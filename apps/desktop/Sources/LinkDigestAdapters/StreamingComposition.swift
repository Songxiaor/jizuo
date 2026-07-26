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
    if options.isEmpty {
      return AVURLAsset(url: url)
    }
    return AVURLAsset(url: url, options: options)
  }

  /// 单 URL：返回带 header + MIME 的 `AVURLAsset`。
  /// 双 URL：分别构造两个 `AVURLAsset`，合成 `AVMutableComposition`（不导出）。
  public static func makePlayableAsset(
    videoURL: URL,
    companionAudioURL: URL? = nil,
    httpHeaders: [String: String]? = nil,
    applyOutOfBandMIME: Bool = true
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
    return try await compose(videoAsset: videoAsset, audioAsset: audioAsset)
  }

  /// HLS 用 playlist MIME；其余按轨角色给 mp4 容器提示。
  public static func mimeTypeHint(for url: URL, role: MIMERole) -> String {
    let path = url.path.lowercased()
    if path.contains(".m3u8") {
      return "application/vnd.apple.mpegurl"
    }
    return role.mimeType
  }

  private static func compose(
    videoAsset: AVAsset,
    audioAsset: AVAsset
  ) async throws -> AVMutableComposition {
    // AVAsset / AVAssetTrack 非 Sendable，必须串行 load（并行 async let 会触发 data race）。
    guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
      throw StreamingCompositionError.missingVideoTrack
    }
    guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
      throw StreamingCompositionError.missingAudioTrack
    }

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
    let range = CMTimeRange(start: .zero, duration: duration)
    try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: .zero)
    try audioTrack.insertTimeRange(range, of: sourceAudioTrack, at: .zero)
    // 竖屏旋转信息在 preferredTransform 上，不带过来会横过来播。
    videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
    return composition
  }
}
