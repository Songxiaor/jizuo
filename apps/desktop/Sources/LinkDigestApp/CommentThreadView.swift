import Foundation
import SwiftUI

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
    return VStack(alignment: .leading, spacing: 4) {
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
    .padding(.vertical, visualDepth > 0 ? 6 : DesignTokens.Space.md)
    .frame(maxWidth: readingFont.bodySize * DesignTokens.Layout.readingTextMeasureEm, alignment: .leading)
  }

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
              size: readingFont.bodySize,
              readingFont: readingFont
            )
            Text(attributed)
              .foregroundStyle(primaryTextColor)
              .lineSpacing(MarkdownPresentation.bodyLineSpacing)
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

  private func commentHeader(_ item: MarkdownPresentation.CommentItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(item.displayAuthor)
        .themedFont(.caption, weight: .medium)
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
        .accessibilityLabel(accessibilityHeader(for: item))
      if let parentAuthor = item.parentAuthor {
        Text("回复 \(parentAuthor)")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor.opacity(0.8))
          .lineLimit(1)
      }
      if let published = item.published {
        Text(CommentPublishedTime.absoluteLabel(published))
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
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
        Button { onOpenURL(permalink) } label: {
          Text("原评论 ↗")
            .themedFont(.caption)
            .foregroundStyle(secondaryTextColor)
        }
        .buttonStyle(.plain)
        .help(permalink.absoluteString)
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

  private static func parsedDate(_ raw: String) -> Date? {
    fractionalISO.date(from: raw) ?? standardISO.date(from: raw)
  }
}
