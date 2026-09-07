import SwiftUI
import LinkDigestCore

/// Shared work-card geometry for import selection, reserved queue, and saved cards.
enum CreatorWorkCardLayout {
  /// WeChat gallery should use this same cover ratio.
  static let coverAspect: CGFloat = 2.35
  static let textPadding: CGFloat = 10
  static let textSpacing: CGFloat = 4
  static let metricGap: CGFloat = 3
  static let metricIconSpacing: CGFloat = 1
}

/// Cover is flush to the card top and side edges; callers pad only the text block.
struct CreatorWorkCardShell<Cover: View, TextContent: View>: View {
  let theme: HistoryThemeTokens
  var highlight: Bool = false
  var showsChrome: Bool = true
  @ViewBuilder var cover: () -> Cover
  @ViewBuilder var text: () -> TextContent

  var body: some View {
    let content = VStack(alignment: .leading, spacing: 0) {
      cover()
      text()
        .padding(CreatorWorkCardLayout.textPadding)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    if showsChrome {
      content
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .strokeBorder(highlight ? theme.accent : theme.hairline, lineWidth: highlight ? 2 : 1)
            .allowsHitTesting(false)
        }
    } else {
      content
    }
  }
}

struct CreatorWorkCardCoverSlot<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    Color.clear
      .aspectRatio(CreatorWorkCardLayout.coverAspect, contentMode: .fit)
      .overlay {
        GeometryReader { geometry in
          content()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
      }
  }
}

struct CreatorWorkCardFillImage: View {
  let image: NSImage

  var body: some View {
    Image(nsImage: image)
      .resizable()
      .scaledToFill()
  }
}

struct CreatorWorkCardTextHeader: View {
  let title: String
  let dateText: String
  let theme: HistoryThemeTokens
  var titleHelp: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
      Text(title)
        .themedFont(.callout, weight: .medium)
        .foregroundStyle(theme.primaryText)
        .lineLimit(2, reservesSpace: true)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(titleHelp ?? title)
      Text(dateText)
        .themedFont(.caption2)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// One bottom row of icon + value. Missing shows "—"; real zero stays "0".
struct CreatorWorkMetricStrip: View {
  let host: String
  let theme: HistoryThemeTokens
  let values: (CreatorWorkMetricKind) -> String?
  var helpSuffix: String = ""

  var body: some View {
    HStack(spacing: CreatorWorkCardLayout.metricGap) {
      ForEach(CreatorWorkMetricLayout.slots(forHost: host), id: \.rawValue) { slot in
        let shown = CreatorWorkMetricLayout.displayValue(values(slot))
        HStack(spacing: CreatorWorkCardLayout.metricIconSpacing) {
          Image(systemName: slot.systemImage)
          Text(shown.visible)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
        .help(helpText(slot, shown: shown))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slot.title(forHost: host))
        .accessibilityValue(shown.accessibility)
      }
      Spacer(minLength: 0)
    }
    .themedFont(.caption2)
    .foregroundStyle(theme.secondaryText)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func helpText(_ slot: CreatorWorkMetricKind, shown: (visible: String, accessibility: String)) -> String {
    let suffix = helpSuffix.isEmpty ? "" : " · \(helpSuffix)"
    return "\(slot.title(forHost: host)) \(shown.accessibility)\(suffix)"
  }
}
