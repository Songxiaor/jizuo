import XCTest
@testable import LinkDigestApp
import LinkDigestCore

final class CreatorDirectoryPresentationTests: XCTestCase {
  func testPlatformGroupsKeepPreferredOrderAndPreserveOrderWithinEachPlatform() throws {
    func creator(_ platform: String, _ author: String) throws -> CreatorSummary {
      CreatorSummary(
        id: CreatorID(UUID()),
        identity: try XCTUnwrap(CreatorIdentity(platform: platform, authorID: author)),
        profileURL: "https://\(platform)/\(author)", displayName: author,
        pinnedRank: nil, savedWorkCount: 0, createdAtMilliseconds: 1, updatedAtMilliseconds: 1
      )
    }
    let rows = try [
      creator("x.com", "x"), creator("xiaohongshu.com", "red"),
      creator("www.douyin.com", "first"), creator("bilibili.com", "b"),
      creator("douyin.com", "second"), creator("youtube.com", "y"),
      creator("example.test", "other"),
    ]
    let groups = CreatorDirectoryPlatformGroup.groups(from: rows)
    XCTAssertEqual(groups.map(\.id), [
      "douyin.com", "xiaohongshu.com", "bilibili.com", "x.com", "example.test", "youtube.com",
    ])
    XCTAssertEqual(groups.first?.creators.map(\.id), [rows[2].id, rows[4].id])
    XCTAssertEqual(groups.flatMap(\.creators).count, rows.count)
    XCTAssertTrue(CreatorDirectoryPlatformGroup.groups(from: []).isEmpty)
    XCTAssertEqual(CreatorDirectoryPlatformGroup.groups(from: [rows[1]]).map(\.id), ["xiaohongshu.com"])
  }

  func testCreatorDirectorySurfaceStateFollowsCatalogWorksReaderFlow() {
    XCTAssertEqual(
      CreatorDirectorySurfaceState.resolve(showsCatalog: true, hasSelectedCreator: false, isReading: false),
      .catalog
    )
    XCTAssertEqual(
      CreatorDirectorySurfaceState.resolve(showsCatalog: true, hasSelectedCreator: true, isReading: false),
      .catalog,
      "返回全部博主时，即使保留选中博主也必须先展示目录"
    )
    XCTAssertEqual(
      CreatorDirectorySurfaceState.resolve(showsCatalog: false, hasSelectedCreator: true, isReading: false),
      .works
    )
    XCTAssertEqual(
      CreatorDirectorySurfaceState.resolve(showsCatalog: false, hasSelectedCreator: true, isReading: true),
      .reader,
      "作品详情状态优先于目录或作品列表"
    )
  }

  func testPlatformSlotsDoNotInventPlaybackForDouyinOrMixViewsWithCollects() {
    // 2026-09-10 全平台统一「赞评转藏看」顺序；平台没有的项拿掉，不改顺序。
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "www.douyin.com"),
      [.likes, .comments, .shares, .collects]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "x.com"),
      [.likes, .comments, .shares, .collects, .views]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "bilibili.com"),
      [.likes, .comments, .shares, .collects, .views]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "xiaohongshu.com"),
      [.likes, .comments, .shares, .collects]
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.slots(forHost: "mp.weixin.qq.com"),
      []  // 公众号卡片不显示互动指标，不从其他社交平台补占位。
    )
    XCTAssertFalse(CreatorWorkMetricLayout.slots(forHost: "douyin.com").contains(.views))
    XCTAssertFalse(CreatorWorkMetricLayout.slots(forHost: "mp.weixin.qq.com").contains(.collects))
    XCTAssertFalse(CreatorWorkMetricLayout.slots(forHost: "mp.weixin.qq.com").contains(.shares))
    XCTAssertEqual(CreatorWorkMetricKind.views.title(forHost: "mp.weixin.qq.com"), "阅读")
    XCTAssertTrue(CreatorWorkMetricLayout.usesAdaptiveWorkGrid("mp.weixin.qq.com"))
  }

  func testMetricDisplayKeepsZeroAndMarksMissing() {
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue(nil).visible, "—")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue(nil).accessibility, "未获取")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("").visible, "—")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("").accessibility, "未获取")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("0").visible, "0")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("0").accessibility, "0")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("338636").visible, "33.9万")
    XCTAssertEqual(CreatorWorkMetricLayout.displayValue("338636").accessibility, "338636")
  }

  func testXMetricVisibilityKeepsRealZeroAndOmitsUnknownFields() {
    let partial: [CreatorWorkMetricKind: String?] = [
      .likes: "0",
      .comments: nil,
      .shares: "  ",
      .collects: "12",
      .views: nil,
    ]
    XCTAssertEqual(
      CreatorWorkMetricLayout.visibleSlots(forHost: "x.com") { partial[$0] ?? nil },
      [.likes, .collects]
    )
    XCTAssertTrue(
      CreatorWorkMetricLayout.visibleSlots(forHost: "x.com") { _ in nil }.isEmpty,
      "X 的互动字段全部缺失时应隐藏整行"
    )
    XCTAssertTrue(
      CreatorWorkMetricLayout.visibleSlots(forHost: "www.douyin.com") { _ in nil }.isEmpty,
      "其他社交平台同样只展示已持久化的指标，不塞满 —"
    )
    XCTAssertTrue(
      CreatorWorkMetricLayout.visibleSlots(forHost: "mp.weixin.qq.com") { _ in "1" }.isEmpty,
      "公众号不展示互动条"
    )
    XCTAssertTrue(
      CreatorWorkMetricLayout.visibleSlots(forHost: "github.com") { _ in "9" }.isEmpty,
      "非社交网站不硬套点赞收藏"
    )
    XCTAssertEqual(
      CreatorWorkMetricLayout.visibleSlots(forHost: "www.douyin.com") {
        $0 == .likes ? "0" : ($0 == .comments ? "3" : nil)
      },
      [.likes, .comments]
    )
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
    XCTAssertEqual(sourceOnly.directoryCardPreviewLabel, "原文预览")
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
    XCTAssertEqual(titleOnly.directoryCardPreviewLabel, "标题预览")
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
    XCTAssertEqual(summarized.directoryCardPreviewLabel, "总结预览")
  }

  func testDirectoryCardPreviewSanitizesSourceWrappersWithoutTouchingSummary() {
    let noisy = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://x.com/a/status/1",
      host: "x.com",
      sourceLabel: "X",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      sourcePreview: "## 配文\n<<<\n正文还在 [说明](https://example.com/a)\n>>>\n"
    )
    XCTAssertEqual(noisy.directoryCardPreview(fallbackTitle: "标题"), "正文还在 说明")
    let summaryKeepsStructure = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://x.com/a/status/1",
      host: "x.com",
      sourceLabel: "X",
      latestRunKind: .summarize,
      latestRunStatus: .completed,
      latestModel: "m",
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: 1,
      usageCost: .unknown,
      artifactPreview: "要点：[保留链接说明](https://example.com/b)",
      sourcePreview: "## 配文\n杂质"
    )
    XCTAssertEqual(
      summaryKeepsStructure.directoryCardPreview(fallbackTitle: "标题"),
      "要点：[保留链接说明](https://example.com/b)"
    )
  }

  /// Real persistence path collapses newlines before `sourcePreview` is stored.
  /// Line-anchored "## 配文" cleanup alone leaves the orphan label; card sanitizer
  /// must clear collapsed leading wrappers while keeping body/code.
  func testDirectoryCardPreviewSanitizesCollapsedDirectorySourcePreview() {
    let body = """
    ## 配文
    <<<
    真实配文还在，含 `let keep = true` 与 [说明](https://example.com/a)
    >>>
    """
    let persistedPreview = MarkdownNoteFrontmatter.directorySourcePreview(fromBody: body)
    XCTAssertEqual(
      persistedPreview,
      "## 配文 <<< 真实配文还在，含 `let keep = true` 与 [说明](https://example.com/a) >>>"
    )
    let row = HistoryRowProjection(
      taskID: TaskID(),
      title: "标题",
      canonicalURL: "https://x.com/a/status/1",
      host: "x.com",
      sourceLabel: "X",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      sourcePreview: persistedPreview
    )
    XCTAssertEqual(
      row.directoryCardPreview(fallbackTitle: "标题"),
      "真实配文还在，含 `let keep = true` 与 说明"
    )
    XCTAssertEqual(
      MarkdownNoteFrontmatter.directorySourcePreview(fromBody: body),
      persistedPreview,
      "展示清洗不得改持久化原文生成结果"
    )
  }

  func testAuthorLineNeverUsesWeChatPlatformNameAsAuthor() {
    let missing = HistoryRowProjection(
      taskID: TaskID(),
      title: "文章",
      canonicalURL: "https://mp.weixin.qq.com/s/a",
      host: "mp.weixin.qq.com",
      sourceLabel: "微信公众号",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      author: nil
    )
    XCTAssertEqual(CreatorDirectoryCardCopy.authorLine(row: missing), "作者未获取")
    XCTAssertTrue(CreatorDirectoryCardCopy.isPlaceholderAuthor("作者未获取"))
    XCTAssertFalse(CreatorDirectoryCardCopy.isPlaceholderAuthor("真实公众号名"))
    XCTAssertTrue(CreatorDirectoryCardCopy.isVideoPlatform(host: "v.douyin.com"))
    XCTAssertFalse(CreatorDirectoryCardCopy.isVideoPlatform(host: "mp.weixin.qq.com"))
    XCTAssertNotEqual(CreatorDirectoryCardCopy.authorLine(row: missing), "公众号")
    let named = HistoryRowProjection(
      taskID: TaskID(),
      title: "文章",
      canonicalURL: "https://mp.weixin.qq.com/s/a",
      host: "mp.weixin.qq.com",
      sourceLabel: "微信公众号",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      author: "真实公众号名"
    )
    XCTAssertEqual(CreatorDirectoryCardCopy.authorLine(row: named), "真实公众号名")
  }

  func testAuthorLineUsesHostnameNotCaptureChannelSourceLabel() {
    let github = HistoryRowProjection(
      taskID: TaskID(),
      title: "README",
      canonicalURL: "https://github.com/owner/repo",
      host: "github.com",
      sourceLabel: "GitHub 公开仓库 README",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      author: nil
    )
    XCTAssertEqual(CreatorDirectoryCardCopy.authorLine(row: github), "github.com")
    XCTAssertNotEqual(CreatorDirectoryCardCopy.authorLine(row: github), "GitHub 公开仓库 README")
    XCTAssertEqual(CreatorDirectoryCardCopy.siteIdentity(github), "github.com")

    let newsletter = HistoryRowProjection(
      taskID: TaskID(),
      title: "Issue",
      canonicalURL: "https://writer.substack.com/p/hello",
      host: "writer.substack.com",
      sourceLabel: "Substack 公开页面",
      latestRunKind: nil,
      latestRunStatus: nil,
      latestModel: nil,
      updatedAtMilliseconds: 1,
      latestRunAtMilliseconds: nil,
      usageCost: .unknown,
      artifactPreview: nil,
      author: nil
    )
    XCTAssertEqual(CreatorDirectoryCardCopy.authorLine(row: newsletter), "writer.substack.com")
    XCTAssertNotEqual(CreatorDirectoryCardCopy.authorLine(row: newsletter), "Substack 公开页面")
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
        hasCover: false,
        showsBodyPreview: true
      ),
      "独立标题"
    )
    XCTAssertNil(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "正文另起",
        preview: "正文另起",
        host: "x.com",
        hasCover: false,
        showsBodyPreview: true
      ),
      "无封面文字预览已展示正文时，重复标题应省略而不是再写一遍截断句"
    )
    XCTAssertEqual(
      CreatorDirectoryCardCopy.headline(
        capturedTitle: "正文另起",
        preview: "正文另起",
        host: "x.com",
        hasCover: false,
        showsBodyPreview: false
      ),
      "帖子",
      "封面位是状态占位时仍保留种类标签，避免卡面只剩日期"
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
    XCTAssertEqual(douyin[0], [.likes, .comments, .shares, .collects])
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
    XCTAssertTrue(previewView.contains("thumbnailLoader.image"))
    let failedBranch = section(previewView, from: "} else if failed {", to: "} else {")
    XCTAssertTrue(failedBranch.contains(".onTapGesture { retryID += 1 }"))
    XCTAssertTrue(failedBranch.contains(".accessibilityAction { retryID += 1 }"))
    XCTAssertFalse(failedBranch.contains("Button {"), "嵌套 Button 会把重试接给父卡片")
    XCTAssertFalse(previewView.replacingOccurrences(of: failedBranch, with: "").contains(".onTapGesture"),
      "仅失败区域接管点击，正常封面不能吞掉父卡片的阅读/选择点击")
    XCTAssertTrue(previewView.contains("NSImage(cgImage: thumbnail.image"))
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
    let thumbnails = try String(contentsOf: root.appendingPathComponent("WorkThumbnailLoader.swift"), encoding: .utf8)
    XCTAssertTrue(avatar.contains("WorkThumbnailLoader.shared.image"))
    XCTAssertTrue(thumbnails.contains("Task.detached(priority: .utility)"))
    XCTAssertTrue(thumbnails.contains("CGImageSourceCreateThumbnailAtIndex"))

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
    let saved = section(views, from: "struct CreatorSavedWorkCard: View", to: "private func placeholderCover")
    let reserved = section(batch, from: "private struct ProfileImportReservedWorkCard: View", to: "private struct ProfileImportBatchCard")
    let candidate = section(importing, from: "private func candidateCard(", to: "private func hasCompleteMetrics(")
    XCTAssertTrue(history.contains("usesAdaptiveWorkGrid(creator.identity.platform)"))
    XCTAssertTrue(history.contains("CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)"))
    // 2026-09-10 媒体区统一 16:9：竖版视频和公众号封面在 2.35 的窄条里只剩中间一截。
    XCTAssertTrue(layout.contains("static let coverAspect: CGFloat = 16.0 / 9.0"))
    XCTAssertTrue(layout.contains("scaledToFill()"))
    // 竖版封面走「模糊底 + 完整缩略图」，所以 layout 里允许 scaledToFit；横版仍铺满。
    XCTAssertTrue(layout.contains("isPortrait"))
    XCTAssertTrue(saved.contains("CreatorWorkCardCoverSlot"))
    XCTAssertTrue(saved.contains("CreatorWorkCardFillImage"))
    XCTAssertTrue(saved.contains("CreatorWorkMetricStrip"))
    XCTAssertTrue(saved.contains("slot.value(from: row)"))
    XCTAssertTrue(saved.contains("CreatorDirectoryCardCopy.headline("))
    XCTAssertTrue(saved.contains("showsBodyPreview: showsBodyPreview"))
    XCTAssertFalse(saved.contains("private var headline: String { capturedTitle }"))
    XCTAssertFalse(saved.contains("4 / 3"))
    XCTAssertFalse(saved.contains("scaledToFit()"), "比例和裁切只在 CreatorWorkCardLayout 一处定")
    XCTAssertTrue(views.contains("封面未获取"))
    XCTAssertTrue(views.contains("封面加载中"))
    XCTAssertTrue(saved.contains("coverFailed"))
    // 「原文预览 / 总结预览」标签已撤：每张卡重复一遍的固定文字是噪音，摘录按句读收尾。
    XCTAssertFalse(saved.contains("directoryCardPreviewLabel"))
    XCTAssertTrue(saved.contains("CreatorDirectoryCardCopy.excerpt("))
    XCTAssertTrue(saved.contains("showsBodyPreview"))
    // 骨架固定：标题两行占位、元信息一行、互动一行固定高度。
    XCTAssertTrue(saved.contains("lineLimit(2, reservesSpace: true)"))
    XCTAssertTrue(saved.contains("CreatorWorkCardLayout.metricRowHeight"))
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

    let wechat = try String(contentsOf: root.appendingPathComponent("WeChatArticleGallery.swift"), encoding: .utf8)
    XCTAssertTrue(wechat.contains("CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)"))
    XCTAssertFalse(wechat.contains("availableWidth >= 1_000"))
    XCTAssertTrue(wechat.contains("PlatformHistoryGallery("), "公众号复用统一图库，不单独复制一套")
    XCTAssertFalse(wechat.contains("CreatorWorkMetricStrip"), "公众号卡片不展示无法采集的互动指标；其他平台继续保留")
    XCTAssertFalse(wechat.contains("wechat-gallery-metrics-note"))
    XCTAssertFalse(wechat.contains("互动数据为采集时快照"))
    XCTAssertTrue(wechat.contains("wechat-article-gallery"))
    XCTAssertFalse(wechat.contains("cardHeight"))
    let gallery = try String(contentsOf: root.appendingPathComponent("PlatformHistoryGallery.swift"), encoding: .utf8)
    XCTAssertTrue(gallery.contains("CreatorDirectoryChrome.xColumnCount"))
    XCTAssertTrue(gallery.contains("CreatorSavedWorkCard("))
    XCTAssertTrue(gallery.contains("scrollTarget"))
    XCTAssertTrue(gallery.contains("contextMenu(row)"))
    XCTAssertTrue(gallery.contains("toggleGallerySelection"))
    XCTAssertTrue(gallery.contains("最近更新"), "排序入口要保留「最近更新」这一档")
    XCTAssertTrue(gallery.contains("WorkSortOrder"), "平台图库要提供排序下拉")
    XCTAssertTrue(gallery.contains("isLoadingNextPage"))
    XCTAssertFalse(gallery.contains("scrollTarget = row.taskID"), "打开详情时不应提前消耗返回锚点")
    let xGallery = try String(contentsOf: root.appendingPathComponent("XPostGallery.swift"), encoding: .utf8)
    XCTAssertTrue(xGallery.contains("PlatformHistoryGallery("))
    XCTAssertTrue(xGallery.contains("x-post-gallery"))
    XCTAssertTrue(xGallery.contains("scrollTarget"))
    XCTAssertTrue(xGallery.contains("contextMenu"))
    XCTAssertFalse(xGallery.contains("scrollTarget = row.taskID"), "X 打开详情时不应提前消耗返回锚点")
  }

  func testUnifiedPlatformGalleryRoutesAllElevenEntries() {
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["x.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["douyin.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["mp.weixin.qq.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["bilibili.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["github.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["youtube.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["discourse"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["reddit.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["substack.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["xiaohongshu.com"]))
    XCTAssertTrue(PlatformHistoryGalleryPresentation.showsGallery(for: ["obscure.example", "another.test"]))
    XCTAssertFalse(PlatformHistoryGalleryPresentation.showsGallery(for: []))
    XCTAssertEqual(
      PlatformHistoryGalleryPresentation.platformDisplayName(for: ["obscure.example", "another.test"]),
      "其他"
    )
    XCTAssertEqual(
      PlatformHistoryGalleryPresentation.title(
        selectedHosts: ["x.com"],
        searchText: "关键词",
        navigationCounts: .init()
      ),
      "X · 当前筛选"
    )
  }

  private func section(_ source: String, from: String, to: String) -> String {
    guard let start = source.range(of: from), let end = source.range(of: to, range: start.upperBound..<source.endIndex)
    else { return "" }
    return String(source[start.lowerBound..<end.lowerBound])
  }
}
