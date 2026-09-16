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
  /// 悬停动作与「按下」动作由父层注入：行只收值，不认识 ViewModel。
  ///
  /// 闭包不参与下面的 `Equatable`——它们捕获的是引用型 model 和这一行固定不变的
  /// taskID，跟行数据无关；放进比较里也没法比（闭包不可比较）。
  var onToggleFavorite: (() -> Void)?
  var onSummarize: (() -> Void)?
  var onActivate: (() -> Void)?
  /// 「更多」菜单：和右键菜单同一份内容，由父层传进来，避免两处各写一遍。
  var moreMenu: (() -> AnyView)?
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 「已总结」只认总结本身。
  ///
  /// 原来判断的是 `artifactPreview != nil`——那是「最近一次运行留下的产物」，
  /// 翻译、脑图同样会写进去，于是只翻译过、从没总结过的内容也被标成绿点，
  /// 而侧栏「待总结」仍然把它算在内：同一条内容两处说法相反。
  private var isSummarized: Bool { row.hasSummary == true }

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
      return DailyNoteTitleFormat.display(
        CapturedDocumentTitle.display(row.title, for: row.canonicalURL)
      )
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
    if row.canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix) {
      return DailyNoteTitleFormat.firstLinePreview(row.sourcePreview)
    }
    return HistoryReadingTitle.listPreview(
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

  /// 日期列永远说清楚「这是哪个时间」。
  ///
  /// 原来只有回落到入库时间时才带「存于」，发布时间是光秃秃一个日期。同一列里
  /// 一半带前缀一半不带，扫过去根本分不清哪条是原文发得早、哪条只是存得早。
  private var compactTimeText: String {
    if let published = row.published?.trimmedNonEmpty {
      return "发布 " + HistoryPublishedTimestampFormatter.compactText(published)
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
        // 预览行原来只喂给 VoiceOver：算好了、骨架屏也给它留了位置，
        // 视觉上却从来没画出来——看得见的人反而比读屏的人知道得少。
        if let preview = rowPreviewLine, preview != rowPrimaryTitle {
          Text(preview)
            .themedFont(.subheadline)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        }
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
    .overlay(alignment: .trailing) { hoverActions }
    .fixedSize(horizontal: false, vertical: true)
    .id("\(row.taskID.rawValue)-\(row.updatedAtMilliseconds)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityValue(rowAccessibilityValue)
    // 读屏和键盘都要能「打开这一条」。整行被合并成一个元素后，里面的
    // 选中手势对 VoiceOver 不可见，没有这条动作就只能念、不能进。
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onActivate?() }
    .accessibilityAction(named: Text("打开")) { onActivate?() }
  }

  private var showsHoverActions: Bool {
    isHovering && (onToggleFavorite != nil || onSummarize != nil || moreMenu != nil)
  }

  /// 悬停时才露出的三个动作。
  ///
  /// 常驻会让每一行右侧都挂三个图标，扫标题时全是噪声；完全藏起来又等于没有——
  /// 所以用 overlay 而不是塞进行内布局：显示和隐藏都不改变行的高度与文字位置。
  @ViewBuilder private var hoverActions: some View {
    if showsHoverActions {
      HStack(spacing: DesignTokens.Space.xxs) {
        if let onToggleFavorite {
          Button(action: onToggleFavorite) {
            Image(systemName: row.isFavorite == true ? "star.fill" : "star")
              .foregroundStyle(row.isFavorite == true ? theme.warning : theme.secondaryText)
          }
          .buttonStyle(.plain)
          .frame(width: 22, height: 20)
          .contentShape(Rectangle())
          .help(row.isFavorite == true ? "取消收藏" : "收藏")
          .accessibilityLabel(row.isFavorite == true ? "取消收藏" : "收藏")
          .accessibilityIdentifier("history-row-favorite")
        }
        if let onSummarize {
          Button(action: onSummarize) {
            Image(systemName: "text.badge.checkmark")
          }
          .buttonStyle(.plain)
          .frame(width: 22, height: 20)
          .contentShape(Rectangle())
          .help("总结这条内容")
          .accessibilityLabel("总结")
          .accessibilityIdentifier("history-row-summarize")
        }
        if let moreMenu {
          Menu { moreMenu() } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 20)
            .help("更多动作")
            .accessibilityLabel("更多")
            .accessibilityIdentifier("history-row-more")
        }
      }
      .font(.system(size: DesignTokens.IconSize.control, weight: .medium))
      .foregroundStyle(theme.secondaryText)
      .padding(.horizontal, DesignTokens.Space.xs)
      .padding(.vertical, DesignTokens.Space.xxs)
      .background(theme.card, in: Capsule())
      .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
      .padding(.trailing, DesignTokens.Space.xs)
      .accessibilityElement(children: .contain)
    }
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

/// 每日笔记的展示标题：「2026-09-15」只是库里的幂等键，眼睛要看的是「9月15日」。
enum DailyNoteTitleFormat {
  static func display(_ stored: String) -> String {
    let parts = stored.split(separator: "-")
    guard parts.count == 3,
          parts[0].count == 4,
          let month = Int(parts[1]), (1...12).contains(month),
          let day = Int(parts[2]), (1...31).contains(day)
    else { return stored }
    return "\(month)月\(day)日"
  }

  static func isISODateTitle(_ stored: String) -> Bool {
    display(stored) != stored
  }

  static func firstLinePreview(_ body: String?) -> String? {
    guard let body else { return nil }
    let cleaned = MarkdownNoteFrontmatter.parse(body).body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == UserNoteDocument.placeholderBody { return nil }
    guard let raw = cleaned.split(whereSeparator: \.isNewline).first else { return nil }
    var line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasPrefix("# ") { line = String(line.dropFirst(2)) }
    if line.isEmpty { return nil }
    return String(line.prefix(240))
  }
}
