import SwiftUI

/// 设置按工序重组（2026-09-28，Syc 认可设置样稿）。
///
/// 实心章 = 新内容进来会自动做这一步；印位（虚线框空心字）= 要在「处理」里手动点。
/// 每道工序页右上一个「自动」开关，打开时那枚章当场盖下来。
enum SettingsProcessStep: String, CaseIterable, Identifiable {
  case capture, record, proof, comments, summary, translation, mindMap

  var id: String { rawValue }

  var glyph: SealMark.Glyph {
    switch self {
    case .capture: .external
    case .record: .record
    case .proof: .proof
    case .comments: .comments
    case .summary: .summary
    case .translation: .translation
    case .mindMap: .mindMap
    }
  }

  var name: String {
    switch self {
    case .capture: "收集"
    case .record: "转写"
    case .proof: "校对"
    case .comments: "评论"
    case .summary: "总结"
    case .translation: "翻译"
    case .mindMap: "脑图"
    }
  }

  /// 侧栏和页头上的标题：「摘 · 总结」。
  var title: String { "\(glyph.rawValue) · \(name)" }

  var rotation: Double {
    switch self {
    case .capture: -0.8
    case .record: -1.5
    case .proof: 1.2
    case .comments: -0.6
    case .summary: 1.8
    case .translation: -1.1
    case .mindMap: 0.8
    }
  }
}

/// 一枚设置里的印：自动做的是盖好的章，手动的是印位。
struct SettingsStepSeal: View {
  let step: SettingsProcessStep
  let isAuto: Bool
  var size: CGFloat = 20
  let color: Color

  var body: some View {
    if isAuto {
      SealMark(glyph: step.glyph, size: size, color: color, style: .stamped, rotation: step.rotation)
    } else {
      SealMark(glyph: step.glyph, size: size, color: color.opacity(0.75), style: .pending)
    }
  }
}

/// 工序页页头：大印 + 「摘 · 总结」+ 一句话 + 右上「自动」开关。
struct SettingsStepHeader: View {
  let step: SettingsProcessStep
  let caption: String
  /// nil 表示这一步没有「自动」开关（收集一直开着）。
  var isAuto: Binding<Bool>?
  var autoLabel = "自动"
  let sealColor: Color
  let secondaryText: Color
  let hairline: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        seal
          .frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(step.title)
            .font(.custom(ReadingFontCatalog.editorialSerifFamily, size: 22).weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(caption)
            .themedFont(.subheadline)
            .foregroundStyle(secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-step-caption-\(step.rawValue)")
        }
        Spacer(minLength: 12)
        if let isAuto {
          HStack(spacing: 8) {
            Text(autoLabel)
              .themedFont(.subheadline)
              .foregroundStyle(secondaryText)
            Toggle("", isOn: isAuto)
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityLabel("\(step.title) \(autoLabel)")
              .accessibilityIdentifier("settings-step-auto-\(step.rawValue)")
          }
        }
      }
      .padding(.bottom, 18)
      Rectangle().fill(hairline).frame(height: 1)
    }
  }

  /// 打开「自动」时换成 `SealStampView`：新建的视图带着盖下的动画出场。
  @ViewBuilder private var seal: some View {
    let auto = isAuto?.wrappedValue ?? true
    if auto {
      SealStampView(glyph: step.glyph, size: 52, color: sealColor, rotation: step.rotation)
        .id("stamped-\(step.rawValue)")
    } else {
      SealMark(glyph: step.glyph, size: 52, color: sealColor.opacity(0.75), style: .pending)
        .id("pending-\(step.rawValue)")
    }
  }
}

/// 工序总览：「汲 → 录 → 校 → 评 → 摘 → 译 → 图」，点哪枚进哪页。
struct SettingsProcessChain: View {
  let isAuto: (SettingsProcessStep) -> Bool
  let sealColor: Color
  let primaryText: Color
  let secondaryText: Color
  let onSelect: (SettingsProcessStep) -> Void

  var body: some View {
    // 七枚一行放不下时换行，不横向滚动。
    FlowChainLayout(spacing: 2, rowSpacing: 14) {
      ForEach(Array(SettingsProcessStep.allCases.enumerated()), id: \.element) { index, step in
        HStack(alignment: .top, spacing: 2) {
          if index > 0 {
            Text("→")
              .themedFont(.caption)
              .foregroundStyle(secondaryText.opacity(0.6))
              .padding(.top, 18)
              .accessibilityHidden(true)
          }
          Button { onSelect(step) } label: {
            VStack(spacing: 7) {
              SettingsStepSeal(step: step, isAuto: isAuto(step), size: 44, color: sealColor)
                .frame(width: 48, height: 48)
              Text(step.title)
                .themedFont(.subheadline)
                .foregroundStyle(primaryText)
              Text(stateText(step))
                .themedFont(.caption)
                .foregroundStyle(isAuto(step) ? sealColor : secondaryText)
            }
            .frame(width: 66)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(step.title)，\(stateText(step))")
          .accessibilityIdentifier("settings-chain-\(step.rawValue)")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-process-chain")
  }

  private func stateText(_ step: SettingsProcessStep) -> String {
    if step == .capture { return "一直开着" }
    return isAuto(step) ? "自动" : "手动"
  }
}

/// 简单的换行排布：一行放不下就折到下一行。
private struct FlowChainLayout: Layout {
  var spacing: CGFloat
  var rowSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
      x += size.width + spacing
      maxX = max(maxX, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxX, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + rowSpacing; rowHeight = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
