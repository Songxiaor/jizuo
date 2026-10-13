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

  func testSingleSourceTabIsCaptionOnlyForVideoAndImagePosts() {
    // 视频、音频帖：有本机媒体文件、没存下来的视频、视频平台。
    XCTAssertTrue(SourceTabNaming.isCaption(hasVideoOrAudioFile: true, isUnsavedVideo: false, isVideoPlatform: false, bodyText: "一句话"))
    XCTAssertTrue(SourceTabNaming.isCaption(hasVideoOrAudioFile: false, isUnsavedVideo: true, isVideoPlatform: false, bodyText: "一句话"))
    XCTAssertTrue(SourceTabNaming.isCaption(hasVideoOrAudioFile: false, isUnsavedVideo: false, isVideoPlatform: true, bodyText: "一句话"))
    // 图片帖：有图、字很短。
    XCTAssertTrue(SourceTabNaming.isCaption(
      hasVideoOrAudioFile: false, isUnsavedVideo: false, isVideoPlatform: false,
      bodyText: "今天的晚霞\n\n![图](https://pbs.twimg.com/media/a.jpg)"
    ))
    // X 的纯文字推文：没有视频、没有图 → 原文（以前因为走 V2 合同被叫成「配文」）。
    XCTAssertFalse(SourceTabNaming.isCaption(
      hasVideoOrAudioFile: false, isUnsavedVideo: false, isVideoPlatform: false, bodyText: "只有文字的一条推文"
    ))
    // 文章：有图但很长 → 原文。
    let article = String(repeating: "这是一篇文章的正文。", count: 120) + "\n![配图](https://example.com/a.png)"
    XCTAssertFalse(SourceTabNaming.isCaption(
      hasVideoOrAudioFile: false, isUnsavedVideo: false, isVideoPlatform: false, bodyText: article
    ))
  }

  func testReadingTabsUseOnlyFourNames() throws {
    XCTAssertEqual(TranscriptManuscript.Mode.revised.title, "校对稿")
    XCTAssertEqual(TranscriptManuscript.Mode.original.title, "转写稿", "原来叫「原稿」")
    let content = try appSource("HistoryContentView.swift")
    XCTAssertTrue(content.contains("case .transcript: \"转写稿\""), "转写层页签原来叫「转写」")
    XCTAssertFalse(content.contains("下面是机器原稿"))
    XCTAssertTrue(content.contains("SourceTabNaming.isCaption("))
    XCTAssertFalse(
      content.contains("localMediaFileURL != nil || detail.media != nil || detail.hadMediaDescriptor"),
      "不能再因为走了 V2 合同就把纯文字帖当视频帖"
    )
  }

  private func appSource(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("Sources/LinkDigestApp/\(name)"), encoding: .utf8)
  }
}
