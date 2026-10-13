import Foundation
import SwiftUI

/// 这条帖子的作者，供评论区认出「作者本人的回复」。详情页注入；别处默认 nil，不标。
private struct CommentPostAuthorKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

private struct CommentCapturedAtKey: EnvironmentKey {
  static let defaultValue: Date? = nil
}

extension EnvironmentValues {
  /// 帖子作者的原始写法，如「大师的AI小灶 (@dashiAIxz)」「u/someone」「阿强」。
  var commentPostAuthor: String? {
    get { self[CommentPostAuthorKey.self] }
    set { self[CommentPostAuthorKey.self] = newValue }
  }

  /// 这条内容保存的时间。评论里的「8分钟前」是保存当时的相对时间，要按这个时刻换算。
  var commentCapturedAt: Date? {
    get { self[CommentCapturedAtKey.self] }
    set { self[CommentCapturedAtKey.self] = newValue }
  }
}

/// 评论放在自己的「评论」页签里时为 true：页签名已经叫「评论」，顶部不再重复写一遍标题。
/// 别处（例如译文里带的评论）仍写「评论」两个字，认得出这一块是什么。
private struct CommentsInOwnTabKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var commentsInOwnTab: Bool {
    get { self[CommentsInOwnTabKey.self] }
    set { self[CommentsInOwnTabKey.self] = newValue }
  }
}

/// 鼠标停在这一块上时才为 true。状态放在自己里面，进出一条评论不会让整个评论区重排。
private struct HoverReveal<Content: View>: View {
  @State private var hovering = false
  let content: (Bool) -> Content

  var body: some View {
    content(hovering)
      .onHover { hovering = $0 }
  }
}

/// 社区评论的阅读态：保留平台对话关系，但去掉投票、奖励、分享等社交操作噪音。
/// 头像只由用户名在本地确定，不发起头像网络请求，也不新增账号画像数据。
///
/// 2026-10-13 评论区改版（Syc 定「评论按这个改」）：评论单独一个页签；正文用系统无衬线小字、
/// 句间不拉空行；条头是名字、作者标、时间，点赞靠最右；回复紧跟在被回复的人下面时不写「回复 某某」；
/// 每串先露两条回复；串与串之间不画线，靠留白分开。
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
  /// 评论有了自己的页签，先露 10 串（原来夹在正文下面时只露 3 条）。
  @State private var visibleRootLimit = CommentThreadSectionView.initialRootLimit
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.commentPostAuthor) private var postAuthor
  @Environment(\.commentCapturedAt) private var commentCapturedAt
  @Environment(\.commentsInOwnTab) private var inOwnTab

  /// 每串先露几条回复（不含根评论）。
  static let collapsedReplyLimit = 2
  static let initialRootLimit = 10
  private let rootLoadStep = 12

  var body: some View {
    let groups = Self.threadGroups(section.items)
    let visibleGroups = Array(groups.prefix(visibleRootLimit))
    let remainingRoots = groups.count - visibleGroups.count
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader
      ForEach(visibleGroups) { group in
        threadGroup(group)
          // 串与串之间不画分隔线，留白分开。
          .padding(.bottom, DesignTokens.Space.xl)
      }
      if remainingRoots > 0 {
        Button {
          visibleRootLimit += rootLoadStep
        } label: {
          Text("还有 \(remainingRoots) 条 · 展开")
            .themedFont(.caption)
            .foregroundStyle(accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DesignTokens.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-comments-load-more")
      }
    }
    .padding(.top, inOwnTab ? DesignTokens.Space.sm : DesignTokens.Space.xl)
    // 评论总在全文最后，下面紧跟「添加笔记」或「收起」：原来留 24pt，加上外面的间距空出一大段（2026-10-07 检查）。
    .padding(.bottom, DesignTokens.Space.sm)
    // 整块铺满阅读列，和正文、标题同一条左右边缘（Syc 2026-10-07）。
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: section) { _, _ in
      expandedRoots.removeAll()
      visibleRootLimit = Self.initialRootLimit
    }
    .accessibilityIdentifier("history-content-comment-thread")
  }

  /// 顶部一行灰字：「已保存 20 条 · 平台共约 173 条」。在评论页签里不再写「评论」标题；
  /// 在别处（译文）仍带上标题。
  private var sectionHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      if !inOwnTab {
        Text(section.title.hasPrefix("评论") ? "评论" : section.title)
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(secondaryTextColor)
          .accessibilityAddTraits(.isHeader)
      }
      if let progressLabel = section.progressLabel ?? (section.items.isEmpty ? nil : "\(section.items.count) 条") {
        Text(progressLabel)
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
      }
      if section.isCapped {
        Text("已截取上限")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .help("为保证一次存得稳，只保留了平台当前页面的前若干条评论。")
      }
      Spacer(minLength: 0)
    }
    .padding(.bottom, DesignTokens.Space.md)
  }

  @ViewBuilder
  private func threadGroup(_ group: ThreadGroup) -> some View {
    let isExpanded = expandedRoots.contains(group.id)
    let replyCount = group.items.count - 1
    let visibleLimit = isExpanded ? group.items.count : min(group.items.count, Self.collapsedReplyLimit + 1)
    let visibleItems = Array(group.items.prefix(visibleLimit))
    let targets = Self.replyTargets(in: group.items)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(visibleItems, id: \.id) { item in
        commentRow(item, replyTarget: targets[item.sequence])
      }

      if group.items.count > visibleLimit {
        disclosureButton(
          title: "展开另外 \(group.items.count - visibleLimit) 条回复",
          rootID: group.id,
          expands: true
        )
      } else if isExpanded, replyCount > Self.collapsedReplyLimit {
        disclosureButton(
          title: "收起回复",
          rootID: group.id,
          expands: false
        )
      }
    }
  }

  private func disclosureButton(
    title: String,
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
        .foregroundStyle(accentColor)
        .padding(.vertical, DesignTokens.Space.xs)
        // 和回复的缩进线对齐：回复内容从线后 14pt 起。
        .padding(.leading, 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  /// 一条评论：一行条头（名字、作者标、账号、时间，点赞靠最右），下面是正文。
  /// 不画彩色头像（每人一种颜色，一页下来五颜六色）；回复缩进一格，左边一道细线。
  private func commentRow(_ item: MarkdownPresentation.CommentItem, replyTarget: String?) -> some View {
    let visualDepth = min(item.depth, 3)
    return HoverReveal { hovering in
      VStack(alignment: .leading, spacing: 4) {
        commentHeader(item, replyTarget: replyTarget, hovering: hovering)
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
      .padding(.vertical, visualDepth > 0 ? 6 : 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
  }

  /// 评论正文：系统无衬线，比阅读区正文小得多，颜色稍浅（2026-10-13）。
  /// 原来用阅读区的宋体、只比正文小两号，十几条评论排下来和帖子正文分不出主次。
  private var commentFontSize: CGFloat { max(12, readingFont.bodySize - 3.5) }

  /// 一条评论里的换行当普通换行：连续空行并成一个换行，句与句之间不再拉开。
  static func compactedBody(_ text: String) -> String {
    text.replacingOccurrences(of: #"[ \t]*\n(?:[ \t]*\n)+"#, with: "\n", options: .regularExpression)
  }

  @ViewBuilder
  private func commentBody(_ body: String) -> some View {
    let segments = LocalMarkdownImageLayout.segments(
      markdown: body,
      localImageURLs: localImageURLs,
      appendsUnusedLocalImages: false
    )
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case let .text(text):
          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attributed = ReadingRenderCache.inlineAttributed(from: Self.compactedBody(text)).applyingBaseFont(
              size: commentFontSize,
              readingFont: .sans
            )
            Text(attributed)
              .foregroundStyle(primaryTextColor.opacity(0.8))
              .lineSpacing(commentFontSize * 0.3)
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

  /// 一串评论里，哪几条回复要写「回复 某某」，写谁（键是 `CommentItem.sequence`）。
  ///
  /// 回复紧跟在被回复的人下面，或者回复的就是这一串的头一条（根评论）时，位置已经说明了在回复谁，
  /// 不再写。只有回复的是同一串里另外一个人、而且不是紧挨着上面那条时才写。
  static func replyTargets(in items: [MarkdownPresentation.CommentItem]) -> [Int: String] {
    var targets: [Int: String] = [:]
    for (index, item) in items.enumerated() where item.depth > 0 && index > 0 {
      guard let parentIndex = items[..<index].lastIndex(where: { $0.depth < item.depth }) else { continue }
      if parentIndex == index - 1 || items[parentIndex].depth == 0 { continue }
      targets[item.sequence] = items[parentIndex].replyHandle
    }
    return targets
  }

  private func commentHeader(
    _ item: MarkdownPresentation.CommentItem,
    replyTarget: String?,
    hovering: Bool
  ) -> some View {
    let author = Self.splitAuthor(item.displayAuthor)
    let isAuthor = Self.isPostAuthor(item.displayAuthor, postAuthor: postAuthor)
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(author.name)
        .font(.system(size: commentFontSize, weight: .semibold))
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
        .accessibilityLabel(accessibilityHeader(for: item, replyTarget: replyTarget) + (isAuthor ? "，作者" : ""))
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
      if let published = item.published {
        let shown = CommentPublishedTime.absoluteLabel(published, capturedAt: commentCapturedAt)
        Text(shown)
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize()
          .help(shown == published ? published : "保存时页面写的是「\(published)」")
      }
      if let replyTarget {
        Text("回复 \(replyTarget)")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor.opacity(0.8))
          .lineLimit(1)
      }
      // 账号退成更淡的灰，排在名字这一组的最后。
      if let handle = author.handle {
        Text(handle)
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor.opacity(0.6))
          .lineLimit(1)
          .truncationMode(.tail)
          .accessibilityHidden(true)
      }
      Spacer(minLength: DesignTokens.Space.xs)
      if let permalink = item.permalink {
        // 小箭头只在鼠标停在这条评论上时出现，贴着点赞数；位置一直留着，出现时不挤动别的东西。
        Button { onOpenURL(permalink) } label: {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(secondaryTextColor.opacity(0.8))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .instantHoverTip("打开原评论")
        .accessibilityLabel("在浏览器中打开 \(item.displayAuthor) 的原评论")
      }
      // 点赞数在这一行最右边，写成「♡ 238」；Reddit 一类的分数同一个位置。
      if let likes = item.likes {
        Text("♡ \(likes)")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize()
      }
      if let score = item.score {
        Text("\(score) 分")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize()
      }
    }
  }

  private func accessibilityHeader(for item: MarkdownPresentation.CommentItem, replyTarget: String?) -> String {
    var parts = ["第 \(item.depth + 1) 层评论", item.displayAuthor]
    if let replyTarget { parts.append("回复 \(replyTarget)") }
    if let score = item.score { parts.append("\(score) 分") }
    if let likes = item.likes { parts.append("\(likes) 赞") }
    if let published = item.published {
      parts.append(CommentPublishedTime.absoluteLabel(published, capturedAt: commentCapturedAt))
    }
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
  ///
  /// `capturedAt` 是这条内容保存的时刻。「8分钟前」是保存当时的相对说法，按它换算；
  /// 不传就不猜，避免把几个月前抓的「8分钟前」算成现在。
  static func absoluteLabel(
    _ raw: String,
    now: Date = Date(),
    calendar: Calendar = .current,
    capturedAt: Date? = nil
  ) -> String {
    if let capturedAt, let resolved = resolvingRelative(raw, capturedAt: capturedAt, now: now, calendar: calendar) {
      return resolved
    }
    if let (date, hasTime) = parsedDisplayDate(raw, calendar: calendar) {
      return stamp(date, now: now, calendar: calendar, withTime: hasTime)
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

  /// 把「8分钟前」「2小时前」按保存时刻换成日期。换算不到就返回 nil，调用方照原样显示。
  private static func resolvingRelative(
    _ raw: String,
    capturedAt: Date,
    now: Date,
    calendar: Calendar
  ) -> String? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if text == "刚刚" { return stamp(capturedAt, now: now, calendar: calendar, withTime: true) }
    if text.hasPrefix("昨天") {
      guard let date = calendar.date(byAdding: .day, value: -1, to: capturedAt) else { return nil }
      return stamp(date, now: now, calendar: calendar, withTime: false)
    }
    if text.hasPrefix("前天") {
      guard let date = calendar.date(byAdding: .day, value: -2, to: capturedAt) else { return nil }
      return stamp(date, now: now, calendar: calendar, withTime: false)
    }
    guard let match = text.wholeMatch(of: /^(\d+)\s*(秒|分钟|小时|天|周|个月|年)前$/) else { return nil }
    let amount = Int(match.1) ?? 0
    let unit = String(match.2)
    let date: Date?
    let withTime: Bool
    switch unit {
    case "秒":
      date = capturedAt.addingTimeInterval(TimeInterval(-amount))
      withTime = true
    case "分钟":
      date = capturedAt.addingTimeInterval(TimeInterval(-amount * 60))
      withTime = true
    case "小时":
      date = capturedAt.addingTimeInterval(TimeInterval(-amount * 3_600))
      withTime = true
    case "天":
      date = calendar.date(byAdding: .day, value: -amount, to: capturedAt)
      withTime = false
    case "周":
      date = calendar.date(byAdding: .day, value: -amount * 7, to: capturedAt)
      withTime = false
    case "个月":
      date = calendar.date(byAdding: .month, value: -amount, to: capturedAt)
      withTime = false
    case "年":
      date = calendar.date(byAdding: .year, value: -amount, to: capturedAt)
      withTime = false
    default:
      return nil
    }
    guard let date else { return nil }
    return stamp(date, now: now, calendar: calendar, withTime: withTime)
  }

  private static func stamp(_ date: Date, now: Date, calendar: Calendar, withTime: Bool) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let sameYear = parts.year == calendar.component(.year, from: now)
    if withTime, sameYear {
      return String(format: "%d月%d日 %02d:%02d", parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0)
    }
    if sameYear { return "\(parts.month ?? 1)月\(parts.day ?? 1)日" }
    return "\(parts.year ?? 0)年\(parts.month ?? 1)月\(parts.day ?? 1)日"
  }

  /// 只认 ISO 8601。导出的 `localStamp` 和「几分钟前」都走这一个，输出格式不随显示用的写法变。
  private static func parsedDate(_ raw: String) -> Date? {
    fractionalISO.date(from: raw) ?? standardISO.date(from: raw)
  }

  /// 阅读区显示用：除 ISO 之外，也认平台直接写出来的本地时间——
  /// 「2026-09-27 19:36」「2026-09-27 19:36:05」「2026/09/27 19:36」「2026-09-27」「2026.9.27」「2026年9月27日 19:36」。
  /// 没写时区的按本机时区算（页面上显示的就是本地时间）。认不出来返回 nil，调用方原样显示。
  static func parsedDisplayDate(_ raw: String, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
    if let date = parsedDate(raw) { return (date, true) }
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard let match = text.wholeMatch(
      of: /(\d{4})[-\/.年](\d{1,2})[-\/.月](\d{1,2})日?(?:[ T]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?/
    ) else { return nil }
    guard let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
          (1...12).contains(month), (1...31).contains(day) else { return nil }
    var parts = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
    var hasTime = false
    if let hourText = match.4, let minuteText = match.5, let hour = Int(hourText), let minute = Int(minuteText) {
      guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
      parts.hour = hour
      parts.minute = minute
      hasTime = true
    }
    guard let date = calendar.date(from: parts) else { return nil }
    // 2 月 30 日这类不存在的日期，Calendar 会悄悄进位成 3 月；对不上就当认不出。
    let check = calendar.dateComponents([.year, .month, .day], from: date)
    guard check.year == year, check.month == month, check.day == day else { return nil }
    return (date, hasTime)
  }
}

/// 把抓来的正文里的评论段拆出来，放进阅读页自己的「评论」页签（2026-10-13）。
/// 库里仍是同一份正文；导出、总结、翻译用的也是原来那份，这里只管阅读页怎么摆。
enum CommentsTabSplit {
  /// 认得出评论结构才拆；认不出就整篇当正文，评论段不会因此消失。
  /// 评论段结束于下一个顶格标题之前，评论后面如果还有别的内容，仍留在正文里。
  static func split(_ body: String) -> (article: String, comments: String) {
    guard let range = MarkdownPresentation.structuredCommentRange(in: body) else { return (body, "") }
    let before = body[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    let after = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    let article = after.isEmpty ? before : (before.isEmpty ? after : before + "\n\n" + after)
    return (article, body[range].trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 评论页签上写的条数：标题里的「已保存 N 条」，没有就数评论本身。
  static func count(inComments markdown: String) -> Int {
    guard !markdown.isEmpty else { return 0 }
    for block in MarkdownPresentation.blocks(from: markdown) {
      if case let .comments(section) = block { return section.loadedCount ?? section.items.count }
    }
    return 0
  }
}
