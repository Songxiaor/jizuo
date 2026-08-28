import Foundation
import LinkDigestCore

struct XArticleContent: Sendable, Equatable {
  let title: String
  let markdown: String
  let isComplete: Bool
}

/// 一条已解析的推文。字段与浏览器扩展抓取 X 帖子时产出的结构保持一致，
/// 这样两条来源落库后读起来是同一种东西。
public struct ResolvedTweet: Sendable, Equatable {
  public let id: String
  public let text: String
  public let authorName: String?
  public let authorHandle: String?
  /// ISO8601，端点原样返回。
  public let publishedAt: String?
  public let likeCount: Int?
  public let replyCount: Int?
  public let photoURLs: [String]
  public let video: CaptureMedia?
  /// 被引用推文的正文与作者。X 的引用是帖子内容的一部分（常见于自引用长串），
  /// 丢掉它会让正文看起来「只有一半」。
  public let quotedText: String?
  public let quotedAuthor: String?
  public let quotedPhotoURLs: [String]
  /// 被引用推文的原文链接，供引用卡底部「查看原推」。
  public let quotedURL: String?
  /// X Article 的标题与正文。文章由一条普通推文承载，syndication 的 `text`
  /// 只是入口文案；不能把它当作文章正文。
  public let articleTitle: String?
  public let articleMarkdown: String?
  public let isArticleComplete: Bool

  public var canonicalURL: String {
    guard let handle = authorHandle, !handle.isEmpty else {
      return "https://x.com/i/status/\(id)"
    }
    return "https://x.com/\(handle)/status/\(id)"
  }

  public var displayAuthor: String? {
    switch (authorName, authorHandle) {
    case let (name?, handle?): return "\(name) (@\(handle))"
    case let (name?, nil): return name
    case let (nil, handle?): return "@\(handle)"
    default: return nil
    }
  }

  /// 正文首行作为标题——与扩展侧一致：帖子没有独立标题，第一句就是标题。
  public var title: String {
    if let articleTitle {
      let value = articleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    let firstLine = text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    return firstLine.isEmpty ? "X 帖子" : firstLine
  }

  /// 与扩展抓取产出的 markdown 同构：frontmatter + 正文 + 内联图片。
  /// 视频不进正文（它走 media 通道由 App 下载），封面帧同理。
  public var markdownBody: String {
    var lines = ["---"]
    if let author = displayAuthor { lines.append("author: \(quoted(author))") }
    if let publishedAt { lines.append("published: \(quoted(publishedAt))") }
    if let likeCount { lines.append("likes: \(quoted(String(likeCount)))") }
    if let replyCount { lines.append("replies: \(quoted(String(replyCount)))") }
    lines.append("---")
    let header = lines.joined(separator: "\n")
    let gallery = photoURLs.map { "![](\($0))" }.joined(separator: "\n\n")
    let primaryText = articleMarkdown.flatMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    } ?? text

    // 引用推文以一个可解析的标记块输出，阅读区把它渲染成仿 X 原生的引用卡
    // （带边框、被引作者加粗、正文正常颜色、图片在卡内、底部原推链接）。图片以
    // `![]()` 放在块内，既进得了图片下载队列，又被卡片渲染器就地取用。
    var quotedBlock = ""
    if let quotedText, !quotedText.isEmpty {
      let attribute = { (value: String?) in
        (value ?? "").replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
      }
      var inner = [quotedText]
      inner.append(contentsOf: quotedPhotoURLs.map { "![](\($0))" })
      quotedBlock = "<!--LDQUOTE author=\"\(attribute(quotedAuthor))\" url=\"\(attribute(quotedURL))\"-->\n"
        + inner.joined(separator: "\n\n")
        + "\n<!--/LDQUOTE-->"
    }

    return ([header, primaryText, gallery, quotedBlock]
      .filter { !$0.isEmpty }).joined(separator: "\n\n")
  }

  /// 落库用的文档。与浏览器捕获同构，因此收藏夹同步进来的条目和你手动发送的
  /// 条目在库里是同一种东西：同样的 platform、同样的正文结构、同样的媒体通道。
  public func capturedDocument(createdAt: String) -> CapturedDocument {
    CapturedDocument(
      createdAt: createdAt,
      origin: .manualLink,
      url: canonicalURL,
      title: title,
      platform: "x",
      method: "rendered_dom",
      text: markdownBody,
      completeness: articleTitle == nil || isArticleComplete ? "full_article" : "visible_only",
      capturedAt: createdAt,
      sourceLabel: articleTitle == nil ? "X syndication endpoint" : "X public article endpoint",
      usedCookie: false,
      media: video
    )
  }

  private func quoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}

/// X 用 MSE 播放视频，页面里的 `<video>` 只有 `blob:` 地址，抓取侧拿不到任何
/// 可下载的源——这正是捕获结果一直停在「只能在原浏览器会话观看」的原因。
///
/// 嵌入式推文用的公开端点会返回整条推文：正文、作者、时间、图片与真实直链
/// MP4。它不需要登录态，也不需要发送 cookie，所以这条路径不会扩大凭据面。
/// 端点是 X 给第三方嵌入用的非文档化接口：若它变更或下线，解析失败即回到原
/// 来的诚实提示，不影响正文与其余捕获结果。
public struct XTweetResolver: Sendable {
  private let resources: any SafeResourceFetching
  /// 推文元数据是小 JSON；给一个宽裕但有界的上限。
  private static let maximumBodyBytes = 512 * 1024
  /// X Article 的富文本状态会明显大于普通推文，但仍保持明确上限。
  private static let maximumGraphQLBodyBytes = 2 * 1024 * 1024

  public init(resources: any SafeResourceFetching) {
    self.resources = resources
  }

  /// 从推文地址里取出数字 id。只认 x.com / twitter.com 的 status 路径。
  public static func tweetID(from rawURL: String) -> String? {
    XBookmarksSyncRequest.tweetID(fromCanonicalURL: rawURL)
  }

  public static func isValidTweetID(_ value: String) -> Bool {
    XBookmarksSyncRequest.isValidTweetID(value)
  }

  /// 直链只接受 X 自己的视频 CDN，且必须是 https 标准端口。
  public static func isAllowedVideoURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return false }
    return host == "video.twimg.com" || host.hasSuffix(".video.twimg.com")
  }

  /// 正文图片只接受 X 的图片 CDN。
  public static func isAllowedPhotoURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return false }
    return host == "pbs.twimg.com" || host.hasSuffix(".pbs.twimg.com")
  }

  public func resolveTweet(id: String) async -> ResolvedTweet? {
    guard Self.isValidTweetID(id),
          var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")
    else { return nil }
    components.queryItems = [
      .init(name: "id", value: id),
      // 端点要求带一个 token 参数，但不校验其取值。
      .init(name: "token", value: "a"),
      .init(name: "lang", value: "en"),
    ]
    guard let endpoint = components.url else { return nil }

    guard let response = try? await resources.fetchResource(
      .init(
        url: endpoint,
        headers: ["Accept": "application/json"],
        byteLimit: Self.maximumBodyBytes,
        allowsRedirectTarget: { url in
          (url.host?.lowercased()).map { $0 == "cdn.syndication.twimg.com" } ?? false
        }
      )
    ), (200...299).contains(response.statusCode) else { return nil }

    guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else { return nil }

    // 原生长推文和 X Article 都只在 syndication 留一个入口。用同一个匿名
    // TweetResultByRestId 请求补齐；取不到时保留可用预览，不伪装成全文。
    var fullText: String?
    var article = payload.article.flatMap(Self.previewArticle)
    if payload.note_tweet != nil || payload.article != nil,
       let richContent = await richContent(id: id) {
      fullText = richContent.noteText
      article = richContent.article ?? article
    }
    return Self.tweet(
      from: payload,
      id: id,
      overrideText: fullText,
      articleContent: article
    )
  }

  // MARK: - 长推文全文（逆向 GraphQL，会随 X 改版失效，失效即降级回 syndication）

  /// X 网页端公开 bearer（对所有匿名会话固定，非用户凭据）。
  private static let webBearer =
    "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
  /// TweetResultByRestId 的 GraphQL query id。**X 会不定期轮换，失效后长推文
  /// 会降级回截断版；更新此值即可恢复。**
  private static let tweetResultQueryID = "LkId5Akr61BS6BmOIcffRg"

  private struct GraphQLRichContent {
    let noteText: String?
    let article: XArticleContent?
  }

  private func richContent(id: String) async -> GraphQLRichContent? {
    guard let token = await activateGuestToken() else { return nil }
    let variables = "{\"tweetId\":\"\(id)\",\"withCommunity\":false,\"includePromotedContent\":false,\"withVoice\":false}"
    let features = Self.graphQLFeatures
    let fieldToggles =
      "{\"withArticleRichContentState\":true,\"withArticlePlainText\":false,\"withArticleSummaryText\":true,\"withArticleVoiceOver\":true}"
    // 只保留 URL query 里绝对安全的字符，其余全转义（{ } " : , 都要转）。
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    guard let vEnc = variables.addingPercentEncoding(withAllowedCharacters: allowed),
          let fEnc = features.addingPercentEncoding(withAllowedCharacters: allowed),
          let tEnc = fieldToggles.addingPercentEncoding(withAllowedCharacters: allowed),
          let url = URL(
            string: "https://api.x.com/graphql/\(Self.tweetResultQueryID)/TweetResultByRestId?variables=\(vEnc)&features=\(fEnc)&fieldToggles=\(tEnc)"
          )
    else { return nil }

    guard let response = try? await resources.fetchResource(
      .init(
        url: url,
        headers: [
          "Authorization": "Bearer \(Self.webBearer)",
          "x-guest-token": token,
          "Accept": "application/json",
        ],
        byteLimit: Self.maximumGraphQLBodyBytes,
        allowsRedirectTarget: { $0.host?.lowercased() == "api.x.com" }
      )
    ), (200...299).contains(response.statusCode) else { return nil }

    let noteText = Self.noteTextFromGraphQL(response.body)
    let article = Self.articleContentFromGraphQL(response.body)
    guard noteText != nil || article != nil else { return nil }
    return GraphQLRichContent(noteText: noteText, article: article)
  }

  private func activateGuestToken() async -> String? {
    guard let url = URL(string: "https://api.x.com/1.1/guest/activate.json") else { return nil }
    guard let response = try? await resources.fetchResource(
      .init(
        url: url,
        headers: ["Authorization": "Bearer \(Self.webBearer)", "Accept": "application/json"],
        byteLimit: 8 * 1024,
        method: "POST",
        allowsRedirectTarget: { $0.host?.lowercased() == "api.x.com" }
      )
    ), (200...299).contains(response.statusCode) else { return nil }
    struct Activate: Decodable { let guest_token: String? }
    let token = (try? JSONDecoder().decode(Activate.self, from: response.body))?.guest_token
    guard let token, token.allSatisfy(\.isNumber), (8...25).contains(token.count) else { return nil }
    return token
  }

  /// 从 GraphQL 响应里挖出 note tweet 全文。结构很深且会变，用宽松的 JSON 遍历
  /// 而不是钉死 Decodable：找到第一个 `note_tweet_results.result.text`。
  static func noteTextFromGraphQL(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
    func search(_ node: Any) -> String? {
      if let dict = node as? [String: Any] {
        if let results = dict["note_tweet_results"] as? [String: Any],
           let result = results["result"] as? [String: Any],
           let text = result["text"] as? String, !text.isEmpty {
          return text
        }
        for value in dict.values { if let found = search(value) { return found } }
      } else if let array = node as? [Any] {
        for value in array { if let found = search(value) { return found } }
      }
      return nil
    }
    return search(root)
  }

  /// X Article 的 `content_state` 是 Draft.js 风格块数组。这里不依赖整份
  /// GraphQL 类型，只提取文章结果，并把常用块转换成可迁移的 Markdown。
  static func articleContentFromGraphQL(_ data: Data) -> XArticleContent? {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

    func articleResult(in node: Any) -> [String: Any]? {
      if let dictionary = node as? [String: Any] {
        if let results = dictionary["article_results"] as? [String: Any],
           let result = results["result"] as? [String: Any] {
          return result
        }
        for value in dictionary.values {
          if let found = articleResult(in: value) { return found }
        }
      } else if let array = node as? [Any] {
        for value in array {
          if let found = articleResult(in: value) { return found }
        }
      }
      return nil
    }

    guard let result = articleResult(in: root),
          let contentState = result["content_state"] as? [String: Any],
          let blocks = contentState["blocks"] as? [[String: Any]]
    else { return nil }

    var mediaURLByID: [String: String] = [:]
    for entity in result["media_entities"] as? [[String: Any]] ?? [] {
      guard let mediaID = stringValue(entity["media_id"]),
            let mediaInfo = entity["media_info"] as? [String: Any],
            let rawURL = mediaInfo["original_img_url"] as? String,
            isAllowedPhotoURL(rawURL)
      else { continue }
      mediaURLByID[mediaID] = rawURL
    }

    var embeddedMedia: [Int: (url: String, caption: String?)] = [:]
    for entity in contentState["entityMap"] as? [[String: Any]] ?? [] {
      guard let key = intValue(entity["key"]),
            let value = entity["value"] as? [String: Any],
            (value["type"] as? String)?.uppercased() == "MEDIA",
            let metadata = value["data"] as? [String: Any],
            let items = metadata["mediaItems"] as? [[String: Any]],
            let mediaID = items.compactMap({ stringValue($0["mediaId"]) }).first,
            let mediaURL = mediaURLByID[mediaID]
      else { continue }
      let caption = (metadata["caption"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      embeddedMedia[key] = (mediaURL, caption.flatMap { $0.isEmpty ? nil : $0 })
    }

    var rendered: [String] = []
    for block in blocks {
      let type = (block["type"] as? String)?.lowercased() ?? "unstyled"
      let text = (block["text"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if type == "atomic" {
        let key = (block["entityRanges"] as? [[String: Any]])?
          .compactMap { intValue($0["key"]) }
          .first
        guard let key, let media = embeddedMedia[key] else { continue }
        let alt = (media.caption ?? "")
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "]", with: "\\]")
          .replacingOccurrences(of: "\n", with: " ")
        rendered.append("![\(alt)](\(media.url))")
        continue
      }

      guard !text.isEmpty else { continue }
      switch type {
      case "header-one":
        rendered.append("# \(text)")
      case "header-two":
        rendered.append("## \(text)")
      case "header-three":
        rendered.append("### \(text)")
      case "header-four":
        rendered.append("#### \(text)")
      case "blockquote":
        rendered.append(text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n"))
      case "unordered-list-item":
        rendered.append("- \(text)")
      case "ordered-list-item":
        rendered.append("1. \(text)")
      case "code-block":
        rendered.append("```\n\(text)\n```")
      default:
        rendered.append(text)
      }
    }

    let markdown = rendered.joined(separator: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { return nil }
    let rawTitle = (result["title"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "X 文章"
    return XArticleContent(title: title, markdown: markdown, isComplete: true)
  }

  private static func previewArticle(_ marker: Payload.ArticleMarker) -> XArticleContent? {
    let preview = marker.preview_text?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = marker.title?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !preview.isEmpty || !title.isEmpty else { return nil }
    let resolvedTitle = title.isEmpty
      ? (preview.split(separator: "\n").first.map(String.init) ?? "X 文章")
      : title
    return XArticleContent(title: resolvedTitle, markdown: preview, isComplete: false)
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static let graphQLFeatures =
    "{\"creator_subscriptions_tweet_preview_api_enabled\":true,\"tweetypie_unmention_optimization_enabled\":true,\"responsive_web_edit_tweet_api_enabled\":true,\"graphql_is_translatable_rweb_tweet_is_translatable_enabled\":true,\"view_counts_everywhere_api_enabled\":true,\"longform_notetweets_consumption_enabled\":true,\"responsive_web_twitter_article_tweet_consumption_enabled\":true,\"tweet_awards_web_tipping_enabled\":false,\"freedom_of_speech_not_reach_fetch_enabled\":true,\"standardized_nudges_misinfo\":true,\"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled\":true,\"longform_notetweets_rich_text_read_enabled\":true,\"longform_notetweets_inline_media_enabled\":true,\"responsive_web_graphql_exclude_directive_enabled\":true,\"verified_phone_label_enabled\":false,\"responsive_web_media_download_video_enabled\":false,\"responsive_web_graphql_skip_user_profile_image_extensions_enabled\":false,\"responsive_web_graphql_timeline_navigation_enabled\":true,\"responsive_web_enhance_cards_enabled\":false}"

  /// 兼容既有调用点：捕获到 blob/MSE 的 X 视频时只要 media。
  public func resolveVideo(tweetID: String, author: String?) async -> CaptureMedia? {
    guard let tweet = await resolveTweet(id: tweetID) else { return nil }
    guard let video = tweet.video else { return nil }
    // 调用方已有作者信息时以它为准，避免与既有条目显示不一致。
    guard let author, !author.isEmpty else { return video }
    return CaptureMedia(
      platform: video.platform,
      videoURL: video.videoURL,
      coverURL: video.coverURL,
      durationSeconds: video.durationSeconds,
      author: author
    )
  }

  static func tweet(
    from payload: Payload,
    id: String,
    overrideText: String? = nil,
    articleContent: XArticleContent? = nil
  ) -> ResolvedTweet? {
    let syndicationText = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // 长推文全文优先（syndication 的 text 只是截断预览）；取不到就用截断版。
    let text = (overrideText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? syndicationText
    let video = bestVideo(in: payload, author: payload.user?.name)
    // 正文为空且没有视频，说明这条推文没有任何可留存的内容。
    guard !text.isEmpty || video != nil else { return nil }
    // `photos` 的语义就是照片；视频封面只出现在 mediaDetails 里，不会混进来。
    let photos = (payload.photos ?? [])
      .compactMap(\.url)
      .filter(isAllowedPhotoURL)
    // 引用推文：取正文、作者、图片与原推链接。引用的视频不取（避免把被引内容
    // 的媒体误当成本帖的媒体去下载），只保留可内联展示的图。
    let quoted = payload.quoted_tweet
    let quotedText = quoted?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let quotedHandle = quoted?.user?.screen_name
    let quotedAuthor = quoted?.user.map { author -> String in
      switch (author.name, author.screen_name) {
      case let (name?, handle?): return "\(name) (@\(handle))"
      case let (name?, nil): return name
      case let (nil, handle?): return "@\(handle)"
      default: return ""
      }
    }.flatMap { $0.isEmpty ? nil : $0 }
    let quotedPhotos = (quoted?.photos ?? []).compactMap(\.url).filter(isAllowedPhotoURL)
    let quotedURL: String? = {
      guard let quotedID = quoted?.id_str, isValidTweetID(quotedID) else { return nil }
      if let handle = quotedHandle, !handle.isEmpty { return "https://x.com/\(handle)/status/\(quotedID)" }
      return "https://x.com/i/status/\(quotedID)"
    }()

    return ResolvedTweet(
      id: id,
      text: text,
      authorName: payload.user?.name,
      authorHandle: payload.user?.screen_name,
      publishedAt: payload.created_at,
      likeCount: payload.favorite_count,
      replyCount: payload.conversation_count,
      photoURLs: photos,
      video: video,
      quotedText: (quotedText?.isEmpty ?? true) ? nil : quotedText,
      quotedAuthor: quotedAuthor,
      quotedPhotoURLs: quotedPhotos,
      quotedURL: quotedURL,
      articleTitle: articleContent?.title,
      articleMarkdown: articleContent?.markdown,
      isArticleComplete: articleContent?.isComplete ?? false
    )
  }

  /// 挑码率最高的 MP4。HLS 变体（m3u8）对本地留存无用，直接跳过。
  static func bestVideo(in payload: Payload, author: String?) -> CaptureMedia? {
    let details = (payload.mediaDetails ?? []) + (payload.video.map { [$0] } ?? [])
    var best: (bitrate: Int, url: String)?
    var cover: String?
    var durationSeconds: Double?
    for detail in details {
      if cover == nil, let still = detail.media_url_https, isAllowedPhotoURL(still) { cover = still }
      guard let info = detail.video_info else { continue }
      if durationSeconds == nil, let millis = info.duration_millis, millis > 0 {
        durationSeconds = millis / 1_000
      }
      for variant in info.variants ?? [] {
        guard variant.content_type?.lowercased() == "video/mp4",
              let raw = variant.url, isAllowedVideoURL(raw)
        else { continue }
        let bitrate = variant.bitrate ?? 0
        if best == nil || bitrate > best!.bitrate { best = (bitrate, raw) }
      }
    }
    guard let best else { return nil }
    return CaptureMedia(
      platform: "x",
      videoURL: best.url,
      coverURL: cover,
      durationSeconds: durationSeconds,
      author: author
    )
  }

  struct Payload: Decodable {
    struct Variant: Decodable {
      let bitrate: Int?
      let content_type: String?
      let url: String?
    }
    struct VideoInfo: Decodable {
      let duration_millis: Double?
      let variants: [Variant]?
    }
    struct MediaDetail: Decodable {
      let type: String?
      let media_url_https: String?
      let video_info: VideoInfo?
    }
    struct Photo: Decodable {
      let url: String?
    }
    struct User: Decodable {
      let name: String?
      let screen_name: String?
    }
    struct QuotedTweet: Decodable {
      let text: String?
      let user: User?
      let photos: [Photo]?
      let id_str: String?
    }
    let text: String?
    let created_at: String?
    let favorite_count: Int?
    let conversation_count: Int?
    let user: User?
    let photos: [Photo]?
    let mediaDetails: [MediaDetail]?
    /// 单视频推文另有一个顶层字段，形状与 mediaDetails 元素一致。
    let video: MediaDetail?
    /// 被引用的推文（引用转发）。
    let quoted_tweet: QuotedTweet?
    /// 原生长推文（note tweet）的存在标记。它一旦出现，`text` 只是被截断的
    /// 前几百字预览，全文得另走 GraphQL 取。
    struct NoteMarker: Decodable { let id: String? }
    let note_tweet: NoteMarker?
    /// X Article 的公开预览。完整正文位于 TweetResultByRestId 的
    /// `article_results.result.content_state`。
    struct ArticleMarker: Decodable {
      let rest_id: String?
      let title: String?
      let preview_text: String?
    }
    let article: ArticleMarker?
  }
}
