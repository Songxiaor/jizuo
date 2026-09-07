import XCTest
import WebKit
@testable import LinkDigestApp

@MainActor
final class ProfileImportPlatformTests: XCTestCase {
  private let samples: [(ProfileImportPlatform, String, String)] = [
    (.x, "https://x.com/sample_author", """
      <h2>要查看键盘快捷键，按下问号查看键盘快捷键</h2>
      <main><div data-testid="UserName">Sample</div>
      <article><div data-testid="User-Name"><a href="/sample_author/status/1234567890"><time>Today</time></a></div><div data-testid="tweetText">Original</div></article>
      <article><div data-testid="User-Name"><a href="/other/status/9876543210"><time>Today</time></a></div>Other author</article></main>
      """),
    (.bilibili, "https://space.bilibili.com/123/upload/video", """
      <main><div class="upload-content"><div class="video-list"><div class="upload-video-card"><a href="https://www.bilibili.com/video/BV1234567890">Sample video</a></div></div></div></main>
      <aside><a href="https://www.bilibili.com/video/BV0987654321">Recommendation</a></aside>
      """),
    (.xiaohongshu, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa", """
      <div class="user-page"><div class="user-name">Sample</div><div class="feeds-container"><section class="note-item"><a href="/explore/bbbbbbbbbbbbbbbbbbbbbbbb">Sample note</a><a class="author" href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa">Sample</a></section>
      <section class="note-item"><a href="/explore/cccccccccccccccccccccccc">Other note</a><a class="author" href="/user/profile/dddddddddddddddddddddddd">Other</a></section></div></div>
      """)
  ]

  func testProfileRoutingRejectsCredentialsLookalikesAndContentPages() {
    for (platform, url, _) in samples {
      XCTAssertEqual(ProfileImportPlatform.fromProfileURL(URL(string: url)!), platform)
      XCTAssertNotNil(ProfileImportPlatform.parse(url))
    }
    for url in ["http://x.com/user", "https://x.com.evil.test/user", "https://x.com/home",
                "https://name:password@x.com/user", "https://x.com:999/user",
                "https://x.com/user/status/123", "https://space.bilibili.com/123/favlist",
                "https://www.xiaohongshu.com/explore/aaaaaaaaaaaaaaaaaaaaaaaa"] {
      XCTAssertNil(ProfileImportPlatform.fromProfileURL(URL(string: url)!))
    }
  }

  func testCanonicalWorkURLsDropAccessAndTrackingParameters() {
    XCTAssertEqual(ProfileImportPlatform.canonicalWork(URL(string:"https://www.xiaohongshu.com/explore/aaaaaaaaaaaaaaaaaaaaaaaa?xsec_token=fixture-only")!),
                   "https://www.xiaohongshu.com/explore/aaaaaaaaaaaaaaaaaaaaaaaa")
    XCTAssertEqual(ProfileImportPlatform.canonicalWork(URL(string:"https://twitter.com/Sample/status/123?source=test")!), "https://x.com/sample/status/123")
    XCTAssertNil(ProfileImportPlatform.canonicalWork(URL(string:"https://www.bilibili.com.evil.test/video/BV1234567890")!))
    XCTAssertEqual(ProfileImportPlatform.parse("https://space.bilibili.com/123")?.sourceURL.absoluteString, "https://space.bilibili.com/123/upload/video")
    XCTAssertEqual(
      ProfileImportPlatform.canonicalWork(URL(string: "https://www.iesdouyin.com/share/video/7000000000000000001")!),
      "https://www.douyin.com/video/7000000000000000001"
    )
    XCTAssertEqual(
      ProfileImportPlatform.canonicalWork(URL(string: "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbb")!),
      "https://www.xiaohongshu.com/explore/bbbbbbbbbbbbbbbbbbbbbbbb"
    )
  }

  func testEveryNewPlatformExtractsOnlyScopedAuthorWorks() async throws {
    for (platform, url, body) in samples {
      let result = try await extract(platform, url: url, body: body)
      XCTAssertEqual(result.status, "ready", platform.rawValue)
      XCTAssertEqual(result.candidates.count, 1, platform.rawValue)
      XCTAssertEqual(result.candidates.first?.authorID, platform.authorID(URL(string:url)!))
    }
  }

  func testEveryNewPlatformSeparatesLoginAndChangedLayout() async throws {
    for (platform, url, _) in samples {
      let login = try await extract(platform, url: url, body: "<div role='dialog'>请登录 Log in</div>")
      XCTAssertEqual(login.status, "login", platform.rawValue)
      XCTAssertTrue(login.candidates.isEmpty)
      let changed = try await extract(platform, url: url, body: "<main>New layout without a works container</main>")
      XCTAssertEqual(changed.status, "missing_root", platform.rawValue)
      XCTAssertTrue(changed.candidates.isEmpty)
    }
  }

  func testXiaohongshuPrefersAccessibleWorkLinkOverPlainCardLink() async throws {
    let r = try await extract(.xiaohongshu, url:"https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa", body: """
      <div class="user-page"><div class="feeds-container"><section class="note-item">
      <a href="/explore/bbbbbbbbbbbbbbbbbbbbbbbb">Plain</a>
      <a href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbb?xsec_token=fixture-only&amp;xsec_source=pc_user">Accessible</a>
      <a class="author" href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa">Sample</a>
      </section></div></div>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertEqual(r.candidates.first?.url, "https://www.xiaohongshu.com/explore/bbbbbbbbbbbbbbbbbbbbbbbb?xsec_token=fixture-only&xsec_source=pc_user")
  }

  func testXDoesNotAttributeQuotedPostToProfileOwner() async throws {
    let r = try await extract(.x, url:"https://x.com/sample_author", body: """
      <main><article>
      <div data-testid="User-Name"><a href="/other/status/1234567890"><time>Now</time></a></div>
      <div role="link" data-testid="quoteTweet">
        <div data-testid="User-Name"><a href="/sample_author/status/4567890123"><time>Then</time></a></div>
      </div></article></main>
      """)
    XCTAssertTrue(r.candidates.isEmpty)
  }

  func testXProfileNamePrefersMainUserNameOverLeadingShortcutHeading() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <h2>要查看键盘快捷键，按下问号查看键盘快捷键</h2>
      <h1>Press question mark to see keyboard shortcuts</h1>
      <main>
        <div data-testid="UserName">DAN KOE</div>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """
    )
    XCTAssertEqual(r.status, "ready")
    XCTAssertEqual(r.profileName, "DAN KOE")
    XCTAssertFalse((r.profileName ?? "").contains("键盘快捷键"))
    XCTAssertEqual(r.candidates.map(\.url), ["https://x.com/thedankoe/status/1234567890123"])
  }

  func testXProfileNameRejectsHandleAndIgnoresTweetAndNavAvatars() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <nav><img src="https://pbs.twimg.com/profile_images/login-user.jpg" alt="me"></nav>
      <main>
        <div data-testid="UserName">@thedankoe</div>
        <a href="/thedankoe/photo"><img src="https://pbs.twimg.com/profile_images/owner.jpg"></a>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <img src="https://pbs.twimg.com/profile_images/tweet-avatar.jpg">
        </article>
      </main>
      """,
      title: "DAN KOE (@thedankoe) / X"
    )
    XCTAssertEqual(r.profileName, "DAN KOE")
    XCTAssertEqual(r.profileAvatarURL, "https://pbs.twimg.com/profile_images/owner.jpg")
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("login-user"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("tweet-avatar"))
  }

  func testXProfileNameDoesNotTreatHandleAsSuccess() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <main>
        <div data-testid="UserName">@thedankoe</div>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """
    )
    XCTAssertNil(r.profileName)
    XCTAssertNil(r.profileAvatarURL)
  }

  func testXProfileNameStripsTrailingHandleFromConcatenatedUserName() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <main>
        <div data-testid="UserName">
          <div dir="auto"><span>DAN KOE</span></div>
          <div dir="ltr"><span>@thedankoe</span></div>
        </div>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """
    )
    XCTAssertEqual(r.profileName, "DAN KOE")
    XCTAssertFalse((r.profileName ?? "").localizedCaseInsensitiveContains("@thedankoe"))
  }

  func testXProfileNameKeepsHandleTextInTheMiddleOfTheDisplayName() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <main>
        <div data-testid="UserName">
          <span>thedankoe notes</span>
          <span>@thedankoe</span>
        </div>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """
    )
    XCTAssertEqual(r.profileName, "thedankoe notes")
  }

  func testXProfileNameFallsBackToDocumentTitleHandle() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <h2>要查看键盘快捷键，按下问号查看键盘快捷键</h2>
      <main>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """,
      title: "DAN KOE (@thedankoe) / X"
    )
    XCTAssertEqual(r.profileName, "DAN KOE")
    XCTAssertEqual(r.candidates.count, 1)
  }

  func testXProfileNameFallsBackToAtHandleWhenTitleMissing() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/thedankoe",
      body: """
      <h2>要查看键盘快捷键，按下问号查看键盘快捷键</h2>
      <main>
        <article>
          <div data-testid="User-Name"><a href="/thedankoe/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
        </article>
      </main>
      """
    )
    XCTAssertNil(r.profileName, "没有真实显示名时不能用 @handle 充当姓名")
    XCTAssertEqual(r.candidates.count, 1)
  }

  func testHeaderSelectorsStayTargetOwnedAndDoNotUseChromeAvatars() {
    let x = ProfileImportPlatform.x.discoveryScript
    XCTAssertTrue(x.contains("main a[href=\"' + photoPath + '\"] img"), "X 头像必须按目标 author 参数化")
    XCTAssertFalse(x.contains("href$=\"/photo\""), "不得用任意 /photo 链接")
    XCTAssertFalse(x.contains("[data-testid^=\"UserAvatar-Container-\"]"), "不得扫全部 UserAvatar 容器")
    let bili = ProfileImportPlatform.bilibili.discoveryScript
    XCTAssertTrue(bili.contains(".upinfo-avatar img"))
    XCTAssertTrue(bili.contains(".nickname"))
    XCTAssertFalse(bili.contains("#h-avatar"))
    XCTAssertFalse(bili.contains("#h-name"))
    XCTAssertFalse(bili.contains(".h-avatar"))
    XCTAssertFalse(bili.contains("#h-info img"))
    let xhs = ProfileImportPlatform.xiaohongshu.discoveryScript
    XCTAssertTrue(xhs.contains(".user-page .user-info .user-image"))
    XCTAssertTrue(xhs.contains(".user-page .user-name"))
    XCTAssertFalse(xhs.contains(".user-page .avatar img"))
  }

  func testXProfileAvatarUsesParameterizedOwnerPhotoNotOtherHandles() async throws {
    let r = try await extract(
      .x,
      url: "https://x.com/sample_author",
      body: """
      <nav><a href="/sample_author/photo"><img src="https://pbs.twimg.com/profile_images/nav.jpg" width="32" height="32"></a></nav>
      <main>
        <div data-testid="UserName">夹具作者</div>
        <a href="/other_author/photo"><img src="https://pbs.twimg.com/profile_images/other.jpg" width="80" height="80"></a>
        <a href="/sample_author/photo"><img src="https://pbs.twimg.com/profile_images/owner.jpg" width="80" height="80"></a>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <img src="https://pbs.twimg.com/profile_images/tweet.jpg" width="40" height="40">
        </article>
      </main>
      """
    )
    XCTAssertEqual(r.status, "ready")
    XCTAssertEqual(r.profileName, "夹具作者")
    XCTAssertEqual(r.profileAvatarURL, "https://pbs.twimg.com/profile_images/owner.jpg")
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("other.jpg"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("nav.jpg"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("tweet.jpg"))
  }

  func testBilibiliHeaderUsesUpinfoAvatarAndNicknameNotLoggedInChrome() async throws {
    let r = try await extract(
      .bilibili,
      url: "https://space.bilibili.com/123/upload/video",
      body: """
      <nav class="bili-header">
        <img class="avatar" src="https://i0.hdslb.com/bfs/face/logged-in.jpg" width="32" height="32">
        <span class="nickname">当前登录用户</span>
      </nav>
      <div id="h-info"><img src="https://i0.hdslb.com/bfs/face/h-info.jpg" width="64" height="64"></div>
      <div class="upinfo-avatar"><picture><img src="//i2.hdslb.com/bfs/face/fixture-up.jpg" width="64" height="64"></picture></div>
      <span class="nickname">夹具UP主</span>
      <main><div class="upload-content"><div class="video-list">
        <div class="upload-video-card">
          <a href="https://www.bilibili.com/video/BV1234567890">Sample video</a>
          <img class="avatar" src="https://i0.hdslb.com/bfs/face/card.jpg" width="40" height="40">
        </div>
      </div></div></main>
      """
    )
    XCTAssertEqual(r.status, "ready")
    XCTAssertEqual(r.profileName, "夹具UP主")
    XCTAssertEqual(r.profileAvatarURL, "https://i2.hdslb.com/bfs/face/fixture-up.jpg")
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("logged-in"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("h-info"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("card.jpg"))
    XCTAssertEqual(r.candidates.count, 1)
  }

  func testBilibiliPublicHeaderSurvivesWrongWorksTab() async throws {
    let r = try await extract(
      .bilibili,
      url: "https://space.bilibili.com/123",
      body: """
      <nav class="bili-header"><img class="avatar" src="https://i0.hdslb.com/bfs/face/logged-in.jpg" width="32" height="32"><span class="nickname">当前登录用户</span></nav>
      <div class="upinfo-avatar"><img src="//i2.hdslb.com/bfs/face/fixture-up.jpg" width="64" height="64"></div>
      <span class="nickname">夹具UP主</span>
      """
    )
    XCTAssertEqual(r.status, "wrong_tab")
    XCTAssertEqual(r.profileName, "夹具UP主")
    XCTAssertEqual(r.profileAvatarURL, "https://i2.hdslb.com/bfs/face/fixture-up.jpg")
    XCTAssertTrue(r.candidates.isEmpty)
  }

  func testXiaohongshuHeaderUsesUserImageAndKeepsPublicProfileBehindLoginWall() async throws {
    let r = try await extract(
      .xiaohongshu,
      url: "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa",
      body: """
      <div class="user-page">
        <div class="user-info">
          <img src="https://sns-avatar-qc.xhscdn.com/avatar/decoration" width="20" height="20">
          <img class="user-image" src="https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner" width="80" height="80">
        </div>
        <div class="user-name">夹具作者</div>
        <div class="feeds-container">
          <section class="note-item">
            <a href="/explore/bbbbbbbbbbbbbbbbbbbbbbbb">Sample note</a>
            <a class="author" href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa">夹具作者</a>
            <img src="https://sns-avatar-qc.xhscdn.com/avatar/note-cover" width="120" height="120">
          </section>
        </div>
      </div>
      <div class="login-container" style="width:240px;height:120px">请登录 Log in</div>
      """
    )
    XCTAssertEqual(r.status, "login")
    XCTAssertEqual(r.profileName, "夹具作者")
    XCTAssertEqual(r.profileAvatarURL, "https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner")
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("decoration"))
    XCTAssertFalse((r.profileAvatarURL ?? "").contains("note-cover"))
    XCTAssertTrue(r.candidates.isEmpty, "作品登录墙不得把笔记写进列表，但公开 header 仍应保存")
  }

  func testVisibleLoginContainerBlocksWorksEvenWithoutLoginCopy() async throws {
    let r = try await extract(
      .xiaohongshu,
      url: "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa",
      body: """
      <div class="user-page">
        <div class="user-info"><img class="user-image" src="https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner" width="80" height="80"></div>
        <div class="user-name">夹具作者</div>
        <div class="feeds-container">
          <section class="note-item">
            <a href="/explore/bbbbbbbbbbbbbbbbbbbbbbbb">Sample note</a>
            <a class="author" href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa">夹具作者</a>
          </section>
        </div>
      </div>
      <div class="login-container" style="width:240px;height:120px">扫码</div>
      """
    )
    XCTAssertEqual(r.status, "login")
    XCTAssertEqual(r.profileName, "夹具作者")
    XCTAssertEqual(r.profileAvatarURL, "https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner")
    XCTAssertTrue(r.candidates.isEmpty)
  }

  func testXiaohongshuReadyHeaderStillDiscoversOwnerWorks() async throws {
    let r = try await extract(
      .xiaohongshu,
      url: "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa",
      body: """
      <div class="user-page">
        <div class="user-info"><img class="user-image" src="https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner" width="80" height="80"></div>
        <div class="user-name">夹具作者</div>
        <div class="feeds-container">
          <section class="note-item">
            <a href="/explore/bbbbbbbbbbbbbbbbbbbbbbbb">Sample note</a>
            <a class="author" href="/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa">夹具作者</a>
          </section>
        </div>
      </div>
      """
    )
    XCTAssertEqual(r.status, "ready")
    XCTAssertEqual(r.profileName, "夹具作者")
    XCTAssertEqual(r.profileAvatarURL, "https://sns-avatar-qc.xhscdn.com/avatar/fixture-owner")
    XCTAssertEqual(r.candidates.count, 1)
  }

  func testXKeepsOwnPostsAndDropsAdsRepostsQuotesWithoutLoginFalsePositive() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="placementTracking"></div>
          <div data-testid="User-Name"><a href="/sample_author/status/1111111111111"><time>Ad</time></a></div>
          <div data-testid="tweetText">Promoted</div>
        </article>
        <article>
          <div data-testid="promotedIndicator">Promoted</div>
          <div data-testid="User-Name"><a href="/sample_author/status/1212121212121"><time>Ad2</time></a></div>
        </article>
        <article>
          <div data-testid="socialContext">转帖</div>
          <div data-testid="User-Name"><a href="/sample_author/status/2222222222222"><time>Repost</time></a></div>
        </article>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/3333333333333"><time>Now</time></a></div>
          <div data-testid="tweetText">登录后也能继续看这篇</div>
          <div role="link" data-testid="quoteTweet">
            <div data-testid="User-Name"><a href="/other/status/4444444444444"><time>Then</time></a></div>
            <div data-testid="tweetText">Quoted</div>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.status, "ready")
    XCTAssertEqual(r.candidates.map(\.url), ["https://x.com/sample_author/status/3333333333333"])
    XCTAssertEqual(r.candidates.first?.previewText, "登录后也能继续看这篇")
  }

  func testXDoesNotTreatTweetLoginCopyAsLoginWall() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/other/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">登录后查看更多</div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.status, "ready")
    XCTAssertTrue(r.candidates.isEmpty)
  }

  func testXMetricsStayMissingWhenActionButtonsHaveNoCount() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button data-testid="like" aria-label="Like">Like</button>
            <button data-testid="bookmark" aria-label="Bookmark">Bookmark</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertNil(r.candidates.first?.likes)
    XCTAssertNil(r.candidates.first?.comments)
    XCTAssertNil(r.candidates.first?.collects)
  }

  func testXMetricsKeepExplicitZeroAndCompactCounts() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group">
            <button data-testid="reply" aria-label="0 Replies. Reply">0</button>
            <button data-testid="unlike" aria-label="1.2K Likes. Liked">1.2K</button>
            <button data-testid="removeBookmark" aria-label="7万 书签。已加入书签">7万</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "0")
    XCTAssertEqual(r.candidates.first?.likes, "1.2K")
    XCTAssertEqual(r.candidates.first?.collects, "7万")
  }

  func testXMetricsIgnoreQuotedCountsAndMillionAbbreviation() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="link" data-testid="quoteTweet">
            <div data-testid="User-Name"><a href="/other/status/4444444444444"><time>Then</time></a></div>
            <button data-testid="reply" aria-label="9,999 Replies. Reply">9999</button>
            <button data-testid="like" aria-label="8.8M Likes. Like">8.8M</button>
            <button data-testid="bookmark" aria-label="3,333 Bookmarks. Bookmark">3333</button>
          </div>
          <div role="group">
            <button data-testid="reply" aria-label="12 Replies. Reply">12</button>
            <button data-testid="like" aria-label="2.3M Likes. Like">2.3M</button>
            <button data-testid="bookmark" aria-label="4 Bookmarks. Bookmark">4</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "12")
    XCTAssertEqual(r.candidates.first?.likes, "2.3M")
    XCTAssertEqual(r.candidates.first?.collects, "4")
  }

  func testXMetricsIgnoreRoleLinkQuoteWithoutQuoteTweetAttribute() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="link">
            <div data-testid="User-Name"><a href="/other/status/4444444444444"><time>Then</time></a></div>
            <button data-testid="reply" aria-label="9,999 Replies. Reply">9999</button>
            <button data-testid="like" aria-label="8.8M Likes. Like">8.8M</button>
            <button data-testid="bookmark" aria-label="3,333 Bookmarks. Bookmark">3333</button>
          </div>
          <div role="group">
            <button data-testid="reply" aria-label="12 Replies. Reply">12</button>
            <button data-testid="like" aria-label="2.3M Likes. Like">2.3M</button>
            <button data-testid="bookmark" aria-label="4 Bookmarks. Bookmark">4</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertEqual(r.candidates.first?.comments, "12")
    XCTAssertEqual(r.candidates.first?.likes, "2.3M")
    XCTAssertEqual(r.candidates.first?.collects, "4")
    XCTAssertNotEqual(r.candidates.first?.comments, "9,999")
    XCTAssertNotEqual(r.candidates.first?.likes, "8.8M")
  }

  func testXArticlePreviewIgnoresHeadingInsideRoleLinkQuote() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div role="link">
            <div data-testid="User-Name"><a href="/other/status/4444444444444"><time>Then</time></a></div>
            <div data-testid="twitter-article-title">Quoted headline must not become preview</div>
            <h2>Quoted headline must not become preview</h2>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertNil(r.candidates.first?.previewText)
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("Quoted headline"))
  }

  func testXArticlePreviewIgnoresRoleLinkHeadingWithoutThisPostStatus() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div role="link">
            <h2>Unattributed link-card headline</h2>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertNil(r.candidates.first?.previewText)
  }

  func testXArticlePreviewKeepsThisPostStatusLinkCardTitle() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <a role="link" href="/sample_author/status/1234567890123">
            <span>文章</span>
            <div data-testid="twitter-article-title">Life is a mind game. Here's how you win.</div>
          </a>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertEqual(r.candidates.first?.previewText, "Life is a mind game. Here's how you win.")
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("文章"))
  }

  func testXMetricsFallbackMatchesEnglishSingularReplyAndPluralReplies() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1111111111111"><time>Now</time></a></div>
          <div data-testid="tweetText">Singular</div>
          <div role="group">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button aria-label="1 Reply. Reply">1</button>
            <button data-testid="like" aria-label="2 Likes. Like">2</button>
          </div>
        </article>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/2222222222222"><time>Now</time></a></div>
          <div data-testid="tweetText">Plural</div>
          <div role="group">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button aria-label="12 Replies. Reply">12</button>
            <button data-testid="like" aria-label="3 Likes. Like">3</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.map(\.comments), ["1", "12"])
    XCTAssertEqual(r.candidates.map(\.likes), ["2", "3"])
  }

  func testXMetricsPreferChineseAriaIntegersAndIgnoreViewLinks() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group">
            <button data-testid="reply" aria-label="4 回复。回复">4</button>
            <div data-testid="like">
              <button aria-label="214 喜欢次数。喜欢">214</button>
            </div>
            <a href="/sample_author/status/1234567890123/analytics" aria-label="73129 次查看。查看帖子分析">7.3万</a>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "4")
    XCTAssertEqual(r.candidates.first?.likes, "214")
    XCTAssertNil(r.candidates.first?.collects)
  }

  func testXMetricsPreferExactAriaCountOverVisibleAbbreviation() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group">
            <button data-testid="reply" aria-label="180 回复。回复">180</button>
            <button data-testid="like" aria-label="5528 喜欢次数。喜欢">5.5K</button>
            <a href="/i/analytics" aria-label="722788 次查看。查看帖子分析">72万</a>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "180")
    XCTAssertEqual(r.candidates.first?.likes, "5528")
    XCTAssertNil(r.candidates.first?.collects)
    XCTAssertNotEqual(r.candidates.first?.collects, "72万")
    XCTAssertNotEqual(r.candidates.first?.likes, "5.5K")
  }

  func testXArticlePreviewUsesHeadingNotWholeArticleInnerText() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>1月13日</time></a></div>
          <span>已置顶</span>
          <span>文章</span>
          <h2>How to fix your entire life in 1 day</h2>
          <p>If you're anything like me, you think new years resolutions are stupid.</p>
          <div>9,144 7万 34万 2.3亿</div>
          <div role="group">
            <button data-testid="reply" aria-label="9,144 Replies. Reply">9,144</button>
            <button data-testid="like" aria-label="34万 喜欢。喜欢">34万</button>
            <button data-testid="bookmark" aria-label="Bookmark">Bookmark</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertEqual(r.candidates.first?.previewText, "How to fix your entire life in 1 day")
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("已置顶"))
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("2.3亿"))
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("DAN KOE") || (r.candidates.first?.previewText ?? "").contains("@"))
    XCTAssertEqual(r.candidates.first?.comments, "9,144")
    XCTAssertEqual(r.candidates.first?.likes, "34万")
    XCTAssertNil(r.candidates.first?.collects)
  }

  func testXArticleCoverSiblingUsesFirstDirAutoNotExcerpt() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="article-cover-image">cover</div>
          <div>
            <div><div dir="auto"><span>How to fix your entire life in 1 day</span></div></div>
            <div dir="auto"><span>If you're anything like me, you think new years resolutions are stupid. Because most people go about changing their lives in the completely wrong way.</span></div>
          </div>
          <div role="group" aria-label="12 回复、34 次转帖、56 喜欢、78 书签、99999 次观看">
            <button data-testid="reply" aria-label="12 回复。回复">12</button>
            <button data-testid="like" aria-label="56 喜欢次数。喜欢">56</button>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertEqual(r.candidates.first?.previewText, "How to fix your entire life in 1 day")
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("If you're anything like me"))
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("99999"))
    XCTAssertEqual(r.candidates.first?.comments, "12")
    XCTAssertEqual(r.candidates.first?.likes, "56")
    XCTAssertEqual(r.candidates.first?.collects, "78")
    XCTAssertNotEqual(r.candidates.first?.collects, "99999")
    XCTAssertNotEqual(r.candidates.first?.collects, "34")
  }

  func testXArticleCoverInsideQuoteDoesNotBecomePreview() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div role="link" data-testid="quoteTweet">
            <div data-testid="User-Name"><a href="/other/status/4444444444444"><time>Then</time></a></div>
            <div data-testid="article-cover-image">quoted-cover</div>
            <div>
              <div dir="auto">Quoted headline must not become preview</div>
              <div dir="auto">Quoted excerpt stays out of the owner card.</div>
            </div>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.count, 1)
    XCTAssertNil(r.candidates.first?.previewText)
    XCTAssertFalse((r.candidates.first?.previewText ?? "").contains("Quoted headline"))
  }

  func testXMetricsGroupEnglishScrambledOrderMapsByNameNotViews() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group" aria-label="78 Bookmarks, 56 Likes, 12 Replies, 34 Reposts, 99999 views">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button data-testid="like" aria-label="Like">Like</button>
            <button data-testid="bookmark" aria-label="Bookmark">Bookmark</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "12")
    XCTAssertEqual(r.candidates.first?.likes, "56")
    XCTAssertEqual(r.candidates.first?.collects, "78")
    XCTAssertNotEqual(r.candidates.first?.collects, "99999")
    XCTAssertNotEqual(r.candidates.first?.collects, "34")
    XCTAssertNotEqual(r.candidates.first?.collects, "4B")
  }

  func testXMetricsGroupMissingBookmarkStaysNull() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group" aria-label="12 回复、34 次转帖、56 喜欢、99999 次观看">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button data-testid="like" aria-label="Like">Like</button>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "12")
    XCTAssertEqual(r.candidates.first?.likes, "56")
    XCTAssertNil(r.candidates.first?.collects)
    XCTAssertNotEqual(r.candidates.first?.collects, "99999")
  }

  func testXMetricsGroupExplicitZeroIsKept() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group" aria-label="0 回复、0 喜欢、0 书签">
            <button data-testid="reply" aria-label="Reply">Reply</button>
            <button data-testid="like" aria-label="Like">Like</button>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "0")
    XCTAssertEqual(r.candidates.first?.likes, "0")
    XCTAssertEqual(r.candidates.first?.collects, "0")
  }

  func testXMetricsButtonCountBeatsGroupLabel() async throws {
    let r = try await extract(.x, url: "https://x.com/sample_author", body: """
      <main>
        <div data-testid="UserName">Sample</div>
        <article>
          <div data-testid="User-Name"><a href="/sample_author/status/1234567890123"><time>Now</time></a></div>
          <div data-testid="tweetText">Own post</div>
          <div role="group" aria-label="999 回复、888 喜欢、777 书签、111 次观看">
            <button data-testid="reply" aria-label="4 回复。回复">4</button>
            <button data-testid="like" aria-label="214 喜欢次数。喜欢">214</button>
            <button data-testid="bookmark" aria-label="书签">书签</button>
          </div>
        </article>
      </main>
      """)
    XCTAssertEqual(r.candidates.first?.comments, "4")
    XCTAssertEqual(r.candidates.first?.likes, "214")
    XCTAssertEqual(r.candidates.first?.collects, "777")
    XCTAssertNotEqual(r.candidates.first?.comments, "999")
    XCTAssertNotEqual(r.candidates.first?.likes, "888")
    XCTAssertNotEqual(r.candidates.first?.collects, "111")
  }

  func testGenericModelDeduplicatesAndKeepsSelectedCaptureInMemory() {
    let profile = "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa"
    var enqueued: [String] = []
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false }, enqueue: { urls, _, _ in
      enqueued = urls; return .init(queued: urls.count, skipped: 0)
    })
    model.input = profile; model.start(); model.acceptNavigation(URL(string:profile)!)
    let raw = "https://www.xiaohongshu.com/explore/bbbbbbbbbbbbbbbbbbbbbbbb?xsec_token=fixture-only"
    let candidate = DouyinProfileDOMCandidate(url:raw, authorID:"aaaaaaaaaaaaaaaaaaaaaaaa", previewText:"Sample", coverURL:nil, publishedText:nil, likes:nil, comments:nil, collects:nil)
    let snapshot = DouyinProfileDOMSnapshot(status:"ready", profileAuthorID:"aaaaaaaaaaaaaaaaaaaaaaaa", profileName:"Sample", profileAvatarURL:nil, activeTab:nil, candidates:[candidate,candidate])
    _ = model.merge(snapshot)
    XCTAssertEqual(model.candidates.count, 1)
    XCTAssertEqual(model.candidates.first?.canonicalURL, "https://www.xiaohongshu.com/explore/bbbbbbbbbbbbbbbbbbbbbbbb")
    model.selectAllLoaded(); model.saveSelected()
    XCTAssertEqual(enqueued, [raw])
  }

  func testDouyinShortLinkBindsResolvedProfileURL() {
    var bound: String?
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) },
      ensureCreator: { _, url, _ in bound = url; return nil })
    model.input = "https://v.douyin.com/example/"
    model.start()
    model.acceptNavigation(URL(string:"https://www.douyin.com/user/sample-author")!)
    XCTAssertEqual(bound, "https://www.douyin.com/user/sample-author")
  }

  func testLoginRedirectStopsLoadingWithoutLosingOriginalProfile() {
    let profile = "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa"
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) })
    model.input = profile; model.start()
    model.acceptNavigation(URL(string:"https://www.xiaohongshu.com/login")!)
    XCTAssertEqual(model.phase, .stopped(.loginRequired))
    XCTAssertEqual(model.sourceURL?.absoluteString, profile)
    model.acceptNavigation(URL(string:profile)!)
    XCTAssertEqual(model.phase, .scanning)
  }

  func testFourPlatformsRouteDesktopMobileShareAndRejectUnsafeLookalikes() {
    let routes: [(ProfileImportPlatform, String, String)] = [
      (.douyin, "https://www.douyin.com/user/MS4wLjABAAAAfixture", "https://www.douyin.com/user/MS4wLjABAAAAfixture"),
      (.douyin, "https://m.douyin.com/share/user/MS4wLjABAAAAfixture", "https://www.douyin.com/user/MS4wLjABAAAAfixture"),
      (.xiaohongshu, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa", "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa"),
      (.xiaohongshu, "https://m.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa", "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa"),
      (.x, "https://mobile.twitter.com/Sample_Author", "https://x.com/sample_author"),
      (.bilibili, "https://space.bilibili.com/123456", "https://space.bilibili.com/123456/upload/video"),
      (.bilibili, "https://m.bilibili.com/space/123456", "https://space.bilibili.com/123456/upload/video"),
    ]
    for (platform, input, persistent) in routes {
      let parsed = ProfileImportPlatform.parse(input)
      XCTAssertEqual(parsed?.platform, platform, input)
      XCTAssertEqual(parsed?.persistentURL.absoluteString, persistent, input)
      XCTAssertEqual(ProfileImportPlatform.fromProfileURL(URL(string: input)!), platform, input)
    }
    for url in [
      "http://www.douyin.com/user/abc",
      "https://name:password@x.com/sample_author",
      "https://x.com:8443/sample_author",
      "https://x.com.evil.test/sample_author",
      "https://xhslink.com.evil.test/a/AbCdEf",
      "https://b23.tv.evil.test/abc",
      "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbb",
    ] {
      XCTAssertNil(ProfileImportPlatform.fromProfileURL(URL(string: url)!), url)
      if url.contains("xhslink") || url.contains("b23.tv.evil") {
        XCTAssertNil(ProfileImportPlatform.fromShortLink(URL(string: url)!), url)
      }
    }
  }

  func testShareTextShortLinksAndMultipleURLs() {
    XCTAssertEqual(
      ProfileImportPlatform.parse("复制打开小红书 https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa 看看")?.platform,
      .xiaohongshu
    )
    XCTAssertEqual(
      ProfileImportPlatform.parse("https://xhslink.com/a/AbCdEf")?.platform,
      .xiaohongshu
    )
    XCTAssertEqual(
      ProfileImportPlatform.parse("https://xhslink.cn/o/5SGH7HyxwIk")?.platform,
      .xiaohongshu
    )
    XCTAssertEqual(
      ProfileImportPlatform.parse("B站主页 https://b23.tv/abc123")?.platform,
      .bilibili
    )
    XCTAssertNil(ProfileImportPlatform.parse("https://x.com/sample_author https://x.com/other_author"))
    XCTAssertNil(ProfileImportPlatform.parse("https://xhslink.com/a/AbCdEf https://b23.tv/abc123"))
  }

  func testAccessParametersStayInMemoryAndDropFromPersistentHomepage() {
    let raw = "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa?xsec_token=fixture-only&utm_source=share"
    var bound: String?
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) },
      ensureCreator: { _, url, _ in bound = url; return nil })
    model.input = raw
    model.start()
    XCTAssertEqual(model.platform, .xiaohongshu)
    XCTAssertEqual(model.sourceURL?.absoluteString, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa?xsec_token=fixture-only")
    XCTAssertEqual(bound, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa")
  }

  func testShortLinkHomeWorkAndIllegalRedirectStayOnDeclaredPlatform() {
    var bound: String?
    let home = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) },
      ensureCreator: { _, url, _ in bound = url; return nil })
    home.input = "https://xhslink.cn/o/profile"
    home.start()
    XCTAssertEqual(home.platform, .xiaohongshu)
    XCTAssertTrue(home.dataStore === SiteSessionController.xiaohongshu.dataStore)
    XCTAssertFalse(home.dataStore === SiteSessionController.douyin.dataStore)
    home.acceptNavigation(URL(string: "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa?xsec_token=fixture-only")!)
    XCTAssertEqual(home.phase, .scanning)
    XCTAssertEqual(home.platform, .xiaohongshu)
    XCTAssertEqual(bound, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa")
    XCTAssertEqual(home.sourceURL?.absoluteString, "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa?xsec_token=fixture-only")

    let work = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) })
    work.input = "https://b23.tv/work"
    work.start()
    XCTAssertEqual(work.platform, .bilibili)
    work.acceptNavigation(URL(string: "https://www.bilibili.com/video/BV1234567890")!)
    XCTAssertEqual(work.phase, .failed("这是单条作品链接，请改用单条保存入口，不能当作博主主页导入。"))

    let illegal = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) })
    illegal.input = "https://xhslink.com/a/AbCdEf"
    illegal.start()
    illegal.rejectDisallowedNavigation(URL(string: "https://evil.example/phish")!)
    XCTAssertEqual(illegal.phase, .failed("打开后的地址离开了当前平台，已停止。"))
    XCTAssertEqual(illegal.platform, .xiaohongshu)
    XCTAssertTrue(ProfileImportPlatform.xiaohongshu.allowsNavigation(URL(string: "https://xhslink.cn/o/abc")!))
    XCTAssertTrue(ProfileImportPlatform.bilibili.allowsNavigation(URL(string: "https://b23.tv/abc")!))
    XCTAssertFalse(ProfileImportPlatform.xiaohongshu.allowsNavigation(URL(string: "https://v.douyin.com/abc")!))
    XCTAssertFalse(ProfileImportPlatform.douyin.allowsNavigation(URL(string: "https://b23.tv/abc")!))
    XCTAssertFalse(ProfileImportPlatform.douyin.allowsNavigation(URL(string: "https://xhslink.com/a/AbCdEf")!))
  }

  func testBilibiliShortLinkRootHomepageLoadsCanonicalUploadThenScans() {
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) })
    model.input = "https://b23.tv/space"
    model.start()
    XCTAssertEqual(model.platform, .bilibili)
    let firstNavigation = model.navigationRequestID
    model.acceptNavigation(URL(string: "https://space.bilibili.com/1798443432")!)
    XCTAssertEqual(model.sourceURL?.absoluteString, "https://space.bilibili.com/1798443432/upload/video")
    XCTAssertEqual(model.phase, .loading)
    XCTAssertEqual(model.navigationRequestID, firstNavigation + 1)
    model.acceptNavigation(URL(string: "https://space.bilibili.com/1798443432/upload/video")!)
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertEqual(model.navigationRequestID, firstNavigation + 1)
    XCTAssertFalse(
      DouyinProfileImportViewModel.needsCanonicalNavigation(
        from: URL(string: "https://space.bilibili.com/1798443432/upload/video")!,
        to: URL(string: "https://space.bilibili.com/1798443432/upload/video")!
      )
    )
  }

  func testPersistentSessionsAreReusedAndLoginReloadKeepsCurrentHomepage() {
    XCTAssertTrue(ProfileImportPlatform.x.session === SiteSessionController.x)
    XCTAssertTrue(ProfileImportPlatform.douyin.session === SiteSessionController.douyin)
    XCTAssertTrue(ProfileImportPlatform.xiaohongshu.session === SiteSessionController.xiaohongshu)
    XCTAssertTrue(ProfileImportPlatform.bilibili.session === SiteSessionController.bilibili)
    let profile = "https://www.xiaohongshu.com/user/profile/aaaaaaaaaaaaaaaaaaaaaaaa"
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { _, _, _ in .init(queued: 0, skipped: 0) })
    model.input = profile
    model.start()
    model.acceptNavigation(URL(string: profile)!)
    _ = model.merge(.init(status: "login", profileAuthorID: "aaaaaaaaaaaaaaaaaaaaaaaa", profileName: nil, activeTab: nil, candidates: []))
    XCTAssertEqual(model.phase, .stopped(.loginRequired))
    model.reloadCurrentHomepage()
    XCTAssertEqual(model.phase, .loading)
    XCTAssertEqual(model.input, profile)
    XCTAssertEqual(model.sourceURL?.absoluteString, profile)
    XCTAssertEqual(model.platform, .xiaohongshu)
  }

  func testKnownHTTPShareLinksUpgradeBeforeNavigation() {
    for host in ["v.douyin.com", "xhslink.com", "xhslink.cn", "b23.tv"] {
      XCTAssertEqual(ProfileImportPlatform.parse("分享主页 http://\(host)/example")?.sourceURL.scheme, "https")
    }
    XCTAssertNil(ProfileImportPlatform.parse("http://x.com/sample"))
    XCTAssertNil(ProfileImportPlatform.parse("http://xhslink.com.evil.test/example"))
    XCTAssertNil(ProfileImportPlatform.parse("http://name:secret@xhslink.com/example"))
    XCTAssertNil(ProfileImportPlatform.parse("https://evil.v.douyin.com/example"))
  }

  private func extract(
    _ platform: ProfileImportPlatform,
    url: String,
    body: String,
    title: String? = nil
  ) async throws -> DouyinProfileDOMSnapshot {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: CGRect(x:0,y:0,width:960,height:640),configuration:config)
    let delegate = ProfileFixtureNavigation(expectation: expectation(description:"load"))
    web.navigationDelegate = delegate
    let head = title.map { "<title>\($0)</title>" } ?? ""
    web.loadHTMLString("<html><head>\(head)</head><body>\(body)</body></html>",baseURL:URL(string:url)!)
    await fulfillment(of:[delegate.loaded],timeout:5)
    let value = try await web.evaluateJavaScript(platform.discoveryScript)
    let raw = try XCTUnwrap(value as? String)
    return try JSONDecoder().decode(DouyinProfileDOMSnapshot.self,from:Data(raw.utf8))
  }
}
private final class ProfileFixtureNavigation: NSObject, WKNavigationDelegate {
  let loaded: XCTestExpectation
  init(expectation: XCTestExpectation) { loaded = expectation }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
