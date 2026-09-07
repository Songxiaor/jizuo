import XCTest
@testable import LinkDigestApp
import LinkDigestCore

final class CreatorDirectoryPresentationTests: XCTestCase {
  func testPlatformSlotsDoNotInventPlaybackForDouyinOrMixViewsWithCollects() {
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "www.douyin.com"),
      [.likes, .comments, .collects, .shares]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "x.com"),
      [.likes, .comments, .shares, .collects, .views]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "bilibili.com"),
      [.views, .likes, .comments, .collects, .shares]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "xiaohongshu.com"),
      [.likes, .comments, .collects, .shares]
    )
    XCTAssertFalse(CreatorWorkMetricLayout.slots(forHost: "douyin.com").contains(.views))
  }

  func testMetricDisplayKeepsZeroAndMarksMissing() {
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("0").visible, "0")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("0").accessibility, "0")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue(nil).visible, "—")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue(nil).accessibility, "尚未读取")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("338636").visible, "33.9万")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("338636").accessibility, "338636")
  }

  func testRowMetricsStayOnTheSameProjection() {
    let row = HistoryRowProjection(
      taskID: TaskID(),
      title: "本条",
      canonicalURL: "https://x.com/a/status/1",
      host: "x.com",
      sourceLabel: "X",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: "预览",
      likes: "12",
      comments: "0",
      shares: nil,
      collects: "3",
      views: "100"
    )
    XCTAssertEqual(CreatorWorkMetricKind.likes.value(from: row), "12")
    XCTAssertEqual(CreatorWorkMetricKind.comments.value(from: row), "0")
    XCTAssertNil(CreatorWorkMetricKind.shares.value(from: row))
    XCTAssertEqual(CreatorWorkMetricKind.collects.value(from: row), "3")
    XCTAssertEqual(CreatorWorkMetricKind.views.value(from: row), "100")
  }

  func testOldRowJSONWithoutCoverOrMetricsStillDecodes() throws {
    let old = HistoryRowProjection(
      taskID: TaskID(),
      title: "旧行",
      canonicalURL: "https://example.test/a",
      host: "example.test",
      sourceLabel: "网页",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil
    )
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    object.removeValue(forKey: "coverURL")
    object.removeValue(forKey: "likes")
    object.removeValue(forKey: "comments")
    object.removeValue(forKey: "shares")
    object.removeValue(forKey: "collects")
    object.removeValue(forKey: "views")
    object.removeValue(forKey: "sourcePreview")
    let data = try JSONSerialization.data(withJSONObject: object)
    let row = try JSONDecoder().decode(HistoryRowProjection.self, from: data)
    XCTAssertNil(row.coverURL)
    XCTAssertNil(row.likes)
    XCTAssertNil(row.views)
    XCTAssertNil(row.sourcePreview)
    XCTAssertEqual(row.canonicalURL, "https://example.test/a")
  }

  func testDirectoryCardPreviewUsesSourceThenTitleAndIsNeverEmpty() {
    let sourceOnly = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://www.douyin.com/video/1",
      host: "www.douyin.com",
      sourceLabel: "抖音",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      sourcePreview: "配文预览"
    )
    XCTAssertEqual(sourceOnly.directoryCardPreview(fallbackTitle: "标题"), "配文预览")
    let titleOnly = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://www.douyin.com/video/1",
      host: "www.douyin.com",
      sourceLabel: "抖音",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      sourcePreview: nil
    )
    XCTAssertEqual(titleOnly.directoryCardPreview(fallbackTitle: "标题"), "标题")
    XCTAssertEqual(titleOnly.directoryCardPreview(fallbackTitle: "  "), "未提供预览")
    let summarized = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://www.douyin.com/video/1",
      host: "www.douyin.com",
      sourceLabel: "抖音",
      latestRunKind: .summarize,
      latestRunStatus: .completed,
      latestModel: "m",
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: 1,
      usageCost: .unknown,
      artifactPreview: "总结预览",
      sourcePreview: "配文预览"
    )
    XCTAssertEqual(summarized.directoryCardPreview(fallbackTitle: "标题"), "总结预览")
  }

  func testDirectoryHeadlineKeepsIndependentTitleAndHidesDuplicateBody() {
    XCTAssertTrue(CreatorDirectoryCardCopy.isIndependentTitle("独立标题", preview: "这是另一段正文"))
    XCTAssertFalse(CreatorDirectoryCardCopy.isIndependentTitle("同一段正文", preview: "同一段正文"))
    XCTAssertFalse(CreatorDirectoryCardCopy.isIndependentTitle("同一段正文…", preview: "同一段正文后面还有"))
    XCTAssertFalse(CreatorDirectoryCardCopy.isIndependentTitle("无标题", preview: "正文"))
    XCTAssertEqual(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "独立标题",
        preview: "正文另起",
        host: "x.com",
        hasCover: false
      ),
      "独立标题"
    )
    XCTAssertEqual(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "正文另起",
        preview: "正文另起",
        host: "x.com",
        hasCover: false
      ),
      "帖子"
    )
  }

  func testCoveredCardKeepsTitleWhenPreviewFallsBackToTitle() {
    XCTAssertEqual(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "封面文章标题",
        preview: "封面文章标题",
        host: "x.com",
        hasCover: true
      ),
      "封面文章标题"
    )
    XCTAssertEqual(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "无标题",
        preview: "无标题",
        host: "x.com",
        hasCover: true
      ),
      "帖子"
    )
    XCTAssertEqual(CreatorDirectoryCardCopy.contentKind(host: "x.com"), "帖子")
    XCTAssertEqual(CreatorDirectoryCardCopy.contentKind(host: "www.douyin.com"), "作品")
  }

  func testXMetricSlotsStayOneRowOfFive() {
    XCTAssertTrue(CreatorWorkMetricLayout.isX("x.com"))
    XCTAssertFalse(CreatorWorkMetricLayout.isX("www.douyin.com"))
    let rows = CreatorWorkMetricLayout.rows(forHost: "x.com")
    XCTAssertEqual(rows.map(\.count), [5])
    XCTAssertEqual(rows[0], [.likes, .comments, .shares, .collects, .views])
    XCTAssertEqual(CreatorDirectoryChrome.xCardMinimumWidth, 230)
  }

  func testSocialPlatformsShareAdaptiveGridAndMetricOrder() {
    XCTAssertTrue(CreatorWorkMetricLayout.isDouyin("www.douyin.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.isDouyin("douyin.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.isDouyin("v.douyin.com"))
    XCTAssertFalse(CreatorWorkMetricLayout.isDouyin("x.com"))
    XCTAssertFalse(CreatorWorkMetricLayout.isDouyin("xiaohongshu.com"))
    XCTAssertFalse(CreatorWorkMetricLayout.isDouyin("bilibili.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.usesAdaptiveWorkGrid("www.douyin.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.usesAdaptiveWorkGrid("x.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.usesAdaptiveWorkGrid("xiaohongshu.com"))
    XCTAssertTrue(CreatorWorkMetricLayout.usesAdaptiveWorkGrid("bilibili.com"))
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 562), 2)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 734), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 733), 2)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 974), 4)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 973), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: -20), 1)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 10_000), 4)
    let douyin = CreatorWorkMetricLayout.rows(forHost: "www.douyin.com")
    XCTAssertEqual(douyin.map(\.count), [4])
    XCTAssertEqual(douyin[0], [.likes, .comments, .collects, .shares])
    XCTAssertEqual(CreatorWorkMetricLayout.rows(forHost: "x.com").map(\.count), [5])
    XCTAssertEqual(CreatorWorkMetricLayout.rows(forHost: "xiaohongshu.com").map(\.count), [4])
    XCTAssertEqual(CreatorWorkMetricLayout.rows(forHost: "bilibili.com").map(\.count), [5])
    XCTAssertEqual(CreatorWorkMetricKind.shares.title(forHost: "www.douyin.com"), "转发")
  }

  func testXColumnCountClampsBetweenOneAndFour() {
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 734), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 733), 2)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 974), 4)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 973), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 562), 2)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 737), 3)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 1024), 4)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 400), 1)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: -20), 1)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 0), 1)
    XCTAssertEqual(CreatorDirectoryChrome.xColumnCount(availableWidth: 10_000), 4)
  }

  func testDirectoryTimestampUsesPublishedOrSavedAndIncludesYearWhenNeeded() {
    let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
    let utc = TimeZone(secondsFromGMT: 0)!
    let plus8 = TimeZone(secondsFromGMT: 8 * 3_600)!
    let minus5 = TimeZone(secondsFromGMT: -5 * 3_600)!
    let savedAt = Int64(now.timeIntervalSince1970) * 1_000

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2025-03-01T00:00:00Z",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2025年3月1日 00:00"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-06-01T00:00:00Z",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2026年6月1日 00:00"
    )

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00Z",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2026年1月13日 00:31"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00Z",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: plus8
      ),
      "发布于 2026年1月13日 08:31"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00+08:00",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2026年1月12日 16:31"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00+08:00",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: plus8
      ),
      "发布于 2026年1月13日 00:31"
    )

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00.123Z",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2026年1月13日 00:31"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13T00:31:00.456+08:00",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: plus8
      ),
      "发布于 2026年1月13日 00:31"
    )

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: utc
      ),
      "发布于 2026年1月13日"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: plus8
      ),
      "发布于 2026年1月13日"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: minus5
      ),
      "发布于 2026年1月13日"
    )
    XCTAssertFalse(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-01-13",
        savedAtMilliseconds: 1,
        now: now,
        timeZone: minus5
      ).contains(":")
    )

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "5天前",
        savedAtMilliseconds: 1,
        now: now
      ),
      "发布于 5天前"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "8/31",
        savedAtMilliseconds: 1,
        now: now
      ),
      "发布于 8/31"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "2026-02-31",
        savedAtMilliseconds: 1,
        now: now
      ),
      "发布于 2026-02-31"
    )

    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: nil,
        savedAtMilliseconds: savedAt,
        now: now,
        timeZone: utc
      ),
      "保存于 2026年9月7日 12:00"
    )
    XCTAssertEqual(
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: "   ",
        savedAtMilliseconds: savedAt,
        now: now,
        timeZone: utc
      ),
      "保存于 2026年9月7日 12:00"
    )
  }

  func testDirectoryTimestampFormatsDouyinWallclockWithoutTimezoneShift() {
    let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
    let utc = TimeZone(secondsFromGMT: 0)!
    let plus8 = TimeZone(secondsFromGMT: 8 * 3_600)!
    let stamp = { (published: String, zone: TimeZone) in
      HistoryPublishedTimestampFormatter.directoryCardStamp(
        published: published,
        savedAtMilliseconds: 1,
        now: now,
        timeZone: zone
      )
    }

    XCTAssertEqual(stamp("2026-07-13 11:00:00", utc), "发布于 2026年7月13日 11:00")
    XCTAssertEqual(stamp("2026-07-13 11:00:00", plus8), "发布于 2026年7月13日 11:00")
    XCTAssertEqual(stamp("2026-04-01 10:55:54", utc), "发布于 2026年4月1日 10:55")
    XCTAssertEqual(stamp("2026-04-01 10:55:54", plus8), "发布于 2026年4月1日 10:55")
    XCTAssertEqual(stamp("2026-07-13 11:00", utc), "发布于 2026年7月13日 11:00")
    XCTAssertEqual(stamp("2026-07-13 11:00", plus8), "发布于 2026年7月13日 11:00")
    XCTAssertEqual(stamp("2026-07-13 00:00:00", utc), "发布于 2026年7月13日 00:00")
    XCTAssertEqual(stamp("2026-07-13 00:00:00", plus8), "发布于 2026年7月13日 00:00")

    XCTAssertEqual(stamp("2026-02-31 11:00:00", utc), "发布于 2026-02-31 11:00:00")
    XCTAssertEqual(stamp("2026-02-31 11:00:00", plus8), "发布于 2026-02-31 11:00:00")
    XCTAssertEqual(stamp("2026-07-13 24:00:00", utc), "发布于 2026-07-13 24:00:00")
    XCTAssertEqual(stamp("2026-07-13 11:60:00", plus8), "发布于 2026-07-13 11:60:00")
    XCTAssertEqual(stamp("2026-07-13 11:00:60", utc), "发布于 2026-07-13 11:00:60")
    XCTAssertEqual(stamp("2026-7-13 11:00:00", utc), "发布于 2026-7-13 11:00:00")
    XCTAssertEqual(stamp("2026-07-13 11:00:00.5", plus8), "发布于 2026-07-13 11:00:00.5")
  }

  func testAvatarViewsTreatRemoteLoadFailureAsRetryableNotURLPresence() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp")
    let preview = try String(contentsOf: root.appendingPathComponent("DouyinProfileImport.swift"), encoding: .utf8)
    let avatar = try String(contentsOf: root.appendingPathComponent("CreatorDirectoryViews.swift"), encoding: .utf8)
    let previewView = section(preview, from: "struct DouyinProfilePreviewImage: View", to: "struct DouyinProfileDOMCandidate")
    XCTAssertTrue(previewView.contains("failed = true"))
    XCTAssertTrue(previewView.contains("retryID"))
    XCTAssertTrue(previewView.contains("profile-preview-image-retry"))
    XCTAssertTrue(previewView.contains("let loaded = NSImage(data: data)"))
    XCTAssertTrue(avatar.contains("failed = true"))
    XCTAssertTrue(avatar.contains("retryID"))
    XCTAssertTrue(avatar.contains("person.crop.circle.badge.questionmark"))
    XCTAssertTrue(avatar.contains("头像未获取，点击重试"))
    XCTAssertTrue(avatar.contains("history-creator-avatar-retry"))
    XCTAssertTrue(avatar.contains("updatedAtMilliseconds"), "同 URL 更新资料必须改 task identity 才能重拉")
    XCTAssertTrue(avatar.contains("retryID += 1"))
    XCTAssertTrue(avatar.contains("directoryCardPreview"))
    XCTAssertTrue(avatar.contains("HistoryPublishedTimestampFormatter"))
    XCTAssertTrue(avatar.contains("directoryCardStamp"))

    XCTAssertFalse(avatar.contains("Text(\"保存时数据\")"))
    XCTAssertFalse(avatar.contains("ViewThatFits"))
    XCTAssertTrue(avatar.contains("Task.detached(priority: .utility)"))

    XCTAssertFalse(avatar.contains(".accessibilityLabel(title)"))
  }

  func testUnifiedWorkCardsKeepCoverFillMetricsLastAndMapExistingSlotsOnly() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp")
    let views = try String(contentsOf: root.appendingPathComponent("CreatorDirectoryViews.swift"), encoding: .utf8)
    let history = try String(contentsOf: root.appendingPathComponent("HistoryContentView.swift"), encoding: .utf8)
    let layout = try String(contentsOf: root.appendingPathComponent("CreatorWorkCardLayout.swift"), encoding: .utf8)
    let batch = try String(contentsOf: root.appendingPathComponent("ProfileImportBatchViews.swift"), encoding: .utf8)
    let importing = try String(contentsOf: root.appendingPathComponent("DouyinProfileImport.swift"), encoding: .utf8)
    let saved = section(views, from: "struct CreatorSavedWorkCard: View", to: "private var coverStatus")
    let reserved = section(batch, from: "private struct ProfileImportReservedWorkCard: View", to: "private struct ProfileImportBatchCard")
    let candidate = section(importing, from: "private func candidateCard(", to: "private func hasCompleteMetrics(")
    XCTAssertTrue(history.contains("usesAdaptiveWorkGrid(creator.identity.platform)"))
    XCTAssertTrue(history.contains("CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)"))
    XCTAssertTrue(layout.contains("static let coverAspect: CGFloat = 2.35"))
    XCTAssertTrue(layout.contains("scaledToFill()"))
    XCTAssertFalse(layout.contains("scaledToFit()"))
    XCTAssertTrue(saved.contains("CreatorWorkCardCoverSlot"))
    XCTAssertTrue(saved.contains("CreatorWorkCardFillImage"))
    XCTAssertTrue(saved.contains("CreatorWorkMetricStrip"))
    XCTAssertTrue(saved.contains("slot.value(from: row)"))
    XCTAssertFalse(saved.contains("4 / 3"))
    XCTAssertFalse(saved.contains("16 / 9"))
    XCTAssertFalse(saved.contains("scaledToFit()"))
    XCTAssertTrue(views.contains("封面未获取"))
    XCTAssertTrue(views.contains("封面加载中"))
    XCTAssertTrue(saved.contains("coverFailed"))
    XCTAssertTrue(saved.contains("Text(\"文字预览\")"))
    XCTAssertTrue(reserved.contains("发布时间待获取"))
    XCTAssertTrue(reserved.contains("case .shares, .views: nil"))
    XCTAssertTrue(reserved.contains("CreatorWorkMetricStrip"))
    XCTAssertTrue(candidate.contains("发布时间待获取"))
    XCTAssertFalse(candidate.contains("点击选择"))
    XCTAssertFalse(candidate.contains("?? (candidate.wasAlreadySaved"))
    XCTAssertTrue(candidate.contains("candidateMetricsStatusOverlay"))
    XCTAssertTrue(candidate.contains("height: geometry.size.width / CreatorWorkCardLayout.coverAspect"))
    XCTAssertFalse(candidate.contains(".frame(height: 20)"))
    XCTAssertTrue(candidate.contains("Button { model.toggleSelection"))
    XCTAssertTrue(candidate.contains("Button(\"取消\")"))
    XCTAssertTrue(layout.contains("lineLimit(2, reservesSpace: true)"))
    XCTAssertTrue(layout.contains("accessibilityValue(shown.accessibility)"))
    XCTAssertTrue(candidate.contains("case .shares, .views: nil"))
    XCTAssertTrue(candidate.contains("CreatorWorkMetricStrip"))
    XCTAssertTrue(batch.contains("struct ProfileImportBatchHeader"))
    XCTAssertTrue(batch.contains("struct ProfileImportBatchWorkCard"))
  }

  private func section(_ source: String, from: String, to: String) -> String {
    guard let start = source.range(of: from), let end = source.range(of: to, range: start.upperBound..<source.endIndex)
    else { return "" }
    return String(source[start.lowerBound..<end.lowerBound])
  }
}
