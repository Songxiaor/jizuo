import Foundation

/// 抓取结果：成功时带标题/正文；失败时仍允许用占位正文保存 URL。
public struct LinkFetchResult: Sendable, Equatable {
  public var title: String?
  public var body: String
  /// 非 nil 表示抓取或解析未完整成功，UI 应展示可读原因。
  public var warningMessage: String?

  public init(title: String?, body: String, warningMessage: String? = nil) {
    self.title = title
    self.body = body
    self.warningMessage = warningMessage
  }
}

public enum LinkPageFetcherError: Error, LocalizedError, Sendable, Equatable {
  case invalidURL
  case httpStatus(Int)
  case emptyResponse
  case decodingFailed
  case unsupportedContentType(String)
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "链接地址无效。"
    case .httpStatus(let code):
      switch code {
      case 401, 403:
        return "服务器拒绝访问（HTTP \(code)），可能需要登录或没有公开权限。"
      case 404:
        return "页面不存在（HTTP 404）。"
      case 410:
        return "页面已删除（HTTP 410）。"
      case 429:
        return "请求过于频繁（HTTP 429），请稍后再试。"
      case 500...599:
        return "服务器出错（HTTP \(code)），暂时无法读取页面。"
      default:
        return "服务器返回 HTTP \(code)，无法读取页面。"
      }
    case .emptyResponse:
      return "页面内容为空。"
    case .decodingFailed:
      return "无法把页面解码成文字（编码可能不受支持）。"
    case .unsupportedContentType(let type):
      return "该链接不是网页（\(type)），无法抽取正文。"
    case .timedOut:
      return "抓取超时，请检查网络或稍后再试。"
    }
  }
}

/// 用 URLSession 拉公开 HTML，再交给 `LinkHTMLExtractor`。
public struct LinkPageFetcher: Sendable {
  public static let defaultByteLimit = 2 * 1024 * 1024
  public static let defaultTimeoutSeconds: TimeInterval = 20

  private let session: URLSession
  private let byteLimit: Int
  private let timeoutSeconds: TimeInterval

  public init(
    session: URLSession = .shared,
    byteLimit: Int = LinkPageFetcher.defaultByteLimit,
    timeoutSeconds: TimeInterval = LinkPageFetcher.defaultTimeoutSeconds
  ) {
    self.session = session
    self.byteLimit = max(16_384, byteLimit)
    self.timeoutSeconds = max(3, timeoutSeconds)
  }

  /// 失败不抛到外层：返回占位正文 + `warningMessage`，方便用户仍保存 URL。
  public func fetch(urlString: String) async -> LinkFetchResult {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = Self.normalizedURL(from: trimmed) else {
      return LinkFetchResult(
        title: nil,
        body: "（待抓取正文）",
        warningMessage: LinkPageFetcherError.invalidURL.errorDescription
      )
    }

    do {
      var request = URLRequest(url: url)
      request.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
      request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
      request.timeoutInterval = timeoutSeconds

      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw LinkPageFetcherError.httpStatus(http.statusCode)
      }
      guard !data.isEmpty else { throw LinkPageFetcherError.emptyResponse }

      if let contentType = Self.contentType(from: response),
         !Self.isHTMLContentType(contentType)
      {
        throw LinkPageFetcherError.unsupportedContentType(contentType)
      }

      let limited = data.count > byteLimit ? data.prefix(byteLimit) : data
      guard let html = Self.decodeHTML(Data(limited), response: response) else {
        throw LinkPageFetcherError.decodingFailed
      }

      // 无 Content-Type 时，若内容完全不像 HTML，给出可读失败。
      if Self.contentType(from: response) == nil, !Self.looksLikeHTML(html) {
        throw LinkPageFetcherError.unsupportedContentType("非 HTML 文本")
      }

      let platform = IOSContentPlatform.recognize(urlString: trimmed)
      let extracted = LinkHTMLExtractor.extract(html: html, platformID: platform?.id)
      let body = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
      if body.isEmpty {
        return LinkFetchResult(
          title: extracted.title,
          body: "（待抓取正文）",
          warningMessage: Self.layeredFetchWarning(
            base: "页面里几乎没有可读文字，可能需要登录或是动态渲染页。",
            platform: platform
          )
        )
      }
      if let platform,
         platform.fetchLimitationHint != nil,
         body.unicodeScalars.count < 80
      {
        return LinkFetchResult(
          title: extracted.title,
          body: body,
          warningMessage: Self.layeredFetchWarning(
            base: "已抽出部分文字，但可能不完整。",
            platform: platform
          )
        )
      }
      return LinkFetchResult(title: extracted.title, body: body, warningMessage: nil)
    } catch let error as LinkPageFetcherError {
      return LinkFetchResult(
        title: nil,
        body: "（待抓取正文）",
        warningMessage: Self.layeredFetchWarning(
          base: error.errorDescription ?? "抓取失败",
          platform: IOSContentPlatform.recognize(urlString: trimmed)
        )
      )
    } catch let urlError as URLError where urlError.code == .timedOut {
      return LinkFetchResult(
        title: nil,
        body: "（待抓取正文）",
        warningMessage: LinkPageFetcherError.timedOut.errorDescription
      )
    } catch {
      return LinkFetchResult(
        title: nil,
        body: "（待抓取正文）",
        warningMessage: "抓取失败：\(error.localizedDescription)"
      )
    }
  }

  public static func layeredFetchWarning(base: String, platform: IOSContentPlatform?) -> String {
    guard let platform else { return base }
    var parts = ["【\(platform.displayName)】\(base)"]
    if let hint = platform.fetchLimitationHint, !hint.isEmpty {
      parts.append(hint)
    }
    return parts.joined(separator: " ")
  }

  public static func normalizedURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
      return url
    }
    if trimmed.contains("."), !trimmed.contains(" ") {
      return URL(string: "https://\(trimmed)")
    }
    return nil
  }

  public static func contentType(from response: URLResponse) -> String? {
    guard let http = response as? HTTPURLResponse else {
      return response.mimeType
    }
    if let header = http.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";")
      .first
      .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
       !header.isEmpty
    {
      return header.lowercased()
    }
    return http.mimeType?.lowercased()
  }

  public static func isHTMLContentType(_ contentType: String) -> Bool {
    let lower = contentType.lowercased()
    if lower.contains("html") || lower.contains("xhtml") { return true }
    // 少数站点用 text/plain 返回 HTML，交给 looksLikeHTML 二次判断。
    if lower == "text/plain" || lower == "application/octet-stream" { return true }
    return false
  }

  public static func looksLikeHTML(_ text: String) -> Bool {
    let sample = text.prefix(2048).lowercased()
    return sample.contains("<html")
      || sample.contains("<!doctype html")
      || sample.contains("<head")
      || sample.contains("<body")
      || sample.contains("<article")
      || sample.contains("<meta")
  }

  static func decodeHTML(_ data: Data, response: URLResponse) -> String? {
    if let headerCharset = (response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Type")
      .flatMap(LinkHTMLExtractor.charsetFromContentType),
       let text = decode(data, charset: headerCharset)
    {
      return text
    }

    // 先用容错编码读出字节，解析 meta charset，再按提示重解。
    let probe =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
      ?? (NSString(data: data, encoding: String.Encoding.isoLatin1.rawValue) as String?)

    if let probe,
       let hint = LinkHTMLExtractor.charsetHint(from: String(probe.prefix(8192))),
       let text = decode(data, charset: hint)
    {
      return text
    }

    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
    return NSString(data: data, encoding: String.Encoding.isoLatin1.rawValue) as String?
  }

  private static func decode(_ data: Data, charset: String) -> String? {
    guard let encoding = String.Encoding.fromCharset(charset) else { return nil }
    if let text = String(data: data, encoding: encoding) { return text }
    return NSString(data: data, encoding: encoding.rawValue) as String?
  }
}

private extension String.Encoding {
  static func fromCharset(_ name: String) -> String.Encoding? {
    let lower = name.lowercased()
    switch lower {
    case "utf-8", "utf8": return .utf8
    case "gbk", "gb2312", "gb18030":
      return .init(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
          CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
      )
    case "iso-8859-1", "latin1": return .isoLatin1
    default:
      let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
      guard cf != kCFStringEncodingInvalidId else { return nil }
      return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
  }
}
