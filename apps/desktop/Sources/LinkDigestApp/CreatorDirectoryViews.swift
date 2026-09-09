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
      if let data = try? await DouyinProfilePreviewResource.fetch(url),
         !Task.isCancelled,
         let loaded = NSImage(data: data) {
        image = loaded
      } else if !Task.isCancelled {
        failed = true
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
        HStack(spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 12)
          Text(HistoryPlatformDisplay.name(forHost: platform))
            .themedFont(.headline)
          Text("\(count) 位")
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
          Spacer(minLength: 0)
        }
        .foregroundStyle(theme.primaryText)
        .padding(.vertical, 6)
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

struct CreatorDirectoryCard: View {
  let creator: CreatorSummary
  let theme: HistoryThemeTokens
  let isSelected: Bool
  var onRetryAvatar: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        CreatorDirectoryAvatar(creator: creator, size: 52, theme: theme, onRetry: onRetryAvatar)
        VStack(alignment: .leading, spacing: 3) {
          Text(creator.directoryDisplayName)
            .themedFont(.body, weight: .semibold)
            .foregroundStyle(theme.primaryText)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(HistoryPlatformDisplay.name(forHost: creator.identity.platform))
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
        }
        .layoutPriority(1)
      }
      Text("已保存 \(creator.savedWorkCount) 条作品")
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(1)
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
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

  /// Cover slot shows body text (not a status placeholder).
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

  private var timestampText: String {
    HistoryPublishedTimestampFormatter.directoryCardStamp(
      published: row.published,
      savedAtMilliseconds: row.createdAtMilliseconds ?? row.updatedAtMilliseconds
    )
  }

  private var isWeChat: Bool {
    HistoryPlatformRegistry.canonicalHost(for: row.host) == "mp.weixin.qq.com"
  }
  private var author: String? {
    CreatorDirectoryCardCopy.authorLine(row: row)
  }
  private var hasCoverURL: Bool { displayCoverURL != nil }
  private var coverLoadIdentity: String {
    "\(row.taskID.rawValue)#\(displayCoverURL ?? "")#media:\(row.hasMedia == true)"
  }
  private var showsVideoBadge: Bool { row.hasMedia == true }
  private var statusChips: [String] {
    var chips: [String] = []
    if row.isFavorite == true { chips.append("收藏") }
    if row.hasSummary == true { chips.append("已总结") }
    if row.hasMedia == true, row.hasTranscript != true { chips.append("待转写") }
    return chips
  }

  var body: some View {
    CreatorWorkCardShell(theme: theme) {
      if showsCoverSlot {
        CreatorWorkCardCoverSlot { cover }
      } else {
        CreatorWorkCardCoverSlot { textPreviewCover }
      }
    } text: {
      VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
        if let author {
          Text(author)
            .themedFont(.caption, weight: .medium)
            .foregroundStyle(theme.accent)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        CreatorWorkCardTextHeader(
          title: headline,
          dateText: timestampText,
          theme: theme,
          titleHelp: capturedTitle == CapturedDocumentTitle.missing ? headline : capturedTitle
        )
        if !statusChips.isEmpty || showsVideoBadge {
          HStack(spacing: 6) {
            if showsVideoBadge {
              Label("视频", systemImage: "play.rectangle")
                .themedFont(.caption2, weight: .medium)
                .foregroundStyle(theme.secondaryText)
                .labelStyle(.titleAndIcon)
            }
            ForEach(statusChips, id: \.self) { chip in
              Text(chip)
                .themedFont(.caption2, weight: .medium)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.badge, in: Capsule())
            }
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !isWeChat {
          CreatorWorkMetricStrip(host: row.host, theme: theme, values: { slot in
            slot.value(from: row)
          }, helpSuffix: "保存时")
        }
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
    } else if prefersTextPreview {
      textPreviewCover
    } else {
      coverStatus
    }
  }

  private var textPreviewCover: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(row.directoryCardPreviewLabel)
        .themedFont(.caption2, weight: .medium)
        .foregroundStyle(theme.secondaryText)
      Text(preview)
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(6)
        .multilineTextAlignment(.leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.badge)
  }

  private var coverStatus: some View {
    let status: String = {
      if coverLoading { return "封面加载中" }
      if coverFailed { return "封面加载失败" }
      return "封面未获取"
    }()
    return Text(status)
      .themedFont(.caption2, weight: .medium)
      .foregroundStyle(theme.secondaryText)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.badge)
      .accessibilityLabel(status)
      .help(coverFailed ? "打开作品后可重新抓取原文以更新封面" : status)
      .overlay {
        if coverLoading { ProgressView().controlSize(.small) }
      }
  }
}
