import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestCore

/// 这条路径上三类错误都不报错、只产出坏结果：认领范围写窄了链接掉回通用路径，
/// 抓回登录墙外壳当正文静默入库；会话跳转白名单写宽了，用户的 Cookie 会跟着
/// 302 送到站外；登录墙外壳解析成功则会存下一条「标题像模像样、正文是站点样板文」
/// 的记录。三类都在这里钉住。
final class XiaohongshuSourceAdapterTests: XCTestCase {
  private let adapter = XiaohongshuSourceAdapter()

  func testClaimsNoteAndShortLinkHosts() {
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.xiaohongshu.com/explore/648c70cf")!))
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://www.xiaohongshu.com/discovery/item/648c70cf")!))
    // 短链 302 到主站，同样要登录才有正文。
    XCTAssertTrue(adapter.takesOwnership(of: URL(string: "https://xhslink.com/a/AbCdEf")!))
  }

  func testDoesNotClaimLookalikeOrForeignHosts() {
    // 后缀匹配必须带点，否则这个域名会被认成自己人。
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://xiaohongshu.com.evil.test/explore/1")!))
    XCTAssertFalse(adapter.takesOwnership(of: URL(string: "https://www.bilibili.com/video/BV1")!))
  }

  func testWithoutSessionItRefusesInsteadOfFetchingTheLoginWall() async {
    do {
      _ = try await adapter.capture(url: URL(string: "https://www.xiaohongshu.com/explore/648c70cf")!)
      XCTFail("未登录时不应该去抓")
    } catch let error as ManualLinkError {
      XCTAssertEqual(error, .loginRequired)
    } catch {
      XCTFail("应当抛 ManualLinkError，实际是 \(error)")
    }
  }

  func testSessionRedirectAllowListKeepsCookiesOnSite() {
    // 这个判定决定「Cookie 能跟着 302 跳到哪」。宽一格就是把用户登录态送去别的域，
    // 而且不会有任何报错。
    XCTAssertTrue(XiaohongshuURL.matchesSessionHost(URL(string: "https://www.xiaohongshu.com/explore/1")!))
    XCTAssertTrue(XiaohongshuURL.matchesSessionHost(URL(string: "https://xhslink.com/a/x")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://xiaohongshu.com.evil.test/")!))
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "https://evil.test/")!))
    // 明文 http 不带 Cookie。
    XCTAssertFalse(XiaohongshuURL.matchesSessionHost(URL(string: "http://www.xiaohongshu.com/explore/1")!))
  }

  func testParserRejectsLoginWallShellButAcceptsARealNote() {
    // 登录墙外壳没有笔记内容：og:description 缺失。解析成功就会静默入库一条假正文。
    let wall = """
      <html><head><meta property="og:title" content="小红书 - 你的生活指南">
      </head><body></body></html>
      """
    XCTAssertNil(XiaohongshuPageParser.parse(html: wall))

    let note = """
      <html><head>
      <meta property="og:title" content="三天两夜厦门citywalk路线 - 小红书">
      <meta property="og:description" content="第一天先去鼓浪屿，建议早上八点前上岛。">
      <meta name="og:xhs:note_user_nickname" content="旅行的小张">
      </head></html>
      """
    let parsed = XiaohongshuPageParser.parse(html: note)
    XCTAssertEqual(parsed?.title, "三天两夜厦门citywalk路线")
    XCTAssertEqual(parsed?.author, "旅行的小张")
    XCTAssertTrue(parsed?.description.contains("鼓浪屿") == true)
  }
}

