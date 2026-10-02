import Foundation

/// 「在汲作里添加链接」和「浏览器扩展保存」的区别，用用户看得懂的话说出来。
///
/// 两条路用同一套提取（2026-10-02 起 App 在内置网页里跑扩展同款脚本），差别只剩登录状态
/// 从哪来：扩展用浏览器里已有的登录，App 用「设置 → 站点登录」。所以提醒只针对
/// 不登录就抓不全的平台——X 单条帖子走公开接口、B 站登录只影响清晰度，都不在其中。
public enum CaptureRouteGuidance {
  /// 不登录就读不全的平台（知乎只给开头、小红书和抖音常跳验证）。
  public static func loginPlatform(for url: URL) -> SiteSessionPlatform? {
    let host = url.host?.lowercased() ?? ""
    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
    if on("zhihu.com") { return .zhihu }
    if on("xiaohongshu.com") || on("xhslink.com") || on("xhslink.cn") { return .xiaohongshu }
    if on("douyin.com") || on("iesdouyin.com") { return .douyin }
    return nil
  }

  /// 输入框下方的提前提醒：这个平台在汲作里还没登录时才出现。
  public static func loginHint(for platform: SiteSessionPlatform) -> String {
    let name = platform.displayName
    return "\(name)要登录后才能读到完整内容。先到「设置 → 站点登录」登录\(name)；或在浏览器里打开它，用浏览器扩展保存。"
  }

  /// 抓取失败时的说明。登录、验证类失败落在需要登录的平台上，就点名平台、给出两个出口。
  public static func failureMessage(for error: ManualLinkError, url: URL?) -> String {
    guard let url, let platform = loginPlatform(for: url),
          error == .loginRequired || error == .verificationRequired
    else { return error.userMessage }
    let name = platform.displayName
    return "\(name)要求登录或验证，这次没有保存。先到「设置 → 站点登录」登录\(name)后点「重试」；或在浏览器里打开它，用浏览器扩展保存。"
  }

  /// 「抓取评论…」读不到时，对小红书单独说明原因：笔记要用分享链接里的访问码才打得开，
  /// 访问码会过期，汲作特意不存它（见 XiaohongshuSourceAdapter），事后补读评论打不开原笔记。
  /// 其他平台返回 nil，沿用通用提示。
  public static func commentsUnavailableMessage(for url: URL) -> String? {
    guard CommentCapture.platform(for: url) == "xiaohongshu" else { return nil }
    return "小红书笔记要用分享链接里的访问码才能打开，这个访问码会过期，汲作没有保存，所以这里读不到评论。在浏览器里打开这条笔记，用浏览器扩展保存时勾选评论。"
  }

  /// 「和浏览器扩展有什么不同？」展开后的几条，按情况列出。
  public static let differences: [String] = [
    "公开网页、博客、新闻、维基、YouTube、B 站、GitHub、公众号：两种方式抓到的正文、图片、字幕一样完整。",
    "知乎、小红书、抖音：在汲作里添加前，先到「设置 → 站点登录」登录一次。浏览器扩展直接用你浏览器里的登录。",
    "评论：打开「设置 → 收集 · 汲 → 评论」里的自动保存时，两种方式都顺带存前几条；没打开时，扩展在保存前让你勾选，汲作里添加后在条目上用「处理 → 抓取评论…」挑选（小红书例外：只能在添加时一起存）。",
    "会员或付费文章（如 Medium 会员文章）：汲作只能读到公开的开头；在浏览器登录后用扩展保存全文。",
    "网页弹出人机验证、被安全防护拦住时：在浏览器里通过验证，再用扩展保存。",
  ]
}
