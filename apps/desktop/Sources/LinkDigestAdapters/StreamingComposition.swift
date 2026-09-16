import AVFoundation
import Foundation

/// 远程多轨合成错误。与 `SeparateTrackMuxer` 不同：这里不落盘、不导出文件，
/// 只构造可直接交给 `AVPlayerItem` 的内存合成资产。
public enum StreamingCompositionError: Error, Equatable, Sendable {
  case missingVideoTrack
  case missingAudioTrack
  case compositionUnavailable
  case invalidDuration
}

/// 远程 DASH（B 站等）把画面和声音拆成两条 `.m4s`。CDN 常返回
/// `Content-Type: application/octet-stream`，AVFoundation 无法识别类型。
/// 给 `AVURLAsset` 加上 out-of-band MIME（视频 `video/mp4`、音频 `audio/mp4`）
/// 后即可流式播放；双轨再用 `AVMutableComposition` 在内存合成，全程零落盘。
///
/// 本地落盘合成仍走 `SeparateTrackMuxer`；两者并存，职责不交叉。
public enum StreamingComposition {
  public enum MIMERole: Sendable, Equatable {
    case video
    case audio

    public var mimeType: String {
      switch self {
      case .video: "video/mp4"
      case .audio: "audio/mp4"
      }
    }
  }

  /// 构造带 header / out-of-band MIME 的 `AVURLAsset`。
  /// `file://` 等本地资产原样返回，不加任何 option。
  public static func urlAsset(
    url: URL,
    role: MIMERole,
    httpHeaders: [String: String]? = nil,
    applyOutOfBandMIME: Bool = true
  ) -> AVURLAsset {
    let scheme = url.scheme?.lowercased()
    guard scheme == "https" || scheme == "http" else {
      return AVURLAsset(url: url)
    }

    var options: [String: Any] = [:]
    if let httpHeaders, !httpHeaders.isEmpty {
      // 与项目既有用法一致：非公开常量以字符串字面量传入。
      options["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders
    }
    if applyOutOfBandMIME {
      options["AVURLAssetOutOfBandMIMETypeKey"] = mimeTypeHint(for: url, role: role)
    }
    // 精确时长要扫完整 moov / sidx。4K 远程 m4s 这一下经常要十秒；
    // 起播只需要轨道和大致片长，精确度让给已知片长或估算。
    options[AVURLAssetPreferPreciseDurationAndTimingKey] = false
    if options.isEmpty {
      return AVURLAsset(url: url)
    }
    return AVURLAsset(url: url, options: options)
  }

  /// 单 URL：返回带 header + MIME 的 `AVURLAsset`。
  /// 双 URL：分别构造两个 `AVURLAsset`，合成 `AVMutableComposition`（不导出）。
  /// `knownDurationSeconds` 来自站点 API 时，跳过远程资产的慢时长扫描。
  public static func makePlayableAsset(
    videoURL: URL,
    companionAudioURL: URL? = nil,
    httpHeaders: [String: String]? = nil,
    applyOutOfBandMIME: Bool = true,
    knownDurationSeconds: Double? = nil
  ) async throws -> AVAsset {
    let videoAsset = urlAsset(
      url: videoURL,
      role: .video,
      httpHeaders: httpHeaders,
      applyOutOfBandMIME: applyOutOfBandMIME
    )
    guard let companionAudioURL else { return videoAsset }

    let audioAsset = urlAsset(
      url: companionAudioURL,
      role: .audio,
      httpHeaders: httpHeaders,
      applyOutOfBandMIME: applyOutOfBandMIME
    )
    return try await compose(
      videoAsset: videoAsset,
      audioAsset: audioAsset,
      knownDurationSeconds: knownDurationSeconds
    )
  }

  /// HLS 用 playlist MIME；其余按轨角色给 mp4 容器提示。
  public static func mimeTypeHint(for url: URL, role: MIMERole) -> String {
    let path = url.path.lowercased()
    if path.contains(".m3u8") {
      return "application/vnd.apple.mpegurl"
    }
    return role.mimeType
  }

  /// `AVAsset` 不是 `Sendable`，但「并行加载属性」恰恰是苹果推荐的用法（`load(_:)`
  /// 系列本身线程安全）。这个盒子只是把这条事实写给编译器：里头装的资产只读、
  /// 只用来取属性，不会跨隔离域被改写。不带它就只剩「串行加载」一个选择，
  /// 而 4K 双轨串行等待实测会叠到十几秒。
  private struct ConcurrentAsset: @unchecked Sendable {
    let asset: AVAsset
  }

  private static func compose(
    videoAsset: AVAsset,
    audioAsset: AVAsset,
    knownDurationSeconds: Double?
  ) async throws -> AVMutableComposition {
    // 画面和声音并行等轨：串行的话 4K 双轨经常把等待叠成十几秒。
    //
    // 走 `loadTracks` / `load(_:)` 而不是同步的 `tracks(withMediaType:)` / `duration`：
    // 同步那套从 macOS 13 起已废弃，而且它要求先手工 `loadValuesAsynchronously`
    // 预热属性——等于把异步加载自己实现一遍，还多出「拼 DispatchGroup + 逐键查
    // status」两处能写错的地方。
    let videoBox = ConcurrentAsset(asset: videoAsset)
    let audioBox = ConcurrentAsset(asset: audioAsset)
    async let videoTracks = videoBox.asset.loadTracks(withMediaType: .video)
    async let audioTracks = audioBox.asset.loadTracks(withMediaType: .audio)
    let (loadedVideoTracks, loadedAudioTracks) = try await (videoTracks, audioTracks)

    guard let sourceVideoTrack = loadedVideoTracks.first else {
      throw StreamingCompositionError.missingVideoTrack
    }
    guard let sourceAudioTrack = loadedAudioTracks.first else {
      throw StreamingCompositionError.missingAudioTrack
    }

    let transform = try await sourceVideoTrack.load(.preferredTransform)

    if let known = knownDurationSeconds, known.isFinite, known > 0 {
      let knownDuration = CMTime(seconds: known, preferredTimescale: 600)
      if let composed = try? buildComposition(
        sourceVideoTrack: sourceVideoTrack,
        sourceAudioTrack: sourceAudioTrack,
        duration: knownDuration,
        preferredTransform: transform
      ) {
        return composed
      }
    }

    if let duration = await numericDuration(videoAsset: videoAsset, audioAsset: audioAsset) {
      return try buildComposition(
        sourceVideoTrack: sourceVideoTrack,
        sourceAudioTrack: sourceAudioTrack,
        duration: duration,
        preferredTransform: transform
      )
    }

    let duration = try await resolvedDuration(
      videoAsset: videoAsset,
      audioAsset: audioAsset,
      sourceVideoTrack: sourceVideoTrack,
      sourceAudioTrack: sourceAudioTrack
    )
    return try buildComposition(
      sourceVideoTrack: sourceVideoTrack,
      sourceAudioTrack: sourceAudioTrack,
      duration: duration,
      preferredTransform: transform
    )
  }

  /// 两个资产里较短的那条时长；任何一边还不是有效数值就返回 nil。
  ///
  /// 这里每次都会真的去 load 一次 duration（`load(_:)` 自带缓存，重复调用不会
  /// 再走网络）；原来那个「只读已缓存值」的变体是靠同步 `asset.duration` 判断的，
  /// 同样是 macOS 13 起废弃的写法。
  ///
  /// 远程 fMP4/m4s 的 duration 有时是 indefinite，那种情况交给 `resolvedDuration`
  /// 改走轨 timeRange。
  private static func numericDuration(videoAsset: AVAsset, audioAsset: AVAsset) async -> CMTime? {
    guard let video = try? await videoAsset.load(.duration),
          let audio = try? await audioAsset.load(.duration)
    else { return nil }
    guard video.isNumeric, audio.isNumeric, video.seconds > 0, audio.seconds > 0 else { return nil }
    return CMTimeMinimum(video, audio)
  }

  private static func resolvedDuration(
    videoAsset: AVAsset,
    audioAsset: AVAsset,
    sourceVideoTrack: AVAssetTrack,
    sourceAudioTrack: AVAssetTrack
  ) async throws -> CMTime {
    // 与 SeparateTrackMuxer 一致：两条流时长可能差几帧，按较短的一条截齐。
    // 远程 fMP4/m4s 有时 asset.duration 为 indefinite，改用轨 timeRange。
    let videoDuration = try await videoAsset.load(.duration)
    let audioDuration = try await audioAsset.load(.duration)
    let duration: CMTime
    if videoDuration.isNumeric, audioDuration.isNumeric,
       videoDuration.seconds > 0, audioDuration.seconds > 0 {
      duration = CMTimeMinimum(videoDuration, audioDuration)
    } else {
      let videoLen = try await sourceVideoTrack.load(.timeRange).duration
      let audioLen = try await sourceAudioTrack.load(.timeRange).duration
      guard videoLen.isNumeric, audioLen.isNumeric,
            videoLen.seconds > 0, audioLen.seconds > 0 else {
        throw StreamingCompositionError.invalidDuration
      }
      duration = CMTimeMinimum(videoLen, audioLen)
    }
    guard duration.isValid, duration.isNumeric, duration.seconds > 0 else {
      throw StreamingCompositionError.invalidDuration
    }
    return duration
  }

  private static func buildComposition(
    sourceVideoTrack: AVAssetTrack,
    sourceAudioTrack: AVAssetTrack,
    duration: CMTime,
    preferredTransform: CGAffineTransform
  ) throws -> AVMutableComposition {
    let composition = AVMutableComposition()
    guard
      let videoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ),
      let audioTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else { throw StreamingCompositionError.compositionUnavailable }

    let range = CMTimeRange(start: .zero, duration: duration)
    try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: .zero)
    try audioTrack.insertTimeRange(range, of: sourceAudioTrack, at: .zero)
    // 竖屏旋转信息在 preferredTransform 上，不带过来会横过来播。
    videoTrack.preferredTransform = preferredTransform
    return composition
  }
}
