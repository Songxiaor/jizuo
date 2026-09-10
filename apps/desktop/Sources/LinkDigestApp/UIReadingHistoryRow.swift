import AppKit
import SwiftUI
import LinkDigestCore

/// 资料列表行：平台图标与总结状态叠在同一锚点，选中只靠浅底，不另占左栏。
/// 时间语义与 `HistoryRowView` 一致：有发布时间用发布，否则标明「存于」。
struct UIReadingHistoryRow: View {
  let row: HistoryRowProjection
  let isSelected: Bool
  let faviconURL: URL?
  let theme: HistoryThemeTokens
  /// 同一博主连续多条时，从第二条起副标题只留日期，不再每行重复作者名。
  var showsAuthor: Bool = true
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isSummarized: Bool {
    row.artifactPreview?.trimmedNonEmpty != nil
  }

  @ViewBuilder private var statusIndicator: some View {
    if theme.encodesStatusByShape {
      if isSummarized {
        Circle().fill(theme.primaryText)
      } else {
        Circle().strokeBorder(theme.primaryText, lineWidth: 1.5)
      }
    } else {
      Circle().fill(isSummarized ? theme.success : theme.warning)
    }
  }

  private var capturedTitle: String {
    if row.sourceLabel == "X public article endpoint",
       let original = row.title, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return original
    }
    if row.canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix) {
      return CapturedDocumentTitle.display(row.title, for: row.canonicalURL)
    }
    return CapturedContentNaming.name(
      title: row.title, body: row.sourcePreview, host: row.host,
      author: row.author, published: row.published
    ).text
  }

  private var cleanedArtifactPreview: String? {
    guard let preview = row.artifactPreview?.trimmedNonEmpty else { return nil }
    let cleaned = MarkdownNoteFrontmatter.strippingCapturedEnvelope(from: preview)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  private var rowPrimaryTitle: String {
    HistoryReadingTitle.primaryTitle(captured: capturedTitle, artifactPreview: cleanedArtifactPreview)
  }

  private var rowPreviewLine: String? {
    HistoryReadingTitle.listPreview(
      artifactPreview: cleanedArtifactPreview,
      primaryTitle: rowPrimaryTitle,
      authorFallback: row.author
    )
  }

  private var rowTimeText: String {
    if let published = row.published?.trimmedNonEmpty {
      return HistoryPublishedTimestampFormatter.text(published)
    }
    return "存于 \(HistoryRelativeTime.text(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))"
  }

  private var rowSourceText: String {
    row.author?.trimmedNonEmpty ?? HistoryPlatformDisplay.name(forHost: row.host)
  }

  private var compactTimeText: String {
    if let published = row.published?.trimmedNonEmpty {
      return HistoryPublishedTimestampFormatter.compactText(published)
    }
    return "存于 " + HistoryPublishedTimestampFormatter.compactDate(
      Date(timeIntervalSince1970: Double(row.createdAtMilliseconds ?? row.updatedAtMilliseconds) / 1_000)
    )
  }

  private var rowAccessibilityLabel: String { rowPrimaryTitle }

  private var rowAccessibilityValue: String {
    var values = [
      "来源：\(rowSourceText)",
      rowTimeText,
      isSummarized ? "已总结" : "未总结",
    ]
    if let preview = rowPreviewLine, preview.count < 40, preview != rowPrimaryTitle {
      values.insert(preview, at: 1)
    }
    if row.hasTranscript == true {
      values.append("已转写")
    } else if row.hasMedia == true {
      values.append("有视频，还没转写")
    }
    if row.hasMindMap == true { values.append("已生成脑图") }
    return values.joined(separator: "，")
  }

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
      ZStack(alignment: .bottomTrailing) {
        favicon
        statusIndicator
          .frame(width: 7, height: 7)
          .background(
            Circle().fill(theme.listPane).padding(-1.5)
          )
          .offset(x: 1, y: 1)
          .help(isSummarized ? "已总结" : "未总结")
          .accessibilityLabel("总结状态")
          .accessibilityValue(isSummarized ? "已总结" : "未总结")
      }
      .frame(width: 18, height: 18)
      .padding(.trailing, 2)
      .padding(.bottom, 2)
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text(rowPrimaryTitle)
          .themedFont(.body, weight: .semibold)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(alignment: .center, spacing: DesignTokens.Space.xs) {
          Text(showsAuthor ? rowSourceText : "")
            .themedFont(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(compactTimeText)
            .themedFont(.subheadline)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .help(rowTimeText)
          HStack(spacing: 4) {
            if row.hasTranscript == true {
              Image(systemName: "waveform")
                .help("已转写")
                .accessibilityLabel("已转写")
            } else if row.hasMedia == true {
              Image(systemName: "waveform.slash")
                .foregroundStyle(theme.warning)
                .help("有视频，还没转写")
                .accessibilityLabel("有视频，还没转写")
                .accessibilityIdentifier("history-row-needs-transcript")
            }
            if row.hasMindMap == true {
              Image(systemName: "brain")
                .help("已生成脑图")
                .accessibilityLabel("已生成脑图")
            }
          }
          .font(.system(size: BadgeTypography.size))
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("history-row-status-badges")
        }
      }
    }
    .padding(.horizontal, DesignTokens.Space.xs)
    .padding(.vertical, DesignTokens.Space.xs)
    .frame(minHeight: 44, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(rowBackground)
    )
    .background(UIReadingListSelectionStyle(usesSystemSelection: theme.isNative))
    .foregroundStyle(theme.primaryText)
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
    .fixedSize(horizontal: false, vertical: true)
    .id("\(row.taskID.rawValue)-\(row.updatedAtMilliseconds)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityValue(rowAccessibilityValue)
  }

  private var rowBackground: Color {
    if isSelected && !theme.isNative { return theme.accent.opacity(0.12) }
    if isHovering && !isSelected { return theme.primaryText.opacity(0.035) }
    return .clear
  }

  @ViewBuilder private var favicon: some View {
    if row.host == HistoryPlatformDisplay.noteHost {
      Image(systemName: "square.and.pencil")
        .font(.system(size: DesignTokens.IconSize.inline, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 18, height: 18)
        .accessibilityLabel("笔记")
    } else if let image = PlatformIconCatalog.image(for: row.host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        .accessibilityLabel("\(row.host) 图标")
    } else if let url = faviconURL {
      HistoryFaviconDiskImage(url: url, host: row.host, taskID: row.taskID) {
        fallbackBadge
      }
    } else {
      fallbackBadge
    }
  }

  private var fallbackBadge: some View {
    Text(PlatformIconCatalog.fallbackInitial(for: row.host))
      .font(.system(size: BadgeTypography.size, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 18, height: 18)
      .background(PlatformIconCatalog.fallbackColor(for: row.host), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
      .accessibilityLabel("\(row.host) 图标")
  }
}

extension UIReadingHistoryRow: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.isSelected == rhs.isSelected
      && lhs.faviconURL == rhs.faviconURL
      && lhs.theme == rhs.theme
      && lhs.showsAuthor == rhs.showsAuthor
  }

  static func repeatsPreviousAuthor(in rows: [HistoryRowProjection], at index: Int) -> Bool {
    guard index > 0, index < rows.count, let author = rows[index].author?.trimmedNonEmpty else { return false }
    let previous = rows[index - 1]
    return previous.author?.trimmedNonEmpty == author
      && HistoryPlatformRegistry.canonicalHost(for: previous.host) == HistoryPlatformRegistry.canonicalHost(for: rows[index].host)
  }
}

/// 与 `HistoryRowView` 相同：关掉系统选中底，主题色由行自己画。
private struct UIReadingListSelectionStyle: NSViewRepresentable {
  var usesSystemSelection: Bool

  func makeNSView(context: Context) -> SelectionView { SelectionView() }

  func updateNSView(_ view: SelectionView, context: Context) {
    view.usesSystemSelection = usesSystemSelection
    view.applyStyle()
    DispatchQueue.main.async { [weak view] in view?.applyStyle() }
  }

  final class SelectionView: NSView {
    var usesSystemSelection = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      applyStyle()
    }
    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      applyStyle()
    }
    func applyStyle() {
      var ancestor = superview
      while let view = ancestor {
        if let table = view as? NSTableView {
          let style: NSTableView.SelectionHighlightStyle = usesSystemSelection ? .regular : .none
          if table.selectionHighlightStyle != style { table.selectionHighlightStyle = style }
          return
        }
        ancestor = view.superview
      }
    }
  }
}
