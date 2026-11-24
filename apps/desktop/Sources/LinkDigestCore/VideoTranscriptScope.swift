import Foundation

/// 一条记录里「当前视频」的转写口径。
///
/// 同一链接重抓时，作者可能已经把整段视频换掉：新视频是新的 `media_assets` 行，
/// 挂在新的抓取快照上，而旧视频的转写快照仍留在库里。只看「最后一份
/// `local_transcription` 快照」就会把新视频和旧转写拼在一起，阅读页、总结/翻译
/// 输入、导出、知识库同步和 MCP 都会拿到错的内容。
///
/// 判据只在这里定义一次：
/// - 当前视频 = 最新落库的媒体；
/// - 当前视频的转写 = `sequence` 大于「引入当前视频的那份快照」的转写快照；
/// - 同一快照重下的媒体（B 站同一视频换清晰度）不算换视频；
/// - 同一个文件（内容哈希相同）重复保存也不会让旧转写失效。
public struct VideoTranscriptScope: Sendable, Equatable {
  public let mediaAssets: [MediaAsset]
  public let snapshots: [ContentSnapshot]

  public init(mediaAssets: [MediaAsset], snapshots: [ContentSnapshot]) {
    self.mediaAssets = mediaAssets
    self.snapshots = snapshots
  }

  /// `HistoryDetailProjection.mediaAssets` 为空时回退到单条 `media`，兼容旧调用点与测试夹具。
  public init(_ detail: HistoryDetailProjection) {
    let media = detail.mediaAssets.isEmpty
      ? [detail.media].compactMap { $0 }
      : detail.mediaAssets
    self.init(mediaAssets: media, snapshots: detail.snapshots)
  }

  public var currentMedia: MediaAsset? {
    mediaAssets.max { lhs, rhs in
      (lhs.createdAtMilliseconds, lhs.id) < (rhs.createdAtMilliseconds, rhs.id)
    }
  }

  /// 引入当前视频的那份抓取快照。
  public var introducingSnapshot: ContentSnapshot? {
    guard let snapshotID = currentMedia?.snapshotID else { return nil }
    return snapshots.first { $0.id == snapshotID }
  }

  public var introducingSequence: Int? { introducingSnapshot?.sequence }

  /// 当前视频第一次被抓到的时间：评论提示里的「X 之后」用它。
  public var currentVideoFirstSeenMilliseconds: Int64? {
    introducingSnapshot?.capturedAtMilliseconds ?? currentMedia?.createdAtMilliseconds
  }

  /// 所有媒体都是同一个文件（同一内容哈希）：重下、重复保存都没有换内容。
  private var allMediaShareOneFile: Bool {
    guard let current = currentMedia else { return true }
    return mediaAssets.allSatisfy { $0.contentSHA256 == current.contentSHA256 }
  }

  /// 这份转写是不是「当前视频」的转写。
  public func isCurrentVideoTranscript(_ snapshot: ContentSnapshot) -> Bool {
    guard snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue else { return false }
    // 没有视频的记录（图文、纯文字）：口径回到旧行为。
    guard let media = currentMedia else { return true }
    // 同一个文件重复保存 / 重下：转写仍然对应当前这份视频。
    if allMediaShareOneFile { return true }
    if let sequence = introducingSequence { return snapshot.sequence > sequence }
    // 旧记录没把媒体绑到快照：按落库时间兜底，转写在当前视频落地之后才算它的。
    return snapshot.capturedAtMilliseconds >= media.createdAtMilliseconds
  }

  /// 当前视频的转写快照，按 `sequence` 从小到大。
  public func currentTranscriptSnapshots() -> [ContentSnapshot] {
    snapshots
      .filter { isCurrentVideoTranscript($0) && !Self.isBlank($0) }
      .sorted { $0.sequence < $1.sequence }
  }

  public func currentTranscriptSnapshot() -> ContentSnapshot? { currentTranscriptSnapshots().last }

  /// 只属于旧视频的转写快照（不删、只是不再当作当前转写展示）。
  public func staleTranscriptSnapshots() -> [ContentSnapshot] {
    snapshots
      .filter {
        $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
          && !isCurrentVideoTranscript($0) && !Self.isBlank($0)
      }
      .sorted { $0.sequence < $1.sequence }
  }

  public func staleTranscriptSnapshot() -> ContentSnapshot? { staleTranscriptSnapshots().last }

  public var hasCurrentTranscript: Bool { currentTranscriptSnapshot() != nil }

  /// 当前视频还没有转写，但库里留着旧视频的转写。
  public var showsStaleTranscriptOnly: Bool {
    !hasCurrentTranscript && !staleTranscriptSnapshots().isEmpty
  }

  /// 作者换过视频：多份媒体、引入快照不同、内容也不同。
  ///
  /// 同一快照下多份媒体（B 站同一视频重下高清）不算；同一内容哈希也不算。
  public var videoChanged: Bool {
    guard let current = currentMedia, mediaAssets.count > 1 else { return false }
    return mediaAssets.contains { other in
      guard other.id != current.id else { return false }
      if other.contentSHA256 == current.contentSHA256 { return false }
      if let mine = introducingSequence,
         let theirs = sequence(for: other),
         mine == theirs {
        return false
      }
      return true
    }
  }

  /// 去掉旧视频转写后的快照集：喂给总结/翻译/导出/知识库的正文只能用它。
  public func scopedSnapshots() -> [ContentSnapshot] {
    let stale = Set(staleTranscriptSnapshots().map(\.id))
    guard !stale.isEmpty else { return snapshots }
    return snapshots.filter { !stale.contains($0.id) }
  }

  /// 评论是同一篇笔记下的，没法按视频拆；只在真换过视频时提示一句。
  public func commentNotice(in timeZone: TimeZone = .current) -> String? {
    guard videoChanged, let milliseconds = currentVideoFirstSeenMilliseconds else { return nil }
    return Self.videoChangedCommentNotice(firstSeenMilliseconds: milliseconds, timeZone: timeZone)
  }

  public static func videoChangedCommentNotice(
    firstSeenMilliseconds: Int64,
    timeZone: TimeZone = .current
  ) -> String {
    let date = Date(timeIntervalSince1970: Double(firstSeenMilliseconds) / 1_000)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy年M月d日"
    return "作者换过视频（汲作在 \(formatter.string(from: date)) 首次抓到新视频），较早的评论可能针对旧视频。"
  }

  private func sequence(for asset: MediaAsset) -> Int? {
    guard let snapshotID = asset.snapshotID else { return nil }
    return snapshots.first { $0.id == snapshotID }?.sequence
  }

  private static func isBlank(_ snapshot: ContentSnapshot) -> Bool {
    snapshot.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
