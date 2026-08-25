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
  @State private var visibleRootLimit = 12
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let collapsedReplyLimit = 3
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
          Label("加载更多评论（还有 \(remainingRoots) 条主线）", systemImage: "chevron.down.circle")
            .font(readingFont.scaled(designSize: 13, weight: .medium))
            .foregroundStyle(accentColor)
            .frame(maxWidth: .infinity)
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
      visibleRootLimit = rootLoadStep
    }
    .accessibilityIdentifier("history-content-comment-thread")
  }

  private var sectionHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text(section.countTitle)
        .font(readingFont.scaled(designSize: 19.5, weight: .semibold))
        .foregroundStyle(primaryTextColor)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: DesignTokens.Space.sm)
      if section.isCapped {
        Label("已截取上限", systemImage: "exclamationmark.triangle")
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(secondaryTextColor)
          .help("为保证单次抓取稳定，只保留了平台当前页面中的前若干条评论。")
      }
      if let progressLabel = section.progressLabel {
        Text(progressLabel)
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(secondaryTextColor)
          .padding(.horizontal, DesignTokens.Space.sm)
          .padding(.vertical, DesignTokens.Space.xs)
          .background(secondaryTextColor.opacity(0.08), in: Capsule())
      }
    }
    .padding(.bottom, DesignTokens.Space.sm)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(secondaryTextColor.opacity(0.16))
        .frame(height: 1)
        .accessibilityHidden(true)
    }
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1)
        .fill(accentColor.opacity(0.6))
        .frame(width: 3, height: 16)
        .offset(x: -10, y: -4)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func threadGroup(_ group: ThreadGroup) -> some View {
    let isExpanded = expandedRoots.contains(group.id)
    let visibleLimit = isExpanded ? group.items.count : min(group.items.count, collapsedReplyLimit + 1)
    let visibleItems = Array(group.items.prefix(visibleLimit))
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
        let nextDepth = index + 1 < visibleItems.count ? visibleItems[index + 1].depth : nil
        commentRow(item, continuesFromAvatar: nextDepth.map { $0 > item.depth } ?? false)
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
      Label(title, systemImage: systemImage)
        .themedFont(.caption, weight: .semibold)
        .foregroundStyle(accentColor)
        .padding(.vertical, DesignTokens.Space.sm)
        .padding(.leading, 38)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private func commentRow(
    _ item: MarkdownPresentation.CommentItem,
    continuesFromAvatar: Bool
  ) -> some View {
    let visualDepth = min(item.depth, 3)
    return HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
      CommentThreadRail(
        depth: visualDepth,
        continuesFromAvatar: continuesFromAvatar,
        author: item.replyHandle,
        isDeleted: item.isDeleted,
        lineColor: secondaryTextColor,
        primaryTextColor: primaryTextColor
      )
      .frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        commentHeader(item)
        if let parentAuthor = item.parentAuthor {
          Text("回复 @\(parentAuthor)")
            .themedFont(.caption)
            .foregroundStyle(secondaryTextColor)
        }
        if item.depth > 3 {
          Text("第 \(item.depth + 1) 层回复")
            .themedFont(.caption2, weight: .semibold)
            .foregroundStyle(secondaryTextColor)
            .padding(.horizontal, DesignTokens.Space.sm)
            .padding(.vertical, DesignTokens.Space.xxs)
            .overlay(Capsule().strokeBorder(secondaryTextColor.opacity(0.28), lineWidth: 1))
        }
        if !item.body.isEmpty {
          commentBody(item.body)
        }
      }
      .padding(.vertical, DesignTokens.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
              size: readingFont.scaledSize(15.5),
              readingFont: readingFont
            )
            Text(attributed)
              .foregroundStyle(primaryTextColor)
              .lineSpacing(7)
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
            accentColor: accentColor,
            onOpenURL: onOpenURL
          )
        }
      }
    }
  }

  private func commentHeader(_ item: MarkdownPresentation.CommentItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text(item.displayAuthor)
        .themedFont(.subheadline, weight: .semibold)
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
        .accessibilityLabel(accessibilityHeader(for: item))
      if let score = item.score {
        Text("\(score) 分")
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
      }
      if let published = item.published {
        Text(CommentPublishedTime.relativeLabel(published))
          .themedFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .help(published)
      }
      Spacer(minLength: DesignTokens.Space.xs)
      if let permalink = item.permalink {
        Button { onOpenURL(permalink) } label: {
          Label("原评论", systemImage: "arrow.up.right")
            .themedFont(.caption, weight: .medium)
            .foregroundStyle(accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在浏览器打开 \(item.displayAuthor) 的原评论")
      }
    }
  }

  private func accessibilityHeader(for item: MarkdownPresentation.CommentItem) -> String {
    var parts = ["第 \(item.depth + 1) 层评论", item.displayAuthor]
    if let parentAuthor = item.parentAuthor { parts.append("回复 \(parentAuthor)") }
    if let score = item.score { parts.append("\(score) 分") }
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

private struct CommentThreadRail: View {
  let depth: Int
  let continuesFromAvatar: Bool
  let author: String
  let isDeleted: Bool
  let lineColor: Color
  let primaryTextColor: Color

  private let step: CGFloat = 24
  private let avatarSize: CGFloat = 28
  private let avatarTop: CGFloat = 12

  private var width: CGFloat { avatarSize + CGFloat(depth) * step }
  private var avatarX: CGFloat { avatarSize / 2 + CGFloat(depth) * step }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        ForEach(0..<depth, id: \.self) { level in
          Rectangle()
            .fill(lineColor.opacity(0.22))
            .frame(width: 1, height: proxy.size.height)
            .offset(x: avatarSize / 2 + CGFloat(level) * step)
        }
        if depth > 0 {
          Path { path in
            let parentX = avatarSize / 2 + CGFloat(depth - 1) * step
            let centerY = avatarTop + avatarSize / 2
            path.move(to: CGPoint(x: parentX, y: centerY))
            path.addLine(to: CGPoint(x: avatarX, y: centerY))
          }
          .stroke(lineColor.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        if continuesFromAvatar {
          Rectangle()
            .fill(lineColor.opacity(0.22))
            .frame(width: 1, height: max(proxy.size.height - avatarTop - avatarSize, 0))
            .offset(x: avatarX, y: avatarTop + avatarSize)
        }
        ZStack {
          Circle().fill(avatarColor.opacity(isDeleted ? 0.08 : 0.16))
          Circle().strokeBorder(lineColor.opacity(0.16), lineWidth: 1)
          Text(isDeleted ? "?" : avatarInitial)
            .themedFont(.caption, weight: .bold)
            .foregroundStyle(primaryTextColor)
        }
        .frame(width: avatarSize, height: avatarSize)
        .offset(x: CGFloat(depth) * step, y: avatarTop)
      }
      .accessibilityHidden(true)
    }
    .frame(width: width)
  }

  private var avatarInitial: String {
    let value = author.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.first.map { String($0).uppercased() } ?? "?"
  }

  private var avatarColor: Color {
    let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]
    var hash: UInt32 = 2_166_136_261
    for scalar in author.unicodeScalars {
      hash = (hash ^ scalar.value) &* 16_777_619
    }
    return palette[Int(hash % UInt32(palette.count))]
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

  private static func parsedDate(_ raw: String) -> Date? {
    fractionalISO.date(from: raw) ?? standardISO.date(from: raw)
  }
}
