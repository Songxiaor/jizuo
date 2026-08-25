import Foundation

enum HistorySourceLinkPresentation {
  static func host(_ rawURL: String) -> String? {
    guard let components = URLComponents(string: rawURL),
          var host = components.host?.lowercased(),
          !host.isEmpty
    else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  static func text(_ rawURL: String) -> String {
    guard let host = host(rawURL),
          let components = URLComponents(string: rawURL)
    else { return rawURL }

    let segments = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).removingPercentEncoding ?? String($0) }

    if (host == "x.com" || host == "twitter.com"),
       segments.count >= 3,
       segments[1].lowercased() == "status" {
      return "\(host) · @\(segments[0]) 的帖子"
    }

    if host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
       segments.count >= 2,
       segments[0].lowercased() == "video" {
      return "\(host) · 视频 \(shortened(segments[1], limit: 18))"
    }

    guard !segments.isEmpty else { return host }
    let path = segments.joined(separator: "/")
    return "\(host) · /\(shortened(path, limit: 32))"
  }

  private static func shortened(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return "\(value.prefix(limit))…"
  }
}
