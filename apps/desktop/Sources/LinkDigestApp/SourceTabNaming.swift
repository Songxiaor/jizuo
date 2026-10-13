import Foundation

/// 阅读页「抓来的那层文字」叫什么，按帖子的结构判断，不按字数（2026-10-13 Syc 定）：
/// - **文案**：作者自己写的那段——X 推文正文、抖音 / 小红书 / B 站 / YouTube 的配文，
///   视频或图片帖下面的文字，纯文字推文也算；
/// - **正文**：整篇文章，或没有附件、没有引用的纯文字条目（笔记、备忘录、网页文章）。
///
/// 「转写稿」「引用」「译文」在别处处理，不走这里。文字多少不参与判断（原来图片帖按字数分的规则已删）。
enum SourceTabNaming {
  /// 社交平台上的帖子：不论带不带附件，作者那段文字都是「文案」。
  /// `platform` 是快照里存的平台标识。
  static let socialPostPlatforms: Set<String> = [
    "x", "douyin", "xiaohongshu", "bilibili", "youtube", "weibo", "tiktok", "instagram", "kuaishou"
  ]

  /// X 的长文章（Article）走这个来源：整篇文章，不是一条推文。
  static let xArticleSourceLabel = "X public article endpoint"

  /// 只有一层文字时叫「文案」还是「正文」。
  static func isCaption(
    platform: String,
    sourceLabel: String,
    hasVideoOrAudioFile: Bool,
    isUnsavedVideo: Bool,
    hasQuote: Bool
  ) -> Bool {
    if sourceLabel == xArticleSourceLabel { return false }
    if hasVideoOrAudioFile || isUnsavedVideo || hasQuote { return true }
    return socialPostPlatforms.contains(platform)
  }
}
