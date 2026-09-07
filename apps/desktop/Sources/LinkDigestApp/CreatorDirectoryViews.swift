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

struct CreatorSavedWorkCard: View {
  let row: HistoryRowProjection
  let theme: HistoryThemeTokens
  let localCover: (String) async -> URL?

  @State private var coverImage: NSImage?
  @State private var coverFailed = false

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

  private var headline: String { capturedTitle }

  private var timestampText: String {
    HistoryPublishedTimestampFormatter.directoryCardStamp(
      published: row.published,
      savedAtMilliseconds: row.createdAtMilliseconds ?? row.updatedAtMilliseconds
    )
  }

  private var isX: Bool { CreatorWorkMetricLayout.isX(row.host) }
  private var isCompactCard: Bool { CreatorWorkMetricLayout.usesAdaptiveWorkGrid(row.host) }
  private var hasCoverURL: Bool {
    row.coverURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
  private var coverLoadIdentity: String { "\(row.taskID.rawValue)#\(row.coverURL ?? "")#\(row.updatedAtMilliseconds)" }

  var body: some View {
    CreatorWorkCardShell(theme: theme) {
      CreatorWorkCardCoverSlot { cover }
    } text: {
      VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
        CreatorWorkCardTextHeader(
          title: headline,
          dateText: timestampText,
          theme: theme,
          titleHelp: capturedTitle == CapturedDocumentTitle.missing ? headline : capturedTitle
        )
        CreatorWorkMetricStrip(host: row.host, theme: theme, values: { slot in
          slot.value(from: row)
        }, helpSuffix: "保存时")
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .task(id: coverLoadIdentity) {
      coverImage = nil
      coverFailed = false
      guard let cover = row.coverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty else { return }
      if let local = await localCover(cover) {
        let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: local) }.value
        guard !Task.isCancelled else { return }
        if let bytes, let image = NSImage(data: bytes) {
          coverImage = image
          return
        }
      }
      guard !Task.isCancelled else { return }
      guard let admitted = DouyinProfilePreviewResource.admittedURL(cover) else {
        coverFailed = true
        return
      }
      if let data = try? await DouyinProfilePreviewResource.fetch(admitted),
         !Task.isCancelled,
         let image = NSImage(data: data) {
        coverImage = image
      } else if !Task.isCancelled {
        coverFailed = true
      }
    }
  }

  @ViewBuilder private var cover: some View {
    if let coverImage {
      CreatorWorkCardFillImage(image: coverImage)
    } else if hasCoverURL || (isCompactCard && !isX) {
      coverStatus
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text("文字预览")
          .themedFont(.caption2, weight: .medium)
          .foregroundStyle(theme.secondaryText)
        Text(preview)
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
          .lineLimit(isX ? 5 : 7)
          .multilineTextAlignment(.leading)
      }
      .padding(isX ? 8 : 10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(theme.badge)
    }
  }

  private var coverStatus: some View {
    let status = hasCoverURL ? (coverFailed ? "封面加载失败" : "封面加载中") : "封面未获取"
    return Text(status)
      .themedFont(.caption2, weight: .medium)
      .foregroundStyle(theme.secondaryText)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.badge)
      .accessibilityLabel(status)
      .help(coverFailed ? "打开作品后可重新抓取原文以更新封面" : status)
  }
}
