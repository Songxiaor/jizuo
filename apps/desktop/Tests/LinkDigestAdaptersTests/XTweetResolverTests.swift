import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

private final class XTweetFixtureResourceFetcher: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [SafeResourceRequest] = []
  private let syndication: Data
  private let graphQL: Data
  private let graphQLStatus: Int

  init(syndication: String, graphQL: String, graphQLStatus: Int = 200) {
    self.syndication = Data(syndication.utf8)
    self.graphQL = Data(graphQL.utf8)
    self.graphQLStatus = graphQLStatus
  }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    lock.withLock { seen.append(request) }
    let path = request.url.path
    let body: Data
    let status: Int
    if request.url.host == "cdn.syndication.twimg.com" {
      body = syndication
      status = 200
    } else if path == "/1.1/guest/activate.json" {
      body = Data(#"{"guest_token":"1234567890123456789"}"#.utf8)
      status = 200
    } else if path.hasSuffix("/TweetResultByRestId") {
      body = graphQL
      status = graphQLStatus
    } else {
      return .init(
        url: request.url,
        statusCode: 404,
        contentType: "application/json",
        body: Data()
      )
    }
    return .init(
      url: request.url,
      statusCode: status,
      contentType: "application/json",
      body: body
    )
  }

  var requests: [SafeResourceRequest] { lock.withLock { seen } }
}

final class XTweetResolverTests: XCTestCase {
  func testTweetIDIsReadOnlyFromXStatusPaths() {
    XCTAssertEqual(
      XTweetResolver.tweetID(from: "https://x.com/op7418/status/2080486709729587300"),
      "2080486709729587300"
    )
    // 旧域名与 www 前缀、带查询串的分享链接都应认得。
    XCTAssertEqual(
      XTweetResolver.tweetID(from: "https://www.twitter.com/a/status/1234567890123?s=20"),
      "1234567890123"
    )
    XCTAssertEqual(
      XTweetResolver.tweetID(from: "https://x.com/a/statuses/1234567890123"),
      "1234567890123"
    )

    // 别的站点、非 status 路径、非数字 id 一律不认——避免拿任意 id 去打端点。
    for rejected in [
      "https://example.com/op7418/status/2080486709729587300",
      "https://x.com/op7418",
      "https://x.com/op7418/status/not-a-number",
      "https://x.evil.com/a/status/1234567890123",
      "http://x.com/a/status/1234567890123",
    ] {
      XCTAssertNil(XTweetResolver.tweetID(from: rejected), rejected)
    }
  }

  func testOnlyXVideoCDNIsAcceptedAsAPlaybackSource() {
    XCTAssertTrue(XTweetResolver.isAllowedVideoURL(
      "https://video.twimg.com/amplify_video/2080486192186109952/vid/avc1/1132x1080/8Dk5oXXQHGEdrdjU.mp4"
    ))
    for rejected in [
      "http://video.twimg.com/a.mp4",
      "https://video.twimg.com.evil.test/a.mp4",
      "https://evil.test/a.mp4",
      "https://user:pass@video.twimg.com/a.mp4",
    ] {
      XCTAssertFalse(XTweetResolver.isAllowedVideoURL(rejected), rejected)
    }
  }

  func testPicksHighestBitrateMP4AndSkipsHLSAndForeignHosts() throws {
    // 形状取自端点真实响应：variants 混有 m3u8 与多档 MP4。
    let json = """
    {
      "mediaDetails": [{
        "type": "video",
        "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/2080486192186109952/img/cover.jpg",
        "video_info": {
          "duration_millis": 121000,
          "variants": [
            {"content_type": "application/x-mpegURL", "url": "https://video.twimg.com/amplify_video/2080486192186109952/pl/2JFIJH0cjzUc2oE7.m3u8"},
            {"bitrate": 256000, "content_type": "video/mp4", "url": "https://video.twimg.com/amplify_video/2080486192186109952/vid/avc1/282x270/NBt6T8I8x228XVqB.mp4"},
            {"bitrate": 10368000, "content_type": "video/mp4", "url": "https://video.twimg.com/amplify_video/2080486192186109952/vid/avc1/1132x1080/8Dk5oXXQHGEdrdjU.mp4"},
            {"bitrate": 99999999, "content_type": "video/mp4", "url": "https://evil.test/highest.mp4"}
          ]
        }
      }]
    }
    """
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(json.utf8)
    )
    let media = try XCTUnwrap(XTweetResolver.bestVideo(in: payload, author: "@op7418"))

    XCTAssertEqual(media.platform, "x")
    // 最高码率的 MP4；码率更高但主机不对的那条必须被挡掉。
    XCTAssertEqual(
      media.videoURL,
      "https://video.twimg.com/amplify_video/2080486192186109952/vid/avc1/1132x1080/8Dk5oXXQHGEdrdjU.mp4"
    )
    XCTAssertEqual(media.durationSeconds, 121)
    XCTAssertEqual(media.author, "@op7418")
    XCTAssertEqual(
      media.coverURL,
      "https://pbs.twimg.com/amplify_video_thumb/2080486192186109952/img/cover.jpg"
    )
  }

  func testResolvesAWholeTweetIntoTheSameShapeTheExtensionProduces() throws {
    // 形状取自端点真实响应。
    let json = """
    {
      "text": "最近手搓了一套知识库，现在正在测试会议解析的能力。\\n\\n这有点厉害了。",
      "created_at": "2026-07-23T15:20:28.000Z",
      "favorite_count": 8,
      "conversation_count": 6,
      "user": {"name": "金尘马", "screen_name": "jinchenma_ai"},
      "photos": [
        {"url": "https://pbs.twimg.com/media/HN6_kUyaAAAlH_y.jpg"},
        {"url": "https://evil.test/tracker.jpg"}
      ]
    }
    """
    let payload = try JSONDecoder().decode(XTweetResolver.Payload.self, from: Data(json.utf8))
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "2080312096865271866"))

    XCTAssertEqual(tweet.displayAuthor, "金尘马 (@jinchenma_ai)")
    XCTAssertEqual(tweet.canonicalURL, "https://x.com/jinchenma_ai/status/2080312096865271866")
    // 正文首行即标题——帖子没有独立标题。
    XCTAssertEqual(tweet.title, "最近手搓了一套知识库，现在正在测试会议解析的能力。")
    // 非 X 图床的地址不进正文。
    XCTAssertEqual(tweet.photoURLs, ["https://pbs.twimg.com/media/HN6_kUyaAAAlH_y.jpg"])

    let markdown = tweet.markdownBody
    XCTAssertTrue(markdown.hasPrefix("---\nauthor: \"金尘马 (@jinchenma_ai)\""))
    XCTAssertTrue(markdown.contains("published: \"2026-07-23T15:20:28.000Z\""))
    XCTAssertTrue(markdown.contains("likes: \"8\""))
    XCTAssertTrue(markdown.contains("replies: \"6\""))
    XCTAssertTrue(markdown.contains("![](https://pbs.twimg.com/media/HN6_kUyaAAAlH_y.jpg)"))
    XCTAssertFalse(markdown.contains("evil.test"))
  }

  func testQuotedTweetIsAppendedAsABlockquoteSoTheBodyIsNotHalfMissing() throws {
    // 自引用长串：主帖引出，引用推文才是实质内容——丢掉引用正文就只剩一半。
    let json = """
    {
      "text": "如果你要研究怎么做一个 code agent，别从 0 https://t.co/abc",
      "user": {"name": "Indie Fox", "screen_name": "indie_maker_fox"},
      "quoted_tweet": {
        "text": "我目前实践最好的东西\\n\\n1、Pi\\n2、Craft",
        "user": {"name": "Indie Fox", "screen_name": "indie_maker_fox"},
        "id_str": "2070000000000000000",
        "photos": [{"url": "https://pbs.twimg.com/media/quoted.jpg"}, {"url": "https://evil.test/x.jpg"}]
      }
    }
    """
    let payload = try JSONDecoder().decode(XTweetResolver.Payload.self, from: Data(json.utf8))
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "2071099277066272900"))

    XCTAssertEqual(tweet.quotedText, "我目前实践最好的东西\n\n1、Pi\n2、Craft")
    XCTAssertEqual(tweet.quotedAuthor, "Indie Fox (@indie_maker_fox)")
    // 引用图只收 pbs.twimg.com。
    XCTAssertEqual(tweet.quotedPhotoURLs, ["https://pbs.twimg.com/media/quoted.jpg"])
    XCTAssertEqual(tweet.quotedURL, "https://x.com/indie_maker_fox/status/2070000000000000000")

    let markdown = tweet.markdownBody
    XCTAssertTrue(markdown.contains("如果你要研究怎么做一个 code agent"))
    // 引用内容包在 LDQUOTE 标记块里，阅读区据此渲染成卡片。
    XCTAssertTrue(markdown.contains("<!--LDQUOTE author=\"Indie Fox (@indie_maker_fox)\" url=\"https://x.com/indie_maker_fox/status/2070000000000000000\"-->"))
    XCTAssertTrue(markdown.contains("我目前实践最好的东西"))
    // 引用图以 ![]() 放在块内（会进下载队列，也被卡片渲染器取用）。
    XCTAssertTrue(markdown.contains("![](https://pbs.twimg.com/media/quoted.jpg)"))
    XCTAssertTrue(markdown.contains("<!--/LDQUOTE-->"))
    XCTAssertFalse(markdown.contains("evil.test"))
  }

  func testTweetWithoutAQuoteHasNoBlockquote() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(#"{"text":"只是一条普通推文"}"#.utf8)
    )
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "1234567890123"))
    XCTAssertNil(tweet.quotedText)
    XCTAssertFalse(tweet.markdownBody.contains(">"))
  }

  func testNoteTweetFullTextIsDugOutOfTheNestedGraphQLResponse() {
    // GraphQL 响应结构很深，用宽松遍历找 note_tweet_results.result.text。
    let json = """
    {"data":{"tweetResult":{"result":{"__typename":"Tweet",
      "legacy":{"full_text":"截断预览…"},
      "note_tweet":{"note_tweet_results":{"result":{
        "id":"abc","text":"这是长推文的完整正文，比截断预览长很多。"}}}}}}}
    """
    let text = XTweetResolver.noteTextFromGraphQL(Data(json.utf8))
    XCTAssertEqual(text, "这是长推文的完整正文，比截断预览长很多。")
  }

  func testNoteTextExtractionReturnsNilWhenAbsent() {
    XCTAssertNil(XTweetResolver.noteTextFromGraphQL(Data(#"{"data":{"tweetResult":{"result":{}}}}"#.utf8)))
    XCTAssertNil(XTweetResolver.noteTextFromGraphQL(Data("not json".utf8)))
  }

  func testXArticleRichContentIsConvertedToMarkdown() throws {
    let json = """
    {
      "data": {"tweetResult": {"result": {
        "article": {"article_results": {"result": {
          "title": "一篇完整文章",
          "content_state": {
            "blocks": [
              {"type": "unstyled", "text": "第一段正文", "entityRanges": []},
              {"type": "header-two", "text": "关键结论", "entityRanges": []},
              {"type": "unordered-list-item", "text": "保留列表", "entityRanges": []},
              {"type": "blockquote", "text": "保留引用", "entityRanges": []},
              {"type": "atomic", "text": " ", "entityRanges": [{"key": 0, "offset": 0, "length": 1}]},
              {"type": "atomic", "text": " ", "entityRanges": [{"key": 1, "offset": 0, "length": 1}]}
            ],
            "entityMap": [
              {"key": "0", "value": {"type": "MEDIA", "data": {
                "caption": "图示说明",
                "mediaItems": [{"mediaId": "42"}]
              }}},
              {"key": "1", "value": {"type": "MEDIA", "data": {
                "mediaItems": [{"mediaId": "43"}]
              }}}
            ]
          },
          "media_entities": [
            {"media_id": "42", "media_info": {
              "original_img_url": "https://pbs.twimg.com/media/article.png"
            }},
            {"media_id": "43", "media_info": {
              "original_img_url": "https://evil.test/tracker.png"
            }}
          ]
        }}}
      }}}
    }
    """

    let article = try XCTUnwrap(
      XTweetResolver.articleContentFromGraphQL(Data(json.utf8))
    )
    XCTAssertEqual(article.title, "一篇完整文章")
    XCTAssertTrue(article.isComplete)
    XCTAssertTrue(article.markdown.contains("第一段正文"))
    XCTAssertTrue(article.markdown.contains("## 关键结论"))
    XCTAssertTrue(article.markdown.contains("- 保留列表"))
    XCTAssertTrue(article.markdown.contains("> 保留引用"))
    XCTAssertTrue(article.markdown.contains(
      "![图示说明](https://pbs.twimg.com/media/article.png)"
    ))
    XCTAssertFalse(article.markdown.contains("evil.test"))
  }

  func testXArticleCoverMediaIsPrependedAndNotDuplicated() throws {
    let cover = "https://pbs.twimg.com/media/COVER.jpg"
    let inline = "https://pbs.twimg.com/media/INLINE.png"
    let json = """
    {
      "data": {"tweetResult": {"result": {
        "article": {"article_results": {"result": {
          "title": "带封面的文章",
          "cover_media": {"media_info": {
            "original_img_url": "\(cover)"
          }},
          "content_state": {
            "blocks": [
              {"type": "unstyled", "text": "第一段", "entityRanges": []},
              {"type": "atomic", "text": " ", "entityRanges": [{"key": 0, "offset": 0, "length": 1}]}
            ],
            "entityMap": [
              {"key": "0", "value": {"type": "MEDIA", "data": {
                "mediaItems": [{"mediaId": "7"}]
              }}}
            ]
          },
          "media_entities": [
            {"media_id": "7", "media_info": {"original_img_url": "\(inline)"}}
          ]
        }}}
      }}}
    }
    """
    let article = try XCTUnwrap(XTweetResolver.articleContentFromGraphQL(Data(json.utf8)))
    XCTAssertTrue(article.markdown.hasPrefix("![](\(cover))"))
    XCTAssertTrue(article.markdown.contains("第一段"))
    XCTAssertTrue(article.markdown.contains("![](\(inline))"))
    XCTAssertEqual(article.markdown.components(separatedBy: cover).count - 1, 1)

    let duplicateCoverJSON = """
    {
      "data": {"tweetResult": {"result": {
        "article": {"article_results": {"result": {
          "title": "封面也在正文里",
          "cover_media": {"media_info": {
            "original_img_url": "\(cover)"
          }},
          "content_state": {
            "blocks": [
              {"type": "atomic", "text": " ", "entityRanges": [{"key": 0, "offset": 0, "length": 1}]}
            ],
            "entityMap": [
              {"key": "0", "value": {"type": "MEDIA", "data": {
                "mediaItems": [{"mediaId": "9"}]
              }}}
            ]
          },
          "media_entities": [
            {"media_id": "9", "media_info": {"original_img_url": "\(cover)"}}
          ]
        }}}
      }}}
    }
    """
    let deduped = try XCTUnwrap(XTweetResolver.articleContentFromGraphQL(Data(duplicateCoverJSON.utf8)))
    XCTAssertEqual(deduped.markdown.components(separatedBy: cover).count - 1, 1)
  }

  func testSyndicationArticlePreviewKeepsTheCover() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data("""
      {
        "text": "文章入口",
        "article": {
          "rest_id": "1",
          "title": "预览标题",
          "preview_text": "第一段预览",
          "cover_media": {"media_info": {
            "original_img_url": "https://pbs.twimg.com/media/HQwC9-zb0AAnbz2.jpg"
          }}
        }
      }
      """.utf8)
    )
    XCTAssertEqual(
      XTweetResolver.coverURL(from: payload.article),
      "https://pbs.twimg.com/media/HQwC9-zb0AAnbz2.jpg"
    )
    let markdown = XTweetResolver.prependArticleCover(
      payload.article?.preview_text ?? "",
      coverURL: XTweetResolver.coverURL(from: payload.article)
    )
    XCTAssertTrue(markdown.hasPrefix("![](https://pbs.twimg.com/media/HQwC9-zb0AAnbz2.jpg)"))
    XCTAssertTrue(markdown.contains("第一段预览"))
  }

  func testXArticleBodyReplacesTheLauncherTweet() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(#"{"text":"文章入口 https://t.co/short","user":{"name":"作者","screen_name":"writer"}}"#.utf8)
    )
    let article = XArticleContent(
      title: "文章自己的标题",
      markdown: "完整正文第一段\n\n## 第二节",
      isComplete: true
    )
    let tweet = try XCTUnwrap(
      XTweetResolver.tweet(
        from: payload,
        id: "2081645581379031509",
        articleContent: article
      )
    )

    XCTAssertEqual(tweet.title, "文章自己的标题")
    XCTAssertTrue(tweet.markdownBody.contains("完整正文第一段"))
    XCTAssertFalse(tweet.markdownBody.contains("文章入口"))
    let document = tweet.capturedDocument(createdAt: "2026-07-28T08:00:00Z")
    XCTAssertEqual(document.completeness, "full_article")
    XCTAssertEqual(document.sourceLabel, "X public article endpoint")
  }

  func testResolveTweetFetchesArticleRichContentWithoutCookies() async throws {
    let resources = XTweetFixtureResourceFetcher(
      syndication: """
      {
        "text": "入口短帖 https://t.co/short",
        "user": {"name": "作者", "screen_name": "writer"},
        "article": {
          "rest_id": "2081635007739604992",
          "title": "接口预览标题",
          "preview_text": "接口只给的预览"
        }
      }
      """,
      graphQL: """
      {"data":{"tweetResult":{"result":{"article":{"article_results":{"result":{
        "title":"GraphQL 完整标题",
        "content_state":{
          "blocks":[{"type":"unstyled","text":"GraphQL 完整正文","entityRanges":[]}],
          "entityMap":[]
        },
        "media_entities":[]
      }}}}}}}
      """
    )

    let resolved = await XTweetResolver(resources: resources)
      .resolveTweet(id: "2081645581379031509")
    let tweet = try XCTUnwrap(resolved)
    XCTAssertEqual(tweet.title, "GraphQL 完整标题")
    XCTAssertTrue(tweet.markdownBody.contains("GraphQL 完整正文"))
    XCTAssertFalse(tweet.markdownBody.contains("入口短帖"))

    let requests = resources.requests
    XCTAssertEqual(requests.count, 3)
    let graphQLRequest = try XCTUnwrap(
      requests.first { $0.url.path.hasSuffix("/TweetResultByRestId") }
    )
    XCTAssertTrue(
      graphQLRequest.url.absoluteString.contains("withArticleRichContentState")
    )
    XCTAssertNil(graphQLRequest.headers["Cookie"])
    XCTAssertNil(graphQLRequest.headers["cookie"])
  }

  /// GraphQL 全文常不含 cover_media；封面只在 syndication 的 article.cover_media。
  /// 以前用 GraphQL 结果整份覆盖预览后封面就丢了。
  func testResolveTweetKeepsSyndicationCoverWhenGraphQLOmitsIt() async throws {
    let cover = "https://pbs.twimg.com/media/HRIkm6IaAAErbRr.jpg"
    let resources = XTweetFixtureResourceFetcher(
      syndication: """
      {
        "text": "入口短帖",
        "user": {"name": "LanLance", "screen_name": "LanLance24"},
        "article": {
          "rest_id": "2094777203984896418",
          "title": "读懂 Warp 的 Agent Skill 自进化机制",
          "preview_text": "预览不会当正文",
          "cover_media": {"media_info": {"original_img_url": "\(cover)"}}
        }
      }
      """,
      graphQL: """
      {"data":{"tweetResult":{"result":{"article":{"article_results":{"result":{
        "title":"读懂 Warp 的 Agent Skill 自进化机制",
        "content_state":{
          "blocks":[{"type":"unstyled","text":"上周 Anthropic 发布了一篇讲 Warp 构建自进化 Agent 的博客。","entityRanges":[]}],
          "entityMap":[]
        },
        "media_entities":[]
      }}}}}}}
      """
    )

    let resolved = await XTweetResolver(resources: resources)
      .resolveTweet(id: "2094777203984896418")
    let tweet = try XCTUnwrap(resolved)
    let body = tweet.markdownBody.replacingOccurrences(
      of: #"^---[\s\S]*?---\n*"#,
      with: "",
      options: .regularExpression
    )
    XCTAssertTrue(body.hasPrefix("![](\(cover))"))
    XCTAssertTrue(body.contains("上周 Anthropic"))
    XCTAssertFalse(body.contains("预览不会当正文"))
  }

  func testArticlePreviewIsNotMarkedAsComplete() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(#"{"text":"文章入口"}"#.utf8)
    )
    let tweet = try XCTUnwrap(
      XTweetResolver.tweet(
        from: payload,
        id: "2081645581379031509",
        articleContent: XArticleContent(
          title: "文章标题",
          markdown: "这里只是公开预览",
          isComplete: false
        )
      )
    )

    XCTAssertEqual(
      tweet.capturedDocument(createdAt: "2026-07-28T08:00:00Z").completeness,
      "visible_only"
    )
  }

  func testOverrideTextReplacesTheTruncatedSyndicationText() throws {
    let json = #"{"text":"截断到这里…","user":{"name":"作者","screen_name":"a"}}"#
    let payload = try JSONDecoder().decode(XTweetResolver.Payload.self, from: Data(json.utf8))
    let full = "完整长文，远比截断预览长，包含后半段所有内容。"
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "1234567890123", overrideText: full))
    XCTAssertTrue(tweet.text == full)
    XCTAssertTrue(tweet.markdownBody.contains(full))
    XCTAssertFalse(tweet.markdownBody.contains("截断到这里"))
  }

  func testTweetWithoutTextOrVideoIsNotWorthStoring() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data("{\"text\": \"   \"}".utf8)
    )
    XCTAssertNil(XTweetResolver.tweet(from: payload, id: "1234567890123"))
  }

  func testTweetWithoutAHandleStillGetsAUsableCanonicalURL() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data("{\"text\": \"内容还在\"}".utf8)
    )
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "1234567890123"))
    XCTAssertEqual(tweet.canonicalURL, "https://x.com/i/status/1234567890123")
    XCTAssertNil(tweet.displayAuthor)
  }

  func testPhotoOnlyTweetYieldsNoMediaInsteadOfAnEmptyURL() throws {
    let json = """
    {"mediaDetails": [{"type": "photo", "media_url_https": "https://pbs.twimg.com/media/abc.jpg"}]}
    """
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(json.utf8)
    )
    XCTAssertNil(XTweetResolver.bestVideo(in: payload, author: nil))
  }

  func testMetricsFromGraphQLReadsLegacyCountsAndStringViewCount() throws {
    let json = """
    {"data":{"tweetResult":{"result":{
      "legacy":{
        "favorite_count":12,
        "reply_count":3,
        "retweet_count":7,
        "quote_count":99,
        "bookmark_count":4
      },
      "views":{"count":"2661117","state":"EnabledWithCount"}
    }}}}
    """
    let metrics = try XCTUnwrap(XTweetResolver.metricsFromGraphQL(Data(json.utf8)))
    XCTAssertEqual(metrics.favoriteCount, 12)
    XCTAssertEqual(metrics.replyCount, 3)
    XCTAssertEqual(metrics.retweetCount, 7)
    XCTAssertEqual(metrics.bookmarkCount, 4)
    XCTAssertEqual(metrics.viewCount, 2_661_117)

    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data(#"{"text":"普通推文","favorite_count":1,"conversation_count":1}"#.utf8)
    )
    let tweet = try XCTUnwrap(
      XTweetResolver.tweet(from: payload, id: "1234567890123", metrics: metrics)
    )
    XCTAssertEqual(tweet.likeCount, 12)
    XCTAssertEqual(tweet.replyCount, 3)
    XCTAssertEqual(tweet.repostCount, 7)
    XCTAssertEqual(tweet.bookmarkCount, 4)
    XCTAssertEqual(tweet.viewCount, 2_661_117)
    let markdown = tweet.markdownBody
    XCTAssertTrue(markdown.contains("likes: \"12\""))
    XCTAssertTrue(markdown.contains("replies: \"3\"\nshares: \"7\"\ncollects: \"4\"\nviews: \"2661117\""))
    XCTAssertFalse(markdown.contains("99"))
  }

  func testArticleInlineStylesAndLinksRespectUTF16Offsets() throws {
    // "看这篇🙂说明即可"：🙂 占 2 个 UTF-16 unit。LINK+BOLD 同时盖住「篇🙂说」
    // （offset 2 / length 4）。若误用 Character 索引，会把「明」也包进去。
    let json = """
    {
      "data": {"tweetResult": {"result": {
        "article": {"article_results": {"result": {
          "title": "富文本",
          "content_state": {
            "blocks": [
              {
                "type": "unstyled",
                "text": "看这篇🙂说明即可",
                "inlineStyleRanges": [{"offset": 2, "length": 4, "style": "BOLD"}],
                "entityRanges": [{"offset": 2, "length": 4, "key": 0}]
              },
              {
                "type": "header-two",
                "text": "小标题",
                "inlineStyleRanges": [{"offset": 0, "length": 3, "style": "ITALIC"}],
                "entityRanges": []
              },
              {
                "type": "unordered-list-item",
                "text": "列表项",
                "inlineStyleRanges": [{"offset": 0, "length": 3, "style": "BOLD"}],
                "entityRanges": []
              },
              {
                "type": "code-block",
                "text": "let x = 1",
                "inlineStyleRanges": [{"offset": 0, "length": 3, "style": "BOLD"}],
                "entityRanges": []
              },
              {
                "type": "unstyled",
                "text": "http 不渲染",
                "inlineStyleRanges": [],
                "entityRanges": [{"offset": 0, "length": 8, "key": 1}]
              }
            ],
            "entityMap": [
              {"key": 0, "value": {"type": "LINK", "data": {"url": "https://example.com/post"}}},
              {"key": 1, "value": {"type": "LINK", "data": {"url": "http://example.com/insecure"}}}
            ]
          },
          "media_entities": []
        }}}
      }}}
    }
    """
    let article = try XCTUnwrap(XTweetResolver.articleContentFromGraphQL(Data(json.utf8)))
    XCTAssertTrue(article.markdown.contains("看这[**篇🙂说**](https://example.com/post)明即可"))
    XCTAssertTrue(article.markdown.contains("## *小标题*"))
    XCTAssertTrue(article.markdown.contains("- **列表项**"))
    XCTAssertTrue(article.markdown.contains("```\nlet x = 1\n```"))
    XCTAssertFalse(article.markdown.contains("**let"))
    XCTAssertTrue(article.markdown.contains("http 不渲染"))
    XCTAssertFalse(article.markdown.contains("http://example.com/insecure"))
  }

  func testArticleInlineRangesOutOfBoundsFallBackToPlainText() throws {
    let json = """
    {
      "data": {"tweetResult": {"result": {
        "article": {"article_results": {"result": {
          "title": "越界",
          "content_state": {
            "blocks": [
              {
                "type": "unstyled",
                "text": "完整文字不能丢",
                "inlineStyleRanges": [{"offset": 0, "length": 2, "style": "BOLD"}],
                "entityRanges": [{"offset": 0, "length": 99, "key": 0}]
              }
            ],
            "entityMap": [
              {"key": 0, "value": {"type": "LINK", "data": {"url": "https://example.com/lost"}}}
            ]
          },
          "media_entities": []
        }}}
      }}}
    }
    """
    let article = try XCTUnwrap(XTweetResolver.articleContentFromGraphQL(Data(json.utf8)))
    XCTAssertTrue(article.markdown.contains("完整文字不能丢"))
    XCTAssertFalse(article.markdown.contains("**"))
    XCTAssertFalse(article.markdown.contains("example.com/lost"))
  }

  func testSyndicationAndNoteTweetExpandTcoURLs() throws {
    let payload = try JSONDecoder().decode(
      XTweetResolver.Payload.self,
      from: Data("""
      {
        "text": "阅读 https://t.co/abc123 和 https://t.co/skip",
        "entities": {
          "urls": [
            {"url": "https://t.co/abc123", "expanded_url": "https://example.com/full"},
            {"url": "https://t.co/skip", "expanded_url": "ftp://example.com/x"}
          ]
        }
      }
      """.utf8)
    )
    let tweet = try XCTUnwrap(XTweetResolver.tweet(from: payload, id: "1234567890123"))
    XCTAssertEqual(tweet.text, "阅读 https://example.com/full 和 https://t.co/skip")

    let noteJSON = """
    {"data":{"tweetResult":{"result":{"note_tweet":{"note_tweet_results":{"result":{
      "text":"长文 https://t.co/note1 结束",
      "entity_set":{"urls":[
        {"url":"https://t.co/note1","expanded_url":"http://example.com/note","display_url":"example.com/note"}
      ]}
    }}}}}}}
    """
    XCTAssertEqual(
      XTweetResolver.noteTextFromGraphQL(Data(noteJSON.utf8)),
      "长文 http://example.com/note 结束"
    )
  }

  func testOrdinaryTweetStillQueriesGraphQLAndFallsBackWhenItFails() async throws {
    let resources = XTweetFixtureResourceFetcher(
      syndication: """
      {
        "text": "只是一条普通推文",
        "favorite_count": 8,
        "conversation_count": 6,
        "user": {"name": "作者", "screen_name": "writer"}
      }
      """,
      graphQL: "{}",
      graphQLStatus: 500
    )

    let resolved = await XTweetResolver(resources: resources)
      .resolveTweet(id: "1234567890123")
    let tweet = try XCTUnwrap(resolved)
    XCTAssertEqual(tweet.text, "只是一条普通推文")
    XCTAssertEqual(tweet.likeCount, 8)
    XCTAssertEqual(tweet.replyCount, 6)
    XCTAssertNil(tweet.repostCount)
    XCTAssertNil(tweet.bookmarkCount)
    XCTAssertNil(tweet.viewCount)
    XCTAssertTrue(tweet.markdownBody.contains("likes: \"8\""))
    XCTAssertTrue(tweet.markdownBody.contains("replies: \"6\""))
    XCTAssertFalse(tweet.markdownBody.contains("shares:"))
    XCTAssertNotNil(resources.requests.first { $0.url.path.hasSuffix("/TweetResultByRestId") })
  }

  func testOrdinaryTweetUsesGraphQLMetricsWhenPresent() async throws {
    let resources = XTweetFixtureResourceFetcher(
      syndication: """
      {
        "text": "只是一条普通推文",
        "favorite_count": 8,
        "conversation_count": 6,
        "user": {"name": "作者", "screen_name": "writer"}
      }
      """,
      graphQL: """
      {"data":{"tweetResult":{"result":{
        "legacy":{
          "favorite_count":21,
          "reply_count":9,
          "retweet_count":5,
          "quote_count":2,
          "bookmark_count":11
        },
        "views":{"count":"42","state":"EnabledWithCount"}
      }}}}
      """
    )

    let resolved = await XTweetResolver(resources: resources)
      .resolveTweet(id: "1234567890123")
    let tweet = try XCTUnwrap(resolved)
    XCTAssertEqual(tweet.text, "只是一条普通推文")
    XCTAssertEqual(tweet.likeCount, 21)
    XCTAssertEqual(tweet.replyCount, 9)
    XCTAssertEqual(tweet.repostCount, 5)
    XCTAssertEqual(tweet.bookmarkCount, 11)
    XCTAssertEqual(tweet.viewCount, 42)
    XCTAssertTrue(tweet.markdownBody.contains("shares: \"5\""))
    XCTAssertFalse(tweet.markdownBody.contains("quote"))
  }
}
