import AVFoundation
import Foundation

/// B 站的 DASH 把画面和声音拆成两条独立的 `.m4s`：画面那条没有声音，声音那条
/// 没有画面。播放和归档都需要一个完整文件，所以下载完两条之后在本机合成一个
/// mp4。合成走 passthrough（`AVAssetExportPresetPassthrough`），不重新编码——
/// 既快又不掉画质，代价是两条流的编码必须本来就能装进 mp4 容器（H.264/HEVC +
/// AAC，选流时已经保证）。
public enum SeparateTrackMuxError: Error, Equatable {
  case missingVideoTrack
  case missingAudioTrack
  case exportUnavailable
  case exportFailed(String)
  case cancelled
}

public enum SeparateTrackMuxer {
  /// 把两个本地文件合成一个 mp4，写到 `destinationURL`。调用方负责清理输入文件。
  public static func mux(
    videoFileURL: URL,
    audioFileURL: URL,
    destinationURL: URL
  ) async throws {
    let videoAsset = AVURLAsset(url: videoFileURL)
    let audioAsset = AVURLAsset(url: audioFileURL)

    guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
      throw SeparateTrackMuxError.missingVideoTrack
    }
    guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
      throw SeparateTrackMuxError.missingAudioTrack
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
    else { throw SeparateTrackMuxError.exportUnavailable }

    // 两条流时长可能差几帧，按较短的一条截齐，避免结尾出现无声或黑帧。
    let videoDuration = try await videoAsset.load(.duration)
    let audioDuration = try await audioAsset.load(.duration)
    let duration = CMTimeMinimum(videoDuration, audioDuration)
    guard duration.isValid, duration.seconds > 0 else {
      throw SeparateTrackMuxError.exportFailed("两条流都没有可用时长")
    }
    let range = CMTimeRange(start: .zero, duration: duration)
    try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: .zero)
    try audioTrack.insertTimeRange(range, of: sourceAudioTrack, at: .zero)
    // 竖屏视频的旋转信息在轨道的 preferredTransform 上，不带过来就会横过来播。
    videoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

    guard let session = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetPassthrough
    ) else { throw SeparateTrackMuxError.exportUnavailable }
    session.outputURL = destinationURL
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true

    do {
      try await session.export(to: destinationURL, as: .mp4)
    } catch is CancellationError {
      throw SeparateTrackMuxError.cancelled
    } catch {
      throw SeparateTrackMuxError.exportFailed(error.localizedDescription)
    }
  }
}
