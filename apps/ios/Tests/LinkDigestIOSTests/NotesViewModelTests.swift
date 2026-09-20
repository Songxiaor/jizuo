import LinkDigestIOS
import LinkDigestShared
import XCTest

@MainActor
final class NotesViewModelTests: XCTestCase {
  func testCreatesTextVoiceAndLinkNotes() async throws {
    let store = InMemoryNoteCardStore()
    let model = NotesViewModel(store: store)
    await model.createTextNote(title: "手写", body: "一段文字")
    await model.createVoiceNote(transcript: "口述内容")
    await model.createLinkNote(
      url: "https://example.com/x",
      title: "链接",
      body: "正文",
      summary: "总结"
    )
    XCTAssertEqual(model.notes.count, 3)
    XCTAssertTrue(model.notes.contains { $0.kind == .text && $0.title == "手写" })
    XCTAssertTrue(model.notes.contains { $0.kind == .voice })
    XCTAssertTrue(model.notes.contains { $0.kind == .link && $0.summary == "总结" })
  }

  func testImportShareInboxCreatesLinkAndText() async throws {
    _ = ShareInbox.consumePending()
    let store = InMemoryNoteCardStore()
    let model = NotesViewModel(store: store)

    XCTAssertTrue(
      ShareInbox.enqueue(
        ShareInbox.Item(
          url: "https://example.com/shared",
          text: "分享带来的正文，避免测试打网",
          title: "分享页"
        )
      )
    )
    XCTAssertTrue(
      ShareInbox.enqueue(
        ShareInbox.Item(text: "一段从分享来的文字", title: "手写分享")
      )
    )

    let count = await model.importShareInbox()
    XCTAssertEqual(count, 2)
    XCTAssertEqual(ShareInbox.peekPending().count, 0)
    XCTAssertTrue(
      model.notes.contains {
        $0.kind == .link
          && $0.sourceURL == "https://example.com/shared"
          && $0.body.contains("分享带来的正文")
      }
    )
    XCTAssertTrue(model.notes.contains { $0.kind == .text && $0.body == "一段从分享来的文字" })
    XCTAssertEqual(model.shareImportBanner, "已从分享导入 2 条")
  }

  func testShareInboxResolvesPlainURLText() {
    let item = ShareInbox.Item(text: "https://example.com/only-url")
    XCTAssertEqual(item.resolvedURLString, "https://example.com/only-url")
    XCTAssertTrue(ShareInbox.looksLikeHTTPURL("https://example.com/only-url"))
    XCTAssertFalse(ShareInbox.looksLikeHTTPURL("不是链接"))
  }

  func testShareDeepCapturePrefersLongerRenderedBody() {
    let plist = ShareDeepCapture.fragments(fromPropertyList: [
      "title": "页面标题",
      "url": "https://mp.weixin.qq.com/s/abc",
      "text": "这是 Safari 当前页抽出的正文，长度足够代表用户已登录看到的内容一二三四五六七八九十。",
      "source": ShareDeepCapture.renderedDOMSource,
    ])
    let merged = ShareDeepCapture.merging(
      .init(url: "https://example.com", title: "旧", text: "短"),
      with: plist
    )
    XCTAssertEqual(merged.url, "https://mp.weixin.qq.com/s/abc")
    XCTAssertTrue(merged.text?.contains("Safari 当前页") == true)
    let item = ShareDeepCapture.normalizedForInbox(merged)
    XCTAssertTrue(item.text?.hasPrefix("【来自当前页】") == true)
    XCTAssertTrue(ShareDeepCapture.isDeepCapturedBody(item.text))
  }

  func testImportShareInboxKeepsRenderedBodyWithoutRefetch() async throws {
    _ = ShareInbox.consumePending()
    let deepBody = "【来自当前页】\n\n用户已打开页里的正文，足够长，导入后不应再被占位符覆盖。"
    XCTAssertTrue(
      ShareInbox.enqueue(
        ShareInbox.Item(
          url: "https://www.xiaohongshu.com/explore/deep",
          text: deepBody,
          title: "笔记"
        )
      )
    )
    let model = NotesViewModel(
      store: InMemoryNoteCardStore(),
      profileStore: UserDefaultsIOSProviderProfileStore(
        defaults: UserDefaults(suiteName: "test.share.deep.\(UUID().uuidString)")!
      ),
      apiKeyStore: InMemoryIOSAPIKeyStore()
    )
    let count = await model.importShareInbox()
    XCTAssertEqual(count, 1)
    XCTAssertEqual(model.notes.first?.body, deepBody)
    XCTAssertTrue(model.shareImportBanner?.contains("当前页") == true)
  }

  func testSearchFiltersTitleAndBody() async throws {
    let store = InMemoryNoteCardStore()
    let model = NotesViewModel(store: store)
    await model.createTextNote(title: "苹果发布会", body: "新品")
    await model.createTextNote(title: "其它", body: "无关")
    model.searchText = "苹果"
    XCTAssertEqual(model.visibleNotes.count, 1)
    XCTAssertEqual(model.visibleNotes.first?.title, "苹果发布会")
  }
}
