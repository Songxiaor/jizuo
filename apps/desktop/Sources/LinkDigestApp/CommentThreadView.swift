import Foundation
import SwiftUI

/// 这条帖子的作者，供评论区认出「作者本人的回复」。详情页注入；别处默认 nil，不标。
private struct CommentPostAuthorKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  /// 帖子作者的原始写法，如「大师的AI小灶 (@dashiAIxz)」「u/someone」「阿强」。
  var commentPostAuthor: String? {
    get { self[CommentPostAuthorKey.self] }
    set { self[CommentPostAuthorKey.self] = newValue }
  }
}

/// 社区评论的阅读态：保留平台对话关系，但去掉投票、奖励、分享等社交操作噪音。
/// 头像只由用户名在本地确定，不发起头像网络请求，也不新增账号画像数据。
struct CommentThreadSectionView: View {
  let section: MarkdownPresentation.CommentSection
  let localImageURLs: [URL]
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let accentColor: Color
  let onOpenURL: (URL) -> Void

  @State private var expandedRoots: Set<Int> = []
  /// 渐进渲染：一条 Reddit/X 长帖的评论主线能把文档堆到两万多点高，
  /// 全量渲染让每次面板切换的布局/合成都要为整棵评论树付费（实测占
  /// 切换卡顿的大头）。先渲染头几屏的量，其余按需展开——内容一条不少，
  /// 只是不同时全部活在视图树里。
  /// 先露 3 条，其余收起（2026-09-28 评论样稿：评论不该把正文页拖得太长）。
  @State private var visibleRootLimit = 3
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.commentPostAuthor) private var postAuthor

  private let collapsedReplyLimit = 3
  private let initialRootLimit = 3
  private let rootLoadStep = 12

  var body: some View {
    let groups = Self.threadGroups(section.items)
    let visibleGroups = Array(groups.prefix(visibleRootLimit))
    let remainingRoots = groups.count - visibleGroups.count
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader
      ForEach(visibleGroups) { group in
        threadGroup(group)
        if group.id != visibleGroups.last?.id || remainingRoots > 0 {
          Divider().overlay(secondaryTextColor.opacity(0.12))
        }
      }
      if remainingRoots > 0 {
        Button {
          visibleRootLimit += rootLoadStep
        } label: {
          Text("还有 \(remainingRoots) 条 · 展开")
            .themedFont(.caption)
            .foregroundStyle(secondaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DesignTokens.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-comments-load-more")
      }
    }
    .padding(.top, DesignTokens.Space.xl)
    .padding(.bottom, DesignTokens.Space.xl)
    // 整块和正文同一行宽（2026-10-03 走查）：原来标题下那道线和分隔线铺满整栏，
    // 评论文字却只排到正文行宽，「原评论 ↗」悬在半中间，线和字对不齐。
    .frame(maxWidth: readingFont.bodySize * DesignTokens.Layout.readingTextMeasureEm, alignment: .leading)
    .onChange(of: section) { _, _ in
      expandedRoots.removeAll()
      visibleRootLimit = initialRootLimit
    }
    .accessibilityIdentifier("history-content-comment-thread")
  }

  /// 2026-09-28 评论样稿：一行靛青小字「评论」，右边灰字写保存了几条；下面一道细线。
  /// 和总结里的段首标签是同一种写法，不再用大号标题加竖条。
  private var sectionHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text(section.title.hasPrefix("评论") ? "评论" : section.title)
        .font(.system(size: 12.5, weight: .medium))
        .tracking(2)
        .foregroundStyle(accentColor)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: DesignTokens.Space.sm)
      if section.isCapped {
        Text("已截取上限")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .help("为保证单次抓取稳定，只保留了平台当前页面中的前若干条评论。")
      }
      if let progressLabel = section.progressLabel ?? (section.items.isEmpty ? nil : "\(section.items.count) 条") {
        Text(progressLabel)
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
      }
    }
    .padding(.bottom, DesignTokens.Space.sm)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(secondaryTextColor.opacity(0.16))
        .frame(height: 1)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func threadGroup(_ group: ThreadGroup) -> some View {
    let isExpanded = expandedRoots.contains(group.id)
    let visibleLimit = isExpanded ? group.items.count : min(group.items.count, collapsedReplyLimit + 1)
    let visibleItems = Array(group.items.prefix(visibleLimit))
    VStack(alignment: .leading, spacing: 0) {
      ForEach(visibleItems, id: \.id) { item in
        commentRow(item)
      }

      if group.items.count > visibleLimit {
        disclosureButton(
          title: "展开其余 \(group.items.count - visibleLimit) 条回复",
          systemImage: "chevron.down",
          rootID: group.id,
          expands: true
        )
      } else if isExpanded, group.items.count > collapsedReplyLimit + 1 {
        disclosureButton(
          title: "收起回复",
          systemImage: "chevron.up",
          rootID: group.id,
          expands: false
        )
      }
    }
  }

  private func disclosureButton(
    title: String,
    systemImage: String,
    rootID: Int,
    expands: Bool
  ) -> some View {
    Button {
      let update = {
        if expands { expandedRoots.insert(rootID) } else { expandedRoots.remove(rootID) }
      }
      if reduceMotion { update() } else { withAnimation(DesignTokens.Motion.standard) { update() } }
    } label: {
      Text(title)
        .themedFont(.caption)
        .foregroundStyle(secondaryTextColor)
        .padding(.vertical, DesignTokens.Space.sm)
        .padding(.leading, 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  /// 一条评论：一行灰字（名字、回复谁、时间、赞、原评论），下面是正文。
  /// 不画彩色头像（每人一种颜色，一页下来五颜六色）；回复缩进一格，左边一道细线。
  private func commentRow(_ item: MarkdownPresentation.CommentItem) -> some View {
    let visualDepth = min(item.depth, 3)
    return VStack(alignment: .leading, spacing: 6) {
      commentHeader(item)
      if item.depth > 3 {
        Text("第 \(item.depth + 1) 层回复")
          .themedFont(.caption2)
          .foregroundStyle(secondaryTextColor)
      }
      if !item.body.isEmpty {
        commentBody(item.body)
      }
    }
    .padding(.leading, visualDepth > 0 ? 14 : 0)
    .overlay(alignment: .leading) {
      if visualDepth > 0 {
        Rectangle()
          .fill(secondaryTextColor.opacity(0.18))
          .frame(width: 1)
          .accessibilityHidden(true)
      }
    }
    .padding(.leading, CGFloat(max(visualDepth - 1, 0)) * 18 + (visualDepth > 0 ? 18 : 0))
    .padding(.vertical, visualDepth > 0 ? 8 : 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 评论正文比帖子正文小两号（2026-10-03 走查）：原来和正文同字号同字体，
  /// 十几条评论排下来和帖子本身分不出主次，整页像一篇没有段落的长文。
  private var commentFontSize: CGFloat { max(13, readingFont.bodySize - 2) }

  @ViewBuilder
  private func commentBody(_ body: String) -> some View {
    let segments = LocalMarkdownImageLayout.segments(
      markdown: body,
      localImageURLs: localImageURLs,
      appendsUnusedLocalImages: false
    )
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case let .text(text):
          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attributed = ReadingRenderCache.inlineAttributed(from: text).applyingBaseFont(
              size: commentFontSize,
              readingFont: readingFont
            )
            Text(attributed)
              .foregroundStyle(primaryTextColor.opacity(0.9))
              .lineSpacing(commentFontSize * 0.42)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        case let .image(url):
          InlineArticleImageView(url: url)
        case let .gallery(urls):
          InlineArticleGalleryView(urls: urls)
        case let .quotedTweet(quote):
          QuotedTweetCardView(
            quote: quote,
            readingFont: readingFont,
            accentColor: accentColor,
            onOpenURL: onOpenURL
          )
        case let .video(video):
          ArticleInlineVideoCard(
            video: video,
            localFileURL: nil,
            pageURL: nil,
            onOpenURL: onOpenURL
          )
        }
      }
    }
  }

  /// 「Panda | AI Agent @PandaAINative」拆成名字和账号：名字是读的人认人的地方，
  /// 账号退一档。
  static func splitAuthor(_ display: String) -> (name: String, handle: String?) {
    guard let range = display.range(of: " @", options: .backwards) else { return (display, nil) }
    let name = display[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    let handle = String(display[display.index(after: range.lowerBound)...])
    guard !name.isEmpty, !handle.contains(" ") else { return (display, nil) }
    // 显示名就是账号名时只留一个。
    if name.caseInsensitiveCompare(String(handle.dropFirst())) == .orderedSame { return (handle, nil) }
    return (name, handle)
  }

  /// 评论者是不是帖子作者本人：有账号比账号，没有账号（抖音、小红书只有昵称）比名字。
  static func isPostAuthor(_ commentAuthor: String, postAuthor: String?) -> Bool {
    guard let postAuthor = postAuthor?.trimmingCharacters(in: .whitespaces), !postAuthor.isEmpty else { return false }
    // 帖子作者写成「名字 (@账号)」，评论者写成「名字 @账号」；统一成同一种再拆。
    let normalizedPost = postAuthor.replacingOccurrences(of: #"\s*\((@[^()\s]+)\)$"#, with: " $1", options: .regularExpression)
    let post = splitAuthor(normalizedPost)
    let comment = splitAuthor(commentAuthor)
    if let postHandle = post.handle ?? (post.name.hasPrefix("@") ? post.name : nil),
       let commentHandle = comment.handle ?? (comment.name.hasPrefix("@") ? comment.name : nil) {
      return postHandle.caseInsensitiveCompare(commentHandle) == .orderedSame
    }
    return post.name == comment.name
  }

  private func commentHeader(_ item: MarkdownPresentation.CommentItem) -> some View {
    let author = Self.splitAuthor(item.displayAuthor)
    let isAuthor = Self.isPostAuthor(item.displayAuthor, postAuthor: postAuthor)
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(author.name)
        .themedFont(.footnote, weight: .semibold)
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
        .accessibilityLabel(accessibilityHeader(for: item) + (isAuthor ? "，作者" : ""))
      // 作者本人的回复常常是整串评论里最有用的补充（「一稿出就发了」），
      // 混在别人中间认不出来（2026-10-03 走查）。
      if isAuthor {
        Text("作者")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(accentColor)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .overlay(Capsule().strokeBorder(accentColor.opacity(0.5), lineWidth: 0.5))
          .fixedSize()
          .accessibilityHidden(true)
      }
      if let handle = author.handle {
        Text(handle)
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .accessibilityHidden(true)
      }
      if let parentAuthor = item.parentAuthor {
        Text("回复 \(parentAuthor)")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor.opacity(0.8))
          .lineLimit(1)
      }
      if let published = item.published {
        Text("· " + CommentPublishedTime.absoluteLabel(published))
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize()
          .help(published)
      }
      if let likes = item.likes {
        Text("赞 \(likes)")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
      }
      if let score = item.score {
        Text("\(score) 分")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
      }
      Spacer(minLength: DesignTokens.Space.xs)
      if let permalink = item.permalink {
        // 一个小图标，贴在这一行的最右端；原来是「原评论 ↗」四个字，每条都重复一遍。
        Button { onOpenURL(permalink) } label: {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(secondaryTextColor.opacity(0.8))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instantHoverTip("打开原评论")
        .accessibilityLabel("在浏览器中打开 \(item.displayAuthor) 的原评论")
      }
    }
  }

  private func accessibilityHeader(for item: MarkdownPresentation.CommentItem) -> String {
    var parts = ["第 \(item.depth + 1) 层评论", item.displayAuthor]
    if let parentAuthor = item.parentAuthor { parts.append("回复 \(parentAuthor)") }
    if let score = item.score { parts.append("\(score) 分") }
    if let likes = item.likes { parts.append("\(likes) 赞") }
    if let published = item.published { parts.append(CommentPublishedTime.relativeLabel(published)) }
    return parts.joined(separator: "，")
  }

  private static func threadGroups(
    _ items: [MarkdownPresentation.CommentItem]
  ) -> [ThreadGroup] {
    var groups: [ThreadGroup] = []
    var current: [MarkdownPresentation.CommentItem] = []
    for item in items {
      if item.depth == 0, !current.isEmpty {
        groups.append(ThreadGroup(items: current))
        current = []
      }
      current.append(item)
    }
    if !current.isEmpty { groups.append(ThreadGroup(items: current)) }
    return groups
  }

  private struct ThreadGroup: Identifiable {
    let items: [MarkdownPresentation.CommentItem]
    var id: Int { items.first?.sequence ?? 0 }
  }
}

enum CommentPublishedTime {
  private nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private nonisolated(unsafe) static let standardISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func relativeLabel(_ raw: String, now: Date = Date()) -> String {
    guard let date = parsedDate(raw) else { return raw }
    let seconds = Int(now.timeIntervalSince(date))
    guard seconds >= 0 else { return raw }
    switch seconds {
    case 0..<60: return "刚刚"
    case 60..<3_600: return "\(seconds / 60) 分钟前"
    case 3_600..<86_400: return "\(seconds / 3_600) 小时前"
    case 86_400..<604_800: return "\(seconds / 86_400) 天前"
    case 604_800..<2_592_000: return "\(seconds / 604_800) 周前"
    case 2_592_000..<31_536_000: return "\(seconds / 2_592_000) 个月前"
    default: return "\(seconds / 31_536_000) 年前"
    }
  }

  /// 阅读区用的本地时间：今年写「9月28日 18:41」，往年写「2025年1月8日」。
  /// 平台原样给的「01-08」这种月-日也换成「1月8日」；认不出的原样显示。
  static func absoluteLabel(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> String {
    if let date = parsedDate(raw) {
      let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
      if parts.year == calendar.component(.year, from: now) {
        return String(format: "%d月%d日 %02d:%02d", parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0)
      }
      return "\(parts.year ?? 0)年\(parts.month ?? 1)月\(parts.day ?? 1)日"
    }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let match = trimmed.wholeMatch(of: /(\d{1,2})-(\d{1,2})/),
       let month = Int(match.1), let day = Int(match.2), (1...12).contains(month), (1...31).contains(day) {
      return "\(month)月\(day)日"
    }
    return raw
  }

  /// 导出用的本地时间：`2026-10-03T23:30:06.000Z` 在东八区是 `2026-10-04 07:30`。
  /// 认不出的原样返回。
  static func localStamp(
    _ raw: String,
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String {
    guard let date = parsedDate(raw) else { return raw }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  private static func parsedDate(_ raw: String) -> Date? {
    fractionalISO.date(from: raw) ?? standardISO.date(from: raw)
  }
}
