import SwiftUI
import LinkDigestCore

struct CreatorDirectoryAvatar: View {
  let creator: CreatorSummary
  var size: CGFloat = 32
  let theme: HistoryThemeTokens
  var onRetry: (() -> Void)? = nil
  @State private var image: NSImage?
  @State private var failed = false
  @State private var retryID = 0

  private var admittedURL: URL? {
    creator.avatarURL.flatMap(DouyinProfilePreviewResource.admittedURL)
  }

  /// Same remote URL after「更新资料」still refetches when `updatedAt` or retryID changes.
  var loadIdentity: String {
    "\(admittedURL?.absoluteString ?? "")#\(creator.updatedAtMilliseconds)#\(retryID)"
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else if admittedURL != nil, !failed {
        Circle().fill(theme.badge)
      } else {
        Button(action: retryLoad) {
          Image(systemName: "person.crop.circle.badge.questionmark")
            .font(.system(size: size < 26 ? 12 : 16, weight: .medium))
            .foregroundStyle(theme.secondaryText)
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help("头像未获取，点击重试")
        .accessibilityIdentifier("history-creator-avatar-retry")
        .accessibilityLabel("头像未获取，点击重试")
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .help(admittedURL == nil || failed ? "头像未获取，点击重试" : creator.directoryDisplayName)
    .task(id: loadIdentity) {
      image = nil
      failed = false
      guard let url = admittedURL else { return }
      // 走和封面同一条缩略图线：内存 + 落盘缓存，第二次打开直接读本地，
      // 不再每次都去 X / 抖音重新拉头像。
      do {
        let thumbnail = try await WorkThumbnailLoader.shared.image(url: url, pixels: 160)
        guard !Task.isCancelled else { return }
        image = NSImage(cgImage: thumbnail.image, size: .zero)
      } catch {
        if !Task.isCancelled { failed = true }
      }
    }
    .accessibilityLabel(admittedURL == nil || failed ? "头像未获取，点击重试" : "博主头像")
  }

  private func retryLoad() {
    if admittedURL != nil {
      retryID += 1
      return
    }
    onRetry?()
  }
}

/// Explicit desktop panes avoid NavigationSplitView's adaptive collapse when
/// replacing a reader with a gallery. Kept separate for native geometry tests.
/// Sidebar width is fixed to `sidebarIdeal` so platform gallery and ordinary
/// list share the same navigation width without drag/AppStorage divergence.
struct HistoryGallerySplitView<Sidebar: View, Detail: View>: View {
  @Environment(\.appTheme) private var theme
  let sidebar: Sidebar
  let detail: Detail

  init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
    self.sidebar = sidebar()
    self.detail = detail()
  }

  private var nativeSidebarHorizontalInset: CGFloat {
    // Tahoe's NavigationSplitView places the fixed-width rail inside an
    // 8pt horizontal inset. Match the container, not the row content width.
    if #available(macOS 26.0, *) { return DesignTokens.Space.sm }
    return 0
  }

  var body: some View {
    HSplitView {
      // HSplitView proposes the child's ideal height. A sidebar List then
      // grows to every row and the window clips it with no internal scroll.
      // Fill the pane first, then overlay the rail so the List receives a
      // bounded height and can scroll to 其他 / 标签 at ~700pt.
      Color.clear
        .frame(
          minWidth: DesignTokens.Layout.sidebarIdeal,
          idealWidth: DesignTokens.Layout.sidebarIdeal,
          maxWidth: DesignTokens.Layout.sidebarIdeal,
          minHeight: 0,
          maxHeight: .infinity
        )
        .overlay {
          sidebar.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
        .padding(.horizontal, nativeSidebarHorizontalInset)
        // `.clipped()` 把侧栏列表的底色裁在安全区以内，工具栏那一段就露出窗口的白底，
        // 左上角成了一块白方块。底色单独铺一层并伸到窗口顶。
        .background {
          if !theme.isNative { theme.canvas.ignoresSafeArea(edges: .top) }
        }
      detail.frame(
        minWidth: DesignTokens.Layout.detailMin,
        maxWidth: .infinity,
        minHeight: 0,
        maxHeight: .infinity
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Group only the current search/page results; preserve the existing order within each platform.
struct CreatorDirectoryPlatformGroup: Identifiable {
  let id: String
  let creators: [CreatorSummary]

  static func groups(from creators: [CreatorSummary]) -> [Self] {
    let preferredOrder = ["douyin.com", "xiaohongshu.com", "bilibili.com", "x.com"]
    let grouped = Dictionary(grouping: creators, by: { $0.identity.platform })
    return grouped.keys.sorted { lhs, rhs in
      let left = preferredOrder.firstIndex(of: lhs) ?? preferredOrder.count
      let right = preferredOrder.firstIndex(of: rhs) ?? preferredOrder.count
      return left == right ? lhs < rhs : left < right
    }.map { Self(id: $0, creators: grouped[$0] ?? []) }
  }
}

struct CreatorDirectoryPlatformSection<Content: View>: View {
  let platform: String
  let count: Int
  let theme: HistoryThemeTokens
  @Binding var isExpanded: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(historyUIAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
          isExpanded.toggle()
        }
      } label: {
        // 和侧栏分组标签同一种写法：11pt 中等次要灰，不带折叠箭头，点标题折叠。
        HStack(spacing: 8) {
          Text(HistoryPlatformDisplay.name(forHost: platform))
            .themedFont(.subheadline, weight: .medium)
          Text("\(count) 位")
            .themedFont(.subheadline)
          Spacer(minLength: 0)
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("history-creator-platform-\(platform)")
      .accessibilityLabel("\(HistoryPlatformDisplay.name(forHost: platform))，\(count) 位博主")
      .accessibilityValue(isExpanded ? "已展开" : "已折叠")
      .accessibilityHint("点击展开或折叠此平台博主")
      if isExpanded { content() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 博主目录里的一张卡：横排，头像 + 两行字。
///
/// 原来是竖排大卡（52pt 头像、名字、平台名、「已保存 N 条作品」），一张卡 116pt 高
/// 却只有三行信息，两列排下去右边空一整列。平台名删掉——分组标题已经说了；
/// 0 条作品的博主整卡置灰并标「还没抓取」，一眼分出哪些是空的。
struct CreatorDirectoryCard: View {
  let creator: CreatorSummary
  let theme: HistoryThemeTokens
  let isSelected: Bool
  var onRetryAvatar: (() -> Void)? = nil

  private var isEmpty: Bool { creator.savedWorkCount == 0 }

  private var subtitle: String {
    var parts: [String] = []
    parts.append(isEmpty ? "还没抓取作品" : "\(creator.savedWorkCount) 条作品")
    if creator.isPinned { parts.append("已置顶") }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Space.md) {
      CreatorDirectoryAvatar(creator: creator, size: 40, theme: theme, onRetry: onRetryAvatar)
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text(creator.directoryDisplayName)
          .themedFont(.body, weight: .semibold)
          .foregroundStyle(theme.primaryText)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(subtitle)
          .themedFont(.subheadline)
          .foregroundStyle(theme.secondaryText)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DesignTokens.Space.md)
    .padding(.vertical, DesignTokens.Space.sm)
    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    .opacity(isEmpty ? 0.6 : 1)
    .background(
      isSelected ? theme.accent.opacity(0.12) : theme.card,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(isSelected ? theme.accent.opacity(0.5) : theme.hairline, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(creator.directoryDisplayName)
    .accessibilityValue(
      "\(HistoryPlatformDisplay.name(forHost: creator.identity.platform))，已保存 \(creator.savedWorkCount) 条作品"
    )
  }
}

struct CreatorWorkSelectionControl: View {
  let isSelected: Bool
  let theme: HistoryThemeTokens
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
        .frame(width: 28, height: 28)
        .background(theme.card, in: Circle())
    }
    .buttonStyle(.plain)
    .help("选择这条作品，可多选后批量处理")
    .accessibilityLabel("选择作品")
    .accessibilityValue(isSelected ? "已选择" : "未选择")
  }
}

/// 平台图库里的一张卡。所有平台同一副骨架，高度固定：
///
/// 1. 媒体区 16:9：有封面用封面（竖版模糊底居中）；没有封面就放正文摘录；
///    两者都没有时用平台图标占位。视频卡在媒体区左下角压一个播放角标。
/// 2. 标题两行，固定占两行的高度。没有独立标题的（X 短帖）用作者名当标题。
/// 3. 元信息一行：作者 · 短日期，右端最多两个状态标签（已总结 / 待转写 / 收藏）。
/// 4. 互动数据一行，全平台同一顺序；没有数据也占这一行。
///
/// 原来三种卡（缩略图、总结预览、原文预览）高度各不同，带「已总结」的比不带的
/// 高一行，网格每一行都被最高的那张撑开。骨架固定之后，行天然对齐。
struct CreatorSavedWorkCard: View {
  let row: HistoryRowProjection
  let theme: HistoryThemeTokens
  let localCover: (String?) async -> URL?

  @State private var coverImage: NSImage?
  @State private var coverFailed = false
  @State private var coverLoading = false
  /// Video rows with no landed `Media/` file must not claim「封面加载失败」.
  @State private var prefersTextPreview = false

  private var capturedTitle: String {
    if row.sourceLabel == "X public article endpoint",
       let original = row.title, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return original
    }
    return CapturedContentNaming.name(
      title: row.title, body: row.sourcePreview, host: row.host,
      author: row.author, published: row.published
    ).text
  }

  private var preview: String {
    row.directoryCardPreview(fallbackTitle: capturedTitle)
  }

  /// 媒体区放图还是放摘录。
  private var showsCoverSlot: Bool { hasCoverURL || row.hasMedia == true || prefersTextPreview }
  private var showsBodyPreview: Bool { !showsCoverSlot }
  /// Stored `cover_image` / first markdown image, else a YouTube hqdefault
  /// derived from the canonical watch URL. Display-only.
  private var displayCoverURL: String? {
    if let cover = row.coverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty {
      return cover
    }
    return YouTubeWatchLink.galleryThumbnailURL(fromCanonicalURL: row.canonicalURL)?.absoluteString
  }

  private var headline: String? {
    CreatorDirectoryCardCopy.headline(
      capturedTitle: capturedTitle,
      preview: preview,
      host: row.host,
      hasCover: showsCoverSlot,
      showsBodyPreview: showsBodyPreview
    )
  }

  private var author: String? {
    guard let line = CreatorDirectoryCardCopy.authorLine(row: row),
          !CreatorDirectoryCardCopy.isPlaceholderAuthor(line) else { return nil }
    return line
  }

  /// 标题行：独立标题优先；没有独立标题时用作者名顶上，卡片高度不变。
  /// 两者都没有时退回内容类型（「帖子」「作品」），不留空行。
  private var displayTitle: String {
    if let headline, !headline.isEmpty,
       headline != CreatorDirectoryCardCopy.contentKind(host: row.host) {
      return headline
    }
    if let author, !author.isEmpty { return author }
    return headline ?? CreatorDirectoryCardCopy.contentKind(host: row.host)
  }

  private var titleShowsAuthor: Bool {
    displayTitle == author
  }

  /// 「作者 · 9月8日」。作者已经在标题行时只剩日期。完整时间留给详情页和悬停提示。
  private var metaLine: String {
    var parts: [String] = []
    if !titleShowsAuthor, let author, !author.isEmpty { parts.append(author) }
    parts.append(shortDateText)
    return parts.joined(separator: " · ")
  }

  private var shortDateText: String {
    if let published = row.published?.trimmedNonEmpty {
      return HistoryPublishedTimestampFormatter.compactText(published)
    }
    return "存于 " + HistoryPublishedTimestampFormatter.compactDate(
      Date(timeIntervalSince1970: Double(row.createdAtMilliseconds ?? row.updatedAtMilliseconds) / 1_000)
    )
  }

  private var timestampText: String {
    HistoryPublishedTimestampFormatter.directoryCardStamp(
      published: row.published,
      savedAtMilliseconds: row.createdAtMilliseconds ?? row.updatedAtMilliseconds
    )
  }

  private var isWeChat: Bool {
    HistoryPlatformRegistry.canonicalHost(for: row.host) == "mp.weixin.qq.com"
  }
  private var hasCoverURL: Bool { displayCoverURL != nil }
  private var coverLoadIdentity: String {
    "\(row.taskID.rawValue)#\(displayCoverURL ?? "")#media:\(row.hasMedia == true)"
  }
  /// 抖音、B站、YouTube 的内容本身就是视频，没下载媒体也该标出来；其他平台看有没有媒体。
  private var showsVideoBadge: Bool {
    if row.hasMedia == true { return true }
    return CreatorDirectoryCardCopy.isVideoPlatform(host: row.host)
  }
  /// 最多两个：收藏是用户动作，优先级最高；其次是「还差什么」（待转写）；已总结最低。
  private var statusChips: [String] {
    var chips: [String] = []
    if row.isFavorite == true { chips.append("收藏") }
    if row.hasMedia == true, row.hasTranscript != true { chips.append("待转写") }
    if row.hasSummary == true { chips.append("已总结") }
    return Array(chips.prefix(2))
  }

  var body: some View {
    CreatorWorkCardShell(theme: theme) {
      CreatorWorkCardCoverSlot { cover }
        .overlay(alignment: .bottomLeading) {
          if showsVideoBadge {
            Image(systemName: "play.fill")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 20, height: 20)
              .background(Color.black.opacity(0.55), in: Circle())
              .padding(8)
              .accessibilityLabel("视频")
          }
        }
    } text: {
      VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
        Text(displayTitle)
          .themedFont(.callout, weight: .medium)
          .foregroundStyle(theme.primaryText)
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(capturedTitle == CapturedDocumentTitle.missing ? displayTitle : capturedTitle)

        HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
          Text(metaLine)
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(timestampText)
          Spacer(minLength: DesignTokens.Space.xs)
          ForEach(statusChips, id: \.self) { chip in
            Text(chip)
              .themedFont(.caption2, weight: .medium)
              .foregroundStyle(chip == "待转写" ? theme.warning : theme.secondaryText)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(theme.badge, in: Capsule())
              .fixedSize()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // 互动行固定高度：公众号这类没有指标的卡也占同一行，整排才等高。
        HStack(spacing: 0) {
          if !isWeChat {
            CreatorWorkMetricStrip(host: row.host, theme: theme, values: { slot in
              slot.value(from: row)
            }, helpSuffix: "保存时")
          }
          Spacer(minLength: 0)
        }
        .frame(height: CreatorWorkCardLayout.metricRowHeight, alignment: .leading)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .task(id: coverLoadIdentity) {
      coverImage = nil
      coverFailed = false
      prefersTextPreview = false
      coverLoading = true
      defer { coverLoading = false }
      if let cover = displayCoverURL {
        let local = await localCover(cover)
        guard !Task.isCancelled else { return }
        let admitted = WeChatArticleLayout.coverURL(cover)
          ?? GalleryCoverAdmission.admittedURL(cover)
          ?? (local != nil ? URL(string: cover) : nil)
        if let admitted {
          do {
            let thumbnail = try await WorkThumbnailLoader.shared.image(url: admitted, localURL: local)
            guard !Task.isCancelled else { return }
            coverImage = NSImage(cgImage: thumbnail.image, size: .zero)
            return
          } catch {
            if Task.isCancelled { return }
          }
        }
      }
      if row.hasMedia == true, let file = await localCover(nil) {
        do {
          let thumbnail = try await WorkThumbnailLoader.shared.videoPoster(fileURL: file)
          guard !Task.isCancelled else { return }
          coverImage = NSImage(cgImage: thumbnail.image, size: .zero)
          return
        } catch {
          if Task.isCancelled { return }
        }
      }
      if displayCoverURL != nil || row.hasMedia == true {
        prefersTextPreview = true
      }
    }
  }

  @ViewBuilder private var cover: some View {
    if let coverImage {
      CreatorWorkCardFillImage(image: coverImage)
    } else if coverLoading, hasCoverURL || row.hasMedia == true {
      placeholderCover(showsProgress: true)
    } else if showsBodyPreview || prefersTextPreview {
      textPreviewCover
    } else {
      placeholderCover(showsProgress: false)
    }
  }

  /// 没有封面时媒体区放正文摘录：不再印「原文预览」标签，摘录按句读收尾。
  private var textPreviewCover: some View {
    Text(CreatorDirectoryCardCopy.excerpt(preview))
      .themedFont(.caption)
      .foregroundStyle(theme.secondaryText)
      .lineLimit(6)
      .multilineTextAlignment(.leading)
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(10)
      .background(theme.badge)
  }

  /// 图还没到、或取不到时的占位：纯色底 + 平台图标，不写「封面加载失败」这种字。
  private func placeholderCover(showsProgress: Bool) -> some View {
    ZStack {
      theme.badge
      PlatformNavigationIcon(host: row.host, monochrome: true)
        .foregroundStyle(theme.secondaryText.opacity(0.55))
        .frame(width: CreatorWorkCardLayout.placeholderIconSize, height: CreatorWorkCardLayout.placeholderIconSize)
      if showsProgress { ProgressView().controlSize(.small) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .help(coverFailed ? "封面没取到，打开作品后可重新抓取原文以更新封面" : (showsProgress ? "封面加载中" : "封面未获取"))
    .accessibilityLabel(coverFailed ? "封面加载失败" : (showsProgress ? "封面加载中" : "封面未获取"))
  }
}
