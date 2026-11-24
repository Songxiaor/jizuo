import XCTest
@testable import LinkDigestCore

/// 同一链接重抓后作者换过视频：新视频 + 旧转写不能拼在一起。
/// 判据只有 `VideoTranscriptScope` 一处，这里把五种情形钉住。
final class VideoTranscriptScopeTests: XCTestCase {
  private let taskID = TaskID()

  // MARK: - 换过视频

  func testChangedVideoUsesOnlyTheNewVideosTranscript() {
    let oldCapture = snapshot(sequence: 2, kind: .manualLink, body: "旧文案")
    let oldTranscript = snapshot(sequence: 3, kind: .localTranscription, body: "旧视频转写")
    let newCapture = snapshot(sequence: 7, kind: .manualLink, body: "新文案")
    let newTranscript = snapshot(sequence: 8, kind: .localTranscription, body: "新视频转写")

    let oldMedia = media(snapshotID: oldCapture.id, sha: sha("a"), createdAt: 100)
    let newMedia = media(snapshotID: newCapture.id, sha: sha("b"), createdAt: 700)
    let scope = VideoTranscriptScope(
      mediaAssets: [newMedia, oldMedia],
      snapshots: [oldCapture, oldTranscript, newCapture, newTranscript]
    )

    XCTAssertTrue(scope.videoChanged)
    XCTAssertEqual(scope.currentMedia?.id, newMedia.id)
    XCTAssertEqual(scope.currentTranscriptSnapshot()?.bodyText, "新视频转写")
    XCTAssertEqual(scope.staleTranscriptSnapshot()?.bodyText, "旧视频转写")
    XCTAssertTrue(scope.hasCurrentTranscript)
    XCTAssertEqual(scope.scopedSnapshots().map(\.bodyText), ["旧文案", "新文案", "新视频转写"])
    XCTAssertNotNil(scope.commentNotice(in: Self.singapore))
  }

  // MARK: - 同一快照重下高清

  func testSameSnapshotRedownloadIsNotAVideoChange() {
    let capture = snapshot(sequence: 1, kind: .browserCapture, body: "配文")
    let transcript = snapshot(sequence: 2, kind: .localTranscription, body: "转写")
    let standard = media(snapshotID: capture.id, sha: sha("a"), createdAt: 100, duration: 150)
    let highDefinition = media(snapshotID: capture.id, sha: sha("b"), createdAt: 200, duration: 150)

    let scope = VideoTranscriptScope(
      mediaAssets: [highDefinition, standard],
      snapshots: [capture, transcript]
    )

    XCTAssertFalse(scope.videoChanged, "同一快照重下高清是同一个视频")
    XCTAssertEqual(scope.currentMedia?.id, highDefinition.id)
    XCTAssertEqual(scope.currentTranscriptSnapshot()?.id, transcript.id)
    XCTAssertTrue(scope.staleTranscriptSnapshots().isEmpty)
  }

  // MARK: - 没有视频

  func testRecordWithoutVideoKeepsExistingTranscriptBehaviour() {
    let capture = snapshot(sequence: 1, kind: .manualLink, body: "正文")
    let transcript = snapshot(sequence: 2, kind: .localTranscription, body: "录音转写")

    let scope = VideoTranscriptScope(mediaAssets: [], snapshots: [capture, transcript])

    XCTAssertNil(scope.currentMedia)
    XCTAssertFalse(scope.videoChanged)
    XCTAssertEqual(scope.currentTranscriptSnapshot()?.id, transcript.id)
  }

  // MARK: - 只有旧转写

  func testOldTranscriptOnlyIsNotShownAsCurrent() {
    let oldCapture = snapshot(sequence: 2, kind: .manualLink, body: "旧文案")
    let oldTranscript = snapshot(sequence: 3, kind: .localTranscription, body: "旧视频转写")
    let newCapture = snapshot(sequence: 7, kind: .manualLink, body: "新文案")

    let oldMedia = media(snapshotID: oldCapture.id, sha: sha("a"), createdAt: 100)
    let newMedia = media(snapshotID: newCapture.id, sha: sha("b"), createdAt: 700)
    let scope = VideoTranscriptScope(
      mediaAssets: [newMedia, oldMedia],
      snapshots: [oldCapture, oldTranscript, newCapture]
    )

    XCTAssertFalse(scope.hasCurrentTranscript)
    XCTAssertTrue(scope.showsStaleTranscriptOnly)
    XCTAssertEqual(scope.staleTranscriptSnapshot()?.id, oldTranscript.id)
    XCTAssertEqual(scope.scopedSnapshots().map(\.bodyText), ["旧文案", "新文案"])
  }

  // MARK: - 新视频已转写

  func testNewVideosOwnTranscriptCountsAsCurrent() {
    let oldCapture = snapshot(sequence: 2, kind: .manualLink, body: "旧文案")
    let oldTranscript = snapshot(sequence: 3, kind: .localTranscription, body: "旧视频转写")
    let newCapture = snapshot(sequence: 7, kind: .manualLink, body: "新文案")
    let newTranscript = snapshot(
      sequence: 9, kind: .localTranscription, body: "新视频转写（校对稿）", captureMethod: "openai_compatible_chat_tidy"
    )

    let oldMedia = media(snapshotID: oldCapture.id, sha: sha("a"), createdAt: 100)
    let newMedia = media(snapshotID: newCapture.id, sha: sha("b"), createdAt: 700)
    let scope = VideoTranscriptScope(
      mediaAssets: [newMedia, oldMedia],
      snapshots: [oldCapture, oldTranscript, newCapture, newTranscript]
    )

    XCTAssertTrue(scope.hasCurrentTranscript)
    XCTAssertEqual(scope.currentTranscriptSnapshot()?.id, newTranscript.id)
    XCTAssertEqual(scope.currentTranscriptSnapshots().count, 1)
    XCTAssertFalse(scope.showsStaleTranscriptOnly)
  }

  /// 同一文件重复保存（哈希相同）不该让已有转写失效。
  func testSameFileResavedUnderANewSnapshotKeepsTheTranscript() {
    let firstCapture = snapshot(sequence: 1, kind: .manualLink, body: "配文")
    let transcript = snapshot(sequence: 2, kind: .localTranscription, body: "转写")
    let secondCapture = snapshot(sequence: 3, kind: .manualLink, body: "配文（重抓）")
    let media = media(snapshotID: secondCapture.id, sha: sha("a"), createdAt: 300)

    let scope = VideoTranscriptScope(mediaAssets: [media], snapshots: [firstCapture, transcript, secondCapture])

    XCTAssertFalse(scope.videoChanged)
    XCTAssertEqual(scope.currentTranscriptSnapshot()?.id, transcript.id)
  }

  func testCommentNoticeNamesTheFirstSeenDate() {
    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 18
    components.hour = 10
    components.minute = 26
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = Self.singapore
    let milliseconds = Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1_000)

    XCTAssertEqual(
      VideoTranscriptScope.videoChangedCommentNotice(
        firstSeenMilliseconds: milliseconds,
        timeZone: Self.singapore
      ),
      "作者换过视频（汲作在 2026年11月18日 首次抓到新视频），较早的评论可能针对旧视频。"
    )
  }

  // MARK: - 夹具

  private static let singapore = TimeZone(secondsFromGMT: 8 * 3_600)!

  private enum Kind {
    case manualLink, browserCapture, localTranscription

    var origin: CapturedDocument.Origin {
      switch self {
      case .manualLink: .manualLink
      case .browserCapture: .browserCapture
      case .localTranscription: .localTranscription
      }
    }

    var method: String {
      switch self {
      case .manualLink: "manual_link"
      case .browserCapture: "page"
      case .localTranscription: "speech_analyzer_local"
      }
    }
  }

  private func snapshot(
    sequence: Int,
    kind: Kind,
    body: String,
    captureMethod: String? = nil
  ) -> ContentSnapshot {
    ContentSnapshot(
      id: ContentSnapshotID(),
      taskID: taskID,
      sequence: sequence,
      envelopeCreatedAtMilliseconds: Int64(sequence),
      capturedAtMilliseconds: Int64(sequence),
      sourceKind: kind.origin.rawValue,
      sourceURL: "https://example.test/note",
      title: "示例",
      platform: "xiaohongshu",
      captureMethod: captureMethod ?? kind.method,
      completeness: "complete",
      bodyText: body,
      characterCount: body.count,
      bodySHA256: sha("f"),
      sourceLabel: "示例",
      usedCookie: false
    )
  }

  private func media(
    snapshotID: ContentSnapshotID,
    sha value: String,
    createdAt: Int64,
    duration: Double = 150
  ) -> MediaAsset {
    MediaAsset(
      taskID: taskID,
      snapshotID: snapshotID,
      relativePath: "\(value).mp4",
      contentSHA256: value,
      byteSize: 1_024,
      durationSeconds: duration,
      platform: "xiaohongshu",
      transcriptionStatus: .none,
      createdAtMilliseconds: createdAt
    )
  }

  private func sha(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
  }
}
