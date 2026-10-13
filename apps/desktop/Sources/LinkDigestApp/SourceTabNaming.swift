import Foundation

/// 阅读页「原文层」只有一层文字时，页签叫什么。按内容类型判断，不按平台（2026-10-13 Syc 定）：
/// - **配文**：视频帖、图片帖下面的那段文字；
/// - **原文**：文章、纯文字帖子（包括 X 的纯文字推文）。
///
/// 只有一层、又分不出类型时一律叫「原文」。转写出来的文字叫「转写稿」，校对过的叫「校对稿」，
/// 两个名字在别处处理，不走这里。
enum SourceTabNaming {
  /// 图片帖配的文字一般很短；超过这个字数当文章，叫「原文」。
  static let imagePostCaptionLimit = 500

  static func isCaption(
    hasVideoOrAudioFile: Bool,
    isUnsavedVideo: Bool,
    isVideoPlatform: Bool,
    bodyText: String
  ) -> Bool {
    if hasVideoOrAudioFile || isUnsavedVideo || isVideoPlatform { return true }
    return isShortImagePost(bodyText)
  }

  /// 正文里有图片，而除去图片之后文字很短。
  static func isShortImagePost(_ bodyText: String) -> Bool {
    let imagePattern = #"!\[[^\]]*\]\([^)]*\)"#
    guard bodyText.range(of: imagePattern, options: .regularExpression) != nil else { return false }
    let text = bodyText
      .replacingOccurrences(of: imagePattern, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.count <= imagePostCaptionLimit
  }
}
