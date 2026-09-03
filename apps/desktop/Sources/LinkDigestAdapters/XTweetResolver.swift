import Foundation
import LinkDigestCore

struct XArticleContent: Sendable, Equatable {
  let title: String
  let markdown: String
  let isComplete: Bool
}

/// GraphQL `legacy` / `views` 里的互动数字。`quote_count` 故意不收入：
/// 产品把 `shares` 只对应转发（retweet），不和引用次数混在一起。
struct XTweetMetrics: Sendable, Equatable {
  let favoriteCount: Int?
  let replyCount: Int?
  let retweetCount: Int?
  let bookmarkCount: Int?
  let viewCount: Int?
}

/// 同一 resolver 实例内复用 guest token；401/403 时清掉再取一次。
private actor GuestTokenCache {
  private var token: String?

  func current() -> String? { token }

  func store(_ value: String) { token = value }

  func clear() { token = nil }
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
  public let repostCount: Int?
  public let bookmarkCount: Int?
  public let viewCount: Int?

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
    if let repostCount { lines.append("shares: \(quoted(String(repostCount)))") }
    if let bookmarkCount { lines.append("collects: \(quoted(String(bookmarkCount)))") }
    if let viewCount { lines.append("views: \(quoted(String(viewCount)))") }
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
  private let tokenCache: GuestTokenCache
  /// 推文元数据是小 JSON；给一个宽裕但有界的上限。
  private static let maximumBodyBytes = 512 * 1024
  /// X Article 的富文本状态会明显大于普通推文，但仍保持明确上限。
  private static let maximumGraphQLBodyBytes = 2 * 1024 * 1024

  public init(resources: any SafeResourceFetching) {
    self.resources = resources
    self.tokenCache = GuestTokenCache()
  }

  /// 从推文地址里取出数字 id。只认 x.com / twitter.com 的 status 路径。
  public static func tweetID(from rawURL: String) -> String? {
    guard let url = URL(string: rawURL),
          url.scheme?.lowercased() == "https",
          let rawHost = url.host?.lowercased()
    else { return nil }
    let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
    guard host == "x.com" || host == "twitter.com" else { return nil }
    let parts = url.pathComponents
    guard let marker = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }) else { return nil }
    let next = parts.index(after: marker)
    guard next < parts.endIndex else { return nil }
    return isValidTweetID(parts[next]) ? parts[next] : nil
  }

  public static func isValidTweetID(_ value: String) -> Bool {
    (8...25).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
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

    // 每条推文都走一次匿名 TweetResultByRestId：补互动数字，长推文/文章
    // 再顺手取全文。失败时正文、图片、视频全部保留 syndication，不假装成功。
    var fullText: String?
    var article = payload.article.flatMap(Self.previewArticle)
    var metrics: XTweetMetrics?
    if let richContent = await richContent(id: id) {
      fullText = richContent.noteText
      article = richContent.article ?? article
      metrics = richContent.metrics
    }
    // 封面在 article.cover_media，不在正文块里。GraphQL 全文若没带上，
    // 仍用 syndication 这份封面补到文首，避免只剩中间插图。
    if let current = article {
      article = XArticleContent(
        title: current.title,
        markdown: Self.prependArticleCover(current.markdown, coverURL: Self.coverURL(from: payload.article)),
        isComplete: current.isComplete
      )
    }
    return Self.tweet(
      from: payload,
      id: id,
      overrideText: fullText,
      articleContent: article,
      metrics: metrics
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
    let metrics: XTweetMetrics?
  }

  private func richContent(id: String) async -> GraphQLRichContent? {
    await fetchRichContent(id: id, retryOnAuthFailure: true)
  }

  private func fetchRichContent(id: String, retryOnAuthFailure: Bool) async -> GraphQLRichContent? {
    guard let token = await cachedGuestToken() else { return nil }
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
    ) else { return nil }

    if response.statusCode == 401 || response.statusCode == 403 {
      await tokenCache.clear()
      if retryOnAuthFailure {
        return await fetchRichContent(id: id, retryOnAuthFailure: false)
      }
      return nil
    }
    guard (200...299).contains(response.statusCode) else { return nil }

    let noteText = Self.noteTextFromGraphQL(response.body)
    let article = Self.articleContentFromGraphQL(response.body)
    let metrics = Self.metricsFromGraphQL(response.body)
    guard noteText != nil || article != nil || metrics != nil else { return nil }
    return GraphQLRichContent(noteText: noteText, article: article, metrics: metrics)
  }

  private func cachedGuestToken() async -> String? {
    if let token = await tokenCache.current() { return token }
    guard let token = await activateGuestToken() else { return nil }
    await tokenCache.store(token)
    return token
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
          return expandShortURLs(text, urls: urlsFromEntitySet(result["entity_set"]))
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
    var linkURLByKey: [Int: String] = [:]
    for entity in contentState["entityMap"] as? [[String: Any]] ?? [] {
      guard let key = intValue(entity["key"]),
            let value = entity["value"] as? [String: Any],
            let entityType = (value["type"] as? String)?.uppercased()
      else { continue }
      if entityType == "MEDIA" {
        guard let metadata = value["data"] as? [String: Any],
              let items = metadata["mediaItems"] as? [[String: Any]],
              let mediaID = items.compactMap({ stringValue($0["mediaId"]) }).first,
              let mediaURL = mediaURLByID[mediaID]
        else { continue }
        let caption = (metadata["caption"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        embeddedMedia[key] = (mediaURL, caption.flatMap { $0.isEmpty ? nil : $0 })
      } else if entityType == "LINK" {
        let raw = ((value["data"] as? [String: Any])?["url"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw.lowercased().hasPrefix("https://") else { continue }
        linkURLByKey[key] = raw
      }
    }

    var rendered: [String] = []
    for block in blocks {
      let type = (block["type"] as? String)?.lowercased() ?? "unstyled"
      let rawText = block["text"] as? String ?? ""

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

      let formatted: String
      if type == "code-block" {
        formatted = rawText
      } else {
        formatted = renderDraftInline(
          text: rawText,
          entityRanges: block["entityRanges"] as? [[String: Any]] ?? [],
          inlineStyleRanges: block["inlineStyleRanges"] as? [[String: Any]] ?? [],
          linkURLByKey: linkURLByKey
        )
      }
      let text = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
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

    let markdown = Self.prependArticleCover(
      rendered.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
      coverURL: Self.coverURL(from: result["cover_media"] as? [String: Any])
    )
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
    return XArticleContent(
      title: resolvedTitle,
      markdown: prependArticleCover(preview, coverURL: coverURL(from: marker)),
      isComplete: false
    )
  }

  /// 文章封面：`cover_media.media_info.original_img_url`，与正文插图不是同一条路径。
  static func coverURL(from media: [String: Any]?) -> String? {
    guard let media else { return nil }
    let info = media["media_info"] as? [String: Any]
    let candidates = [
      info?["original_img_url"] as? String,
      (info?["preview_image"] as? [String: Any])?["original_img_url"] as? String,
    ]
    return candidates.compactMap { $0 }.first { isAllowedPhotoURL($0) }
  }

  static func coverURL(from marker: Payload.ArticleMarker?) -> String? {
    guard let raw = marker?.cover_media?.media_info?.original_img_url else { return nil }
    return isAllowedPhotoURL(raw) ? raw : nil
  }

  static func prependArticleCover(_ markdown: String, coverURL: String?) -> String {
    guard let coverURL, isAllowedPhotoURL(coverURL) else { return markdown }
    let key = photoDedupeKey(coverURL)
    if markdown.contains(coverURL) || markdown.contains(key) { return markdown }
    let image = "![](\(coverURL))"
    let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? image : "\(image)\n\n\(trimmed)"
  }

  static func photoDedupeKey(_ rawURL: String) -> String {
    guard let url = URL(string: rawURL) else { return rawURL }
    let last = url.path.split(separator: "/").last.map(String.init) ?? rawURL
    if let dot = last.lastIndex(of: ".") { return String(last[..<dot]) }
    return last
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

  /// 从 `data.tweetResult.result` 取互动数字。`views.count` 在线上是字符串。
  static func metricsFromGraphQL(_ data: Data) -> XTweetMetrics? {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

    func tweetResultNode(_ node: Any) -> [String: Any]? {
      if let dictionary = node as? [String: Any] {
        if let wrapper = dictionary["tweetResult"] as? [String: Any],
           let result = wrapper["result"] as? [String: Any] {
          return result
        }
        for value in dictionary.values {
          if let found = tweetResultNode(value) { return found }
        }
      } else if let array = node as? [Any] {
        for value in array {
          if let found = tweetResultNode(value) { return found }
        }
      }
      return nil
    }

    guard var result = tweetResultNode(root) else { return nil }
    if result["legacy"] == nil, let inner = result["tweet"] as? [String: Any] {
      result = inner
    }
    let legacy = result["legacy"] as? [String: Any]
    let views = result["views"] as? [String: Any]
    guard legacy != nil || views != nil else { return nil }
    return XTweetMetrics(
      favoriteCount: intValue(legacy?["favorite_count"]),
      replyCount: intValue(legacy?["reply_count"]),
      retweetCount: intValue(legacy?["retweet_count"]),
      bookmarkCount: intValue(legacy?["bookmark_count"]),
      viewCount: intValue(views?["count"])
    )
  }

  static func expandShortURLs(_ text: String, urls: [(url: String, expanded: String)]) -> String {
    var result = text
    for item in urls {
      let short = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
      let expanded = item.expanded.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !short.isEmpty, isExpandableHTTPURL(expanded) else { continue }
      result = result.replacingOccurrences(of: short, with: expanded)
    }
    return result
  }

  private static func isExpandableHTTPURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else { return false }
    return true
  }

  private static func urlsFromEntitySet(_ entitySet: Any?) -> [(url: String, expanded: String)] {
    guard let dictionary = entitySet as? [String: Any],
          let urls = dictionary["urls"] as? [[String: Any]]
    else { return [] }
    return urls.compactMap { item in
      guard let url = item["url"] as? String,
            let expanded = item["expanded_url"] as? String
      else { return nil }
      return (url, expanded)
    }
  }

  /// Draft.js 的 offset/length 按 UTF-16 code unit 计。切段失败或范围异常时
  /// 整块退回原文，避免把字切丢。
  static func renderDraftInline(
    text: String,
    entityRanges: [[String: Any]],
    inlineStyleRanges: [[String: Any]],
    linkURLByKey: [Int: String]
  ) -> String {
    let unitCount = text.utf16.count
    if unitCount == 0 { return text }

    var links: [(start: Int, end: Int, url: String)] = []
    var bolds: [(start: Int, end: Int)] = []
    var italics: [(start: Int, end: Int)] = []
    var cuts: Set<Int> = [0, unitCount]

    func parseRange(_ raw: [String: Any]) -> (start: Int, end: Int)? {
      guard let offset = intValue(raw["offset"]),
            let length = intValue(raw["length"])
      else { return nil }
      if length == 0 { return nil }
      let end = offset + length
      guard offset >= 0, length > 0, end <= unitCount,
            isUTF16Aligned(text, offset: offset),
            isUTF16Aligned(text, offset: end)
      else { return nil }
      return (offset, end)
    }

    func isMalformedRange(_ raw: [String: Any]) -> Bool {
      guard let offset = intValue(raw["offset"]),
            let length = intValue(raw["length"]),
            length != 0
      else { return false }
      let end = offset + length
      return offset < 0 || length < 0 || end > unitCount
        || !isUTF16Aligned(text, offset: offset)
        || !isUTF16Aligned(text, offset: end)
    }

    if entityRanges.contains(where: isMalformedRange) || inlineStyleRanges.contains(where: isMalformedRange) {
      return text
    }

    for range in entityRanges {
      guard let span = parseRange(range),
            let key = intValue(range["key"]),
            let url = linkURLByKey[key]
      else { continue }
      links.append((span.start, span.end, url))
      cuts.insert(span.start)
      cuts.insert(span.end)
    }

    for range in inlineStyleRanges {
      guard let span = parseRange(range) else { continue }
      let style = (range["style"] as? String)?.uppercased() ?? ""
      if style == "BOLD" {
        bolds.append(span)
        cuts.insert(span.start)
        cuts.insert(span.end)
      } else if style == "ITALIC" {
        italics.append(span)
        cuts.insert(span.start)
        cuts.insert(span.end)
      }
    }

    let sortedLinks = links.sorted { $0.start < $1.start }
    for index in 0..<sortedLinks.count {
      for other in (index + 1)..<sortedLinks.count {
        let left = sortedLinks[index]
        let right = sortedLinks[other]
        if left.start < right.end && right.start < left.end && left.url != right.url {
          return text
        }
      }
    }

    if links.isEmpty && bolds.isEmpty && italics.isEmpty { return text }

    let points = cuts.sorted()
    var output = ""
    for index in 0..<(points.count - 1) {
      let start = points[index]
      let end = points[index + 1]
      if start == end { continue }
      guard let piece = utf16Slice(text, start: start, end: end) else { return text }
      let url = links.first { $0.start <= start && end <= $0.end }?.url
      let bold = bolds.contains { $0.start <= start && end <= $0.end }
      let italic = italics.contains { $0.start <= start && end <= $0.end }
      output += wrapDraftSegment(piece, url: url, bold: bold, italic: italic)
    }
    return output
  }

  private static func isUTF16Aligned(_ text: String, offset: Int) -> Bool {
    let units = text.utf16
    guard offset >= 0, offset <= units.count else { return false }
    if offset == 0 || offset == units.count { return true }
    let index = units.index(units.startIndex, offsetBy: offset)
    return !UTF16.isTrailSurrogate(units[index])
  }

  private static func utf16Slice(_ text: String, start: Int, end: Int) -> String? {
    let units = text.utf16
    guard start >= 0, end <= units.count, start <= end else { return nil }
    let from = units.index(units.startIndex, offsetBy: start)
    let to = units.index(units.startIndex, offsetBy: end)
    return String(units[from..<to])
  }

  private static func wrapDraftSegment(_ text: String, url: String?, bold: Bool, italic: Bool) -> String {
    // Draft.js 的样式范围常把结尾空格也圈进去；`**词 **` 在 CommonMark 里不成立，
    // 所以标记只包住非空白部分，空白原样留在外面。
    let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !core.isEmpty else { return text }
    let leading = String(text.prefix(while: { $0.isWhitespace || $0.isNewline }))
    let trailing = String(text.reversed().prefix(while: { $0.isWhitespace || $0.isNewline }).reversed())
    var result = core
    if italic { result = "*\(result)*" }
    if bold { result = "**\(result)**" }
    if let url { result = "[\(result)](\(url))" }
    return leading + result + trailing
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
    articleContent: XArticleContent? = nil,
    metrics: XTweetMetrics? = nil
  ) -> ResolvedTweet? {
    let syndicationText = expandShortURLs(
      (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      urls: (payload.entities?.urls ?? []).compactMap { entity in
        guard let url = entity.url, let expanded = entity.expanded_url else { return nil }
        return (url, expanded)
      }
    )
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
      likeCount: metrics?.favoriteCount ?? payload.favorite_count,
      replyCount: metrics?.replyCount ?? payload.conversation_count,
      photoURLs: photos,
      video: video,
      quotedText: (quotedText?.isEmpty ?? true) ? nil : quotedText,
      quotedAuthor: quotedAuthor,
      quotedPhotoURLs: quotedPhotos,
      quotedURL: quotedURL,
      articleTitle: articleContent?.title,
      articleMarkdown: articleContent?.markdown,
      isArticleComplete: articleContent?.isComplete ?? false,
      repostCount: metrics?.retweetCount,
      bookmarkCount: metrics?.bookmarkCount,
      viewCount: metrics?.viewCount
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
    struct URLEntity: Decodable {
      let url: String?
      let expanded_url: String?
    }
    struct Entities: Decodable {
      let urls: [URLEntity]?
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
      struct CoverMedia: Decodable {
        struct MediaInfo: Decodable {
          let original_img_url: String?
        }
        let media_info: MediaInfo?
      }
      let rest_id: String?
      let title: String?
      let preview_text: String?
      let cover_media: CoverMedia?
    }
    let article: ArticleMarker?
    let entities: Entities?
  }
}
