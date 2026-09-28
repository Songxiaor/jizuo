import Foundation
import LinkDigestAdapters
import LinkDigestCore

/// 转写后视频清理：按「设置 → 视频存储」里的规则删已转写视频的文件，删前先存封面。
///
/// 启动、转写完成、改设置都会触发；同一时刻只跑一轮，跑的过程中又被触发就在结束后再补一轮，
/// 不会两轮同时删同一批文件。
actor TranscribedVideoCleaner {
  static let shared = TranscribedVideoCleaner()

  private var isRunning = false
  private var needsRerun = false

  @discardableResult
  func run(mediaStore: LocalMediaStore, now: @escaping @Sendable () -> Date = Date.init) async -> LocalMediaStore.DeletionReport? {
    if isRunning {
      needsRerun = true
      return nil
    }
    isRunning = true
    defer { isRunning = false }
    var deleted: [LocalMediaStore.MediaFile] = []
    var refused: [String] = []
    repeat {
      needsRerun = false
      // 清单读不到（历史还没接上）时什么都不删。
      guard let files = mediaStore.transcribedCleanupCandidates(now: now()), !files.isEmpty else { continue }
      for file in files {
        await WorkThumbnailLoader.preservePoster(forVideo: mediaStore.absoluteURL(relativePath: file.relativePath))
      }
      let report = mediaStore.deleteTranscribedVideos(files)
      deleted += report.deleted
      refused += report.refused
    } while needsRerun
    return .init(deleted: deleted, refused: refused)
  }
}
