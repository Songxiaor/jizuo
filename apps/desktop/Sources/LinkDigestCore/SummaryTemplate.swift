import Foundation

/// 按内容形式选默认的总结写法（2026-10-16）。
///
/// 原来所有内容共用一条通用提示词：一小时的视频、一条带几百条评论的帖子、一个 GitHub
/// 仓库，出来的都是同一种「概括 + 关键证据」。这几类读者真正想要的东西不一样：
/// 视频要能按时间点跳回去看，带评论的帖子要知道评论区在哪儿跟作者唱反调，仓库要知道
/// 它是干什么的、怎么用、靠不靠谱。
///
/// 只在用户**没改过**总结提示词时生效：用户自己写的提示词永远优先（见
/// `ModelPreferences.summaryPrompt`）。
public enum SummaryTemplate: String, Sendable, Equatable, CaseIterable {
  case general
  /// 视频、录音：分段要点，每段带 `[mm:ss]` 时间码，点了能跳播放器。
  case media
  /// 帖子 + 评论：作者的主要主张，以及评论区在哪些地方不同意。
  case discussion
  /// GitHub 仓库：是什么、怎么用、成熟度。
  case repository

  /// 选哪一种写法。优先级：仓库 → 视频/录音 → 带评论的帖子 → 通用。
  ///
  /// 全部按正文和来源判断，不查库：总结时手上只有这份已经拼好的正文。
  public static func select(origin: CapturedDocument.Origin, url: String, text: String) -> SummaryTemplate {
    if isGitHubRepository(url) { return .repository }
    if isMedia(origin: origin, text: text) { return .media }
    if hasComments(text) { return .discussion }
    return .general
  }

  /// 带评论的视频、仓库：在各自写法后面补一段「评论区怎么看」。
  public static func appendsCommentAnalysis(_ template: SummaryTemplate, text: String) -> Bool {
    (template == .media || template == .repository) && hasComments(text)
  }

  static func isGitHubRepository(_ url: String) -> Bool {
    guard let components = URLComponents(string: url),
          let host = components.host?.lowercased(),
          host == "github.com" || host == "www.github.com"
    else { return false }
    let parts = components.path.split(separator: "/")
    // `/owner/repo` 及其下的页面；`/owner` 单独一级是个人主页，不算仓库。
    guard parts.count >= 2 else { return false }
    let reserved: Set<String> = ["orgs", "topics", "search", "settings", "marketplace", "explore", "notifications"]
    return !reserved.contains(parts[0].lowercased())
  }

  static func isMedia(origin: CapturedDocument.Origin, text: String) -> Bool {
    if origin == .localTranscription || origin == .burnedInSubtitles { return true }
    let headings = [LayeredSourceDocument.transcriptHeading, LayeredSourceDocument.subtitleHeading]
    if headings.contains(where: { text.hasPrefix("## \($0)\n") || text.contains("\n## \($0)\n") }) {
      return true
    }
    return TranscriptReadingText.hasLeadingTimecodes(text)
  }

  static func hasComments(_ text: String) -> Bool {
    // 评论段是抓评论时按固定格式写进正文末尾的（见 CommentCapture.markdown）；
    // 前面补一个换行，评论段在正文最开头时也认得出。
    CommentCapture.strippingCommentSection(from: "\n" + text) != "\n" + text
  }

  /// 这种写法对应的默认提示词。`.general` 就是原来的通用提示词，不变。
  public func prompt(includingCommentAnalysis: Bool = false) -> String {
    let base: String = switch self {
    case .general:
      ModelPreferences.defaultSummaryPrompt
    case .media:
      """
      Summarize this video or audio for a reader who has not watched it, following the order in which things are said. Split it into sections by topic. Start each section with a line `### [mm:ss] Section title`, using the timestamp from the content where that section begins, then give 2-4 bullet points with the key claims and the concrete evidence behind them. A bullet may start with its own `[mm:ss]` when it points to a specific moment. Copy timestamps exactly as they appear in the content and never invent one; if the content carries no timestamps, leave them out. Stay strictly within what is said.
      """
    case .discussion:
      """
      Summarize this post and its comments for a reader who has read neither. First state the author's main claims and the key evidence behind them. Then add a section `### 评论区` that says where commenters push back, add important corrections or context, or disagree with each other, naming the specific point each disagreement is about. Do not list comments one by one and do not count likes. If the comments mostly agree, say so in one sentence. Stay strictly within what the content says.
      """
    case .repository:
      """
      Summarize this code repository for a developer deciding whether to use it. Cover three things, each under its own short heading: what it is (the problem it solves and how it differs from obvious alternatives, if the content says so), how to use it (installation and the main way to get started, with the key commands copied exactly), and maturity (signals such as stars, release or commit activity, license, documented limitations or warnings). Only report what the content shows; if a signal is missing, skip it instead of guessing.
      """
    }
    guard includingCommentAnalysis else { return base }
    return base + "\n\nThe content ends with a comments section. After the summary, add a section `### 评论区` that says where commenters disagree, correct, or add important context, naming the specific point each disagreement is about."
  }
}
