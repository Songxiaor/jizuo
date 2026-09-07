#if DEBUG
import Foundation
import LinkDigestCore

/// Isolated end-to-end UI fixture. Only the network adapter is substituted;
/// enqueueing, cancellation, persistence, navigation and cards use production code.
enum ProfileImportBatchPipelineFixture {
  static let environmentKey = "LINKDIGEST_DEBUG_PROFILE_IMPORT_PIPELINE"
  static let authorID = "MS4wLjABAAAAjizuoBatchFixture"
  static let workIDs = (1...5).map { "700000000000000000\($0)" }

  static var root: URL? {
    guard ProcessInfo.processInfo.environment[environmentKey] == "1",
          AppApplicationSupportRoot.shouldUseVisualFixture(),
          let path = ProcessInfo.processInfo.environment[AppApplicationSupportRoot.smokeOverrideEnvironmentKey]
    else { return nil }
    return URL(fileURLWithPath: path).deletingLastPathComponent()
  }

  @MainActor
  static func start(manualLink: ManualLinkViewModel, historyModel: HistoryViewModel) {
    guard root != nil,
          let creatorID = manualLink.ensureProfileCreator(
            authorID: authorID,
            profileURL: "https://www.douyin.com/user/\(authorID)",
            displayName: "隔离批次验收"
          )
    else { return }
    historyModel.focusCreatorInDirectory(creatorID)
    // Reopening the fixture must exercise journal recovery, never re-enqueue.
    guard manualLink.profileImportBatches.isEmpty else { return }
    manualLink.enqueueProfileImport(
      candidates: workIDs.enumerated().map { offset, id in
        .init(workID: id, authorID: authorID,
              canonicalURL: "https://www.douyin.com/video/\(id)",
              previewText: "隔离作品 \(offset + 1) · 抓取前预览",
              likes: "0", comments: "2", collects: nil)
      },
      downloadsVideo: false,
      creatorID: creatorID
    )
  }
}

actor ProfileImportBatchFixtureAdapter: SourceAdapting {
  private let root: URL
  private var attempts: [String: Int] = [:]

  init(root: URL) { self.root = root }

  nonisolated func takesOwnership(of url: URL) -> Bool {
    url.host == "www.douyin.com"
      && ProfileImportBatchPipelineFixture.workIDs.contains(url.lastPathComponent)
  }

  func capture(url: URL) async throws -> CapturedDocument {
    let id = url.lastPathComponent
    attempts[id, default: 0] += 1
    try Data().write(to: root.appendingPathComponent("\(id).started"))
    let release = root.appendingPathComponent("\(id).allow")
    let deadline = Date().addingTimeInterval(120)
    while !FileManager.default.fileExists(atPath: release.path) {
      try Task.checkCancellation()
      guard Date() < deadline else { throw ManualLinkError.timedOut }
      try await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
    if id == ProfileImportBatchPipelineFixture.workIDs[2], attempts[id] == 1 {
      throw ManualLinkError.network
    }
    let number = (ProfileImportBatchPipelineFixture.workIDs.firstIndex(of: id) ?? 0) + 1
    let title = "隔离作品 \(number) · 已保存的完整配文"
    return CapturedDocument(
      createdAt: "2026-09-07T12:00:00Z", origin: .manualLink,
      url: url.absoluteString, title: title, platform: "douyin",
      method: "isolated_batch_fixture",
      text: """
      ---
      title: "\(title)"
      author: "隔离批次验收"
      aweme_id: "\(id)"
      published_at: "2026-09-07T12:00:00Z"
      likes: "12"
      comments: "3"
      collects: "4"
      shares: "5"
      ---

      这是通过真实串行队列与本地保存链路生成的隔离验收内容。用户手动点击才进入阅读，后台任务不得抢走当前页面。
      """,
      completeness: "complete", capturedAt: "2026-09-07T12:00:00Z",
      sourceLabel: "隔离批次验收"
    )
  }
}
#endif
