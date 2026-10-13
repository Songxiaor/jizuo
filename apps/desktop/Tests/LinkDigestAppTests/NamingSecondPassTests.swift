import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 2026-10-13 命名第二批（Syc 回复「按建议改」）：本地文件→文件、论坛、备忘录同步、随手记、阅读页页签四个叫法。
final class NamingSecondPassTests: XCTestCase {
  // MARK: 文件 / 论坛

  func testListRowSourceNamesUseTheSidebarWords() {
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: LocalImportSource.files.rawValue), "文件")
    XCTAssertEqual(HistoryPlatformDisplay.shortName(forHost: LocalImportSource.files.rawValue), "文件")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "linux.do"), "论坛")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "uscardforum.com"), "论坛")
    // 其它平台名不动。
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "v2ex.com"), "V2EX")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "news.ycombinator.com"), "Hacker News")
    // 存进库里的值不动：导入时写的来源标签仍是「本地文件」，只是显示名换了。
    XCTAssertEqual(LocalFileProvenance.plainSourceLabel, "本地文件")
  }

  // MARK: 备忘录行的小字

  func testAppleNotesRowShowsTheNoteDateInsteadOfTheWordNotes() {
    // 有笔记自己的创建日期：写那一天。
    let published = UIReadingHistoryRow.noteDateText(published: "2026-08-20T09:30:00+08:00", savedAtMilliseconds: 0)
    XCTAssertTrue(published.contains("8月20日"), published)
    // 拿不到：写存入日期，不再写「备忘录」三个字。
    let saved = UIReadingHistoryRow.noteDateText(
      published: nil, savedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
    )
    XCTAssertFalse(saved.isEmpty)
    XCTAssertNotEqual(saved, "备忘录")
  }

  // MARK: 菜单

  func testMenuItemsRenamedAndQuickCaptureShowsItsShortcut() throws {
    let app = try appSource("LinkDigestApp.swift")
    XCTAssertTrue(app.contains("Button(\"从语音备忘录同步\")"))
    XCTAssertTrue(app.contains("Button(\"从备忘录同步\")"))
    XCTAssertFalse(app.contains("Button(\"同步语音备忘录\")"))
    XCTAssertFalse(app.contains("Button(\"同步备忘录\")"))
    // 随手记：名字里不再带快捷键，快捷键在菜单右侧；三个新建入口都保留。
    XCTAssertTrue(app.contains("Button(\"随手记\") { quickCapture.show() }"))
    XCTAssertTrue(app.contains(".keyboardShortcut(\"n\", modifiers: [.control, .option])"))
    XCTAssertFalse(app.contains("Button(\"随手记（"))
    XCTAssertTrue(app.contains("Button(\"新建笔记\")"))
    XCTAssertTrue(app.contains("Button(\"今日笔记\")"))
    // 全局热键本身没动：仍是 ⌃⌥N（Carbon 注册），且别的菜单项没用同一个组合。
    let quick = try appSource("QuickCaptureController.swift")
    XCTAssertTrue(quick.contains("UInt32(kVK_ANSI_N)"))
    XCTAssertTrue(quick.contains("UInt32(controlKey | optionKey)"))
    XCTAssertEqual(app.components(separatedBy: "modifiers: [.control, .option]").count - 1, 1)
  }

  // MARK: 页签

  func testSingleSourceTabIsNamedByPostStructureNotByLength() {
    func isCaption(
      _ platform: String, label: String = "", media: Bool = false, unsavedVideo: Bool = false, quote: Bool = false
    ) -> Bool {
      SourceTabNaming.isCaption(
        platform: platform, sourceLabel: label, hasVideoOrAudioFile: media, isUnsavedVideo: unsavedVideo, hasQuote: quote
      )
    }
    // 社交平台上的帖子：作者那段文字都是「文案」，纯文字推文也是。
    for platform in ["x", "douyin", "xiaohongshu", "bilibili", "youtube", "weibo"] {
      XCTAssertTrue(isCaption(platform), platform)
    }
    // 带视频、没存下来的视频、带引用：不管什么平台都是「文案」。
    XCTAssertTrue(isCaption("generic", media: true))
    XCTAssertTrue(isCaption("generic", unsavedVideo: true))
    XCTAssertTrue(isCaption("generic", quote: true))
    // 整篇文章、笔记、网页：「正文」。
    for platform in ["wechat", "applenotes", "generic", "manual", "github"] {
      XCTAssertFalse(isCaption(platform), platform)
    }
    // X 的长文章是一整篇文章，不是一条推文。
    XCTAssertFalse(isCaption("x", label: SourceTabNaming.xArticleSourceLabel))
  }

  func testReadingTabsUseTheThirdPassNames() throws {
    XCTAssertEqual(TranscriptManuscript.Mode.revised.title, "校对稿")
    XCTAssertEqual(TranscriptManuscript.Mode.marked.title, "朱批")
    XCTAssertEqual(TranscriptManuscript.Mode.original.title, "机器原稿")
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(content.contains("case .transcript: \"转写稿\""))
    XCTAssertTrue(content.contains("下面是机器原稿，模型正在补标点、改错字"))
    XCTAssertTrue(content.contains("SourceTabNaming.isCaption("))
    // 校对稿并进「转写稿」页签：不再有单独的原稿页签，也没有正文上方那一排切换。
    XCTAssertFalse(content.contains("case sourceOriginal"))
    XCTAssertFalse(content.contains("manuscriptModePicker"))
    XCTAssertFalse(content.contains("splitsManuscriptTabs"))
    XCTAssertTrue(content.contains("manuscriptSwitch"))
    XCTAssertFalse(content.contains("SourceTabNaming.isShortImagePost"), "500 字的规则已删")
    let naming = try appSource("SourceTabNaming.swift")
    XCTAssertFalse(naming.contains("500"))
    XCTAssertFalse(naming.contains("bodyText"))
  }

  /// 「校对稿 / 朱批 / 机器原稿」开关是否出现，不能被「按快照缓存」的结果卡住：
  /// 2026-10-13 实测，套了 derivedMemo 以后，某次求值时的「没有」被记成这条的答案，开关再也不出现。
  func testManuscriptSwitchDecisionIsNotCachedPerSnapshot() throws {
    let content = try appSource("HistoryContentView.swift")
    let start = try XCTUnwrap(content.range(of: "private var manuscriptSwitchSnapshot"))
    let end = try XCTUnwrap(content.range(of: "@ViewBuilder private var manuscriptSwitch:", range: start.upperBound..<content.endIndex))
    let body = String(content[start.lowerBound..<end.lowerBound])
    XCTAssertFalse(body.contains("derivedMemo"))
    XCTAssertTrue(body.contains("looksLikeTranscript"))
    XCTAssertTrue(body.contains("speakerTurns("))
  }

  private func appSource(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("Sources/LinkDigestApp/\(name)"), encoding: .utf8)
  }
}
