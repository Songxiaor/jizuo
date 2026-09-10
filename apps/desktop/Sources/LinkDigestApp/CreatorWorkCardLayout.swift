import SwiftUI
import LinkDigestCore

/// Shared work-card geometry for import selection, reserved queue, and saved cards.
enum CreatorWorkCardLayout {
  /// 所有平台卡片同一个媒体区比例。16:9 而不是 2.35：竖版视频和公众号封面在
  /// 2.35 的窄条里只剩中间一截，16:9 是各平台封面的最大公约数。
  static let coverAspect: CGFloat = 16.0 / 9.0
  /// 媒体区里没有图时的平台图标尺寸。
  static let placeholderIconSize: CGFloat = 28
  /// 卡底互动数据行的固定高度：没有数据的卡也占这一行，整排卡片才等高。
  static let metricRowHeight: CGFloat = 14
  static let textPadding: CGFloat = 10
  static let textSpacing: CGFloat = 4
  static let metricGap: CGFloat = DesignTokens.Space.xs
  static let metricIconSpacing: CGFloat = DesignTokens.Space.xxs
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

  /// 竖版图（抖音、小红书的封面）按 16:9 居中裁只剩身子没有脸。
  /// 竖版改成「模糊放大的同图做底 + 完整缩略图居中」，横版仍然铺满。
  private var isPortrait: Bool {
    image.size.width > 0 && image.size.height > image.size.width * 1.15
  }

  var body: some View {
    if isPortrait {
      ZStack {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .blur(radius: 18)
          .opacity(0.85)
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
      }
    } else {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
    }
  }
}

struct CreatorWorkCardTextHeader: View {
  let title: String?
  let dateText: String
  let theme: HistoryThemeTokens
  var titleHelp: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
      if let title, !title.isEmpty {
        Text(title)
          .themedFont(.callout, weight: .medium)
          .foregroundStyle(theme.primaryText)
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(titleHelp ?? title)
      }
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
    Group {
      if !visibleSlots.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: CreatorWorkCardLayout.metricGap) {
          ForEach(visibleSlots, id: \.rawValue) { slot in
            let shown = CreatorWorkMetricLayout.displayValue(values(slot))
            HStack(alignment: .firstTextBaseline, spacing: CreatorWorkCardLayout.metricIconSpacing) {
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
    }
  }

  private var visibleSlots: [CreatorWorkMetricKind] {
    CreatorWorkMetricLayout.visibleSlots(forHost: host, values: values)
  }

  private func helpText(_ slot: CreatorWorkMetricKind, shown: (visible: String, accessibility: String)) -> String {
    let suffix = helpSuffix.isEmpty ? "" : " · \(helpSuffix)"
    return "\(slot.title(forHost: host)) \(shown.accessibility)\(suffix)"
  }
}
