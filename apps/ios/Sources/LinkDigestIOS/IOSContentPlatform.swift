import Foundation

/// iOS Companion 识别的内容平台（与 Mac `HistoryPlatformRegistry` 主平台对齐）。
/// 用于抓取分支、失败分层提示与详情页展示；不引入 Cookie/登录会话。
public struct IOSContentPlatform: Sendable, Equatable, Hashable {
  public var id: String
  public var displayName: String
  public var exactHosts: [String]
  public var suffixHosts: [String]
  /// 公开 HTML 抓取在该平台上的已知限制（登录墙 / SPA 等）。
  public var fetchLimitationHint: String?

  public init(
    id: String,
    displayName: String,
    exactHosts: [String],
    suffixHosts: [String] = [],
    fetchLimitationHint: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.exactHosts = exactHosts
    self.suffixHosts = suffixHosts
    self.fetchLimitationHint = fetchLimitationHint
  }

  public static let catalog: [IOSContentPlatform] = [
    .init(
      id: "douyin",
      displayName: "抖音",
      exactHosts: ["douyin.com", "iesdouyin.com", "v.douyin.com"],
      fetchLimitationHint: "抖音公开页常被登录墙或短链跳转挡住；若正文为空请在浏览器打开后再分享，或改用 Mac 扩展抓取。"
    ),
    .init(
      id: "wechat",
      displayName: "微信公众号",
      exactHosts: ["mp.weixin.qq.com", "weixin.qq.com"]
    ),
    .init(
      id: "x",
      displayName: "X",
      exactHosts: ["x.com", "twitter.com"],
      fetchLimitationHint: "X 公开 HTML 经常只有壳页面；登录受限帖需在已打开页用 Mac 扩展抓取。"
    ),
    .init(
      id: "youtube",
      displayName: "YouTube",
      exactHosts: ["youtube.com", "youtu.be"],
      fetchLimitationHint: "YouTube 页面正文多为播放器壳；详情里「整理页面稿」只用标题/简介，不是音轨识别。完整媒体管线仍在 Mac。"
    ),
    .init(
      id: "bilibili",
      displayName: "哔哩哔哩",
      exactHosts: ["bilibili.com", "b23.tv"],
      fetchLimitationHint: "B 站公开页可能只有标题与简介；详情「整理页面稿」不是音轨识别，完整视频转写优先在 Mac。"
    ),
    .init(
      id: "xiaohongshu",
      displayName: "小红书",
      exactHosts: ["xiaohongshu.com", "xhslink.com"],
      fetchLimitationHint: "小红书未登录时常返回登录墙；优先依赖 og:title / og:description。"
    ),
    .init(
      id: "zhihu",
      displayName: "知乎",
      exactHosts: ["zhihu.com", "zhuanlan.zhihu.com"],
      fetchLimitationHint: "知乎部分内容需登录；公开答案可尝试抽 article。"
    ),
    .init(
      id: "weibo",
      displayName: "微博",
      exactHosts: ["weibo.com", "weibo.cn"],
      fetchLimitationHint: "微博公开页经常是 SPA 壳；失败时请改用已渲染页分享或 Mac 扩展。"
    ),
    .init(
      id: "github",
      displayName: "GitHub",
      exactHosts: ["github.com"]
    ),
    .init(
      id: "medium",
      displayName: "Medium",
      exactHosts: ["medium.com"],
      suffixHosts: ["medium.com"]
    ),
    .init(
      id: "reddit",
      displayName: "Reddit",
      exactHosts: ["reddit.com"]
    ),
  ]

  public static func recognize(urlString: String) -> IOSContentPlatform? {
    guard let host = normalizedHost(from: urlString), !host.isEmpty else { return nil }
    if let exact = catalog.first(where: { $0.exactHosts.contains(host) }) {
      return exact
    }
    return catalog.first { platform in
      platform.suffixHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        || platform.exactHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
  }

  public static func normalizedHost(from urlString: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let host = url.host?.lowercased() else {
      return nil
    }
    if host.hasPrefix("www.") {
      return String(host.dropFirst(4))
    }
    return host
  }
}
