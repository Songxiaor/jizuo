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
  /// 文字帖卡片正文最多几行：推文多数两三句，六行能完整放下绝大多数。
  static let textPostLineLimit = 6
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

/// 没有封面、没有视频的作品（推文这类文字帖）专用卡片。
///
/// 视频卡的 16:9 封面位对文字帖是负资产：正文被塞进封面位当「图」，
/// 标题又把同一段话写一遍，一半面积空着。这里正文就是主角，只出现一次，
/// 高度跟着内容走，放在瀑布流里（见 CreatorWorkMasonry）。
struct CreatorTextWorkCard<Status: View>: View {
  let theme: HistoryThemeTokens
  /// 译过的中文标题等「另取的标题」。和正文开头重复时不传。
  var heading: String? = nil
  let text: String
  let dateText: String
  var dateHelp: String? = nil
  /// 在这位博主自己的作品里互动排前 10%。
  var isHighlighted: Bool = false
  var host: String
  var metricHelpSuffix: String = ""
  let metric: (CreatorWorkMetricKind) -> String?
  @ViewBuilder var status: () -> Status

  var body: some View {
    CreatorWorkCardShell(theme: theme) {
      EmptyView()
    } text: {
      VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        if let heading, !heading.isEmpty {
          Text(heading)
            .themedFont(.callout, weight: .semibold)
            .foregroundStyle(theme.primaryText)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(text)
          .themedFont(heading == nil ? .callout : .subheadline)
          .foregroundStyle(heading == nil ? theme.primaryText : theme.secondaryText)
          .lineLimit(CreatorWorkCardLayout.textPostLineLimit)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(text)
        status()
        // 互动数在左（自带弹性空白），日期贴右。「高赞」放在这一行最前面，
        // 不单独占一行：翻页后门槛重算、标记出现或消失，卡片高度都不变。
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
          if isHighlighted {
            Image(systemName: "flame.fill")
              .themedFont(.caption2, weight: .semibold)
              .foregroundStyle(theme.accent)
              .help("高赞：在这位博主的作品里，点赞排前 10%")
              .accessibilityLabel("高赞")
          }
          CreatorWorkMetricStrip(host: host, theme: theme, values: metric, helpSuffix: metricHelpSuffix)
          Text(dateText)
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .help(dateHelp ?? dateText)
        }
      }
      .padding(.vertical, 2)
    }
  }
}

extension CreatorTextWorkCard where Status == EmptyView {
  init(
    theme: HistoryThemeTokens, heading: String? = nil, text: String, dateText: String,
    dateHelp: String? = nil, isHighlighted: Bool = false, host: String,
    metricHelpSuffix: String = "", metric: @escaping (CreatorWorkMetricKind) -> String?
  ) {
    self.init(
      theme: theme, heading: heading, text: text, dateText: dateText, dateHelp: dateHelp,
      isHighlighted: isHighlighted, host: host, metricHelpSuffix: metricHelpSuffix, metric: metric,
      status: { EmptyView() }
    )
  }
}

enum CreatorWorkHighlight {
  /// 少于这么多条时不评「高赞」：五条里挑一条前 10% 没有意义。
  static let minimumSampleCount = 10

  /// 点赞达到这个值就算高赞；样本不够或全是 0 时返回 nil。
  static func likesThreshold(_ rawLikes: [String?]) -> Double? {
    let values = rawLikes.compactMap { WorkSortOrder.metric($0) }.filter { $0 > 0 }.sorted()
    guard values.count >= minimumSampleCount else { return nil }
    let index = Int((Double(values.count) * 0.9).rounded(.down))
    return values[min(index, values.count - 1)]
  }

  static func isHighlighted(_ rawLikes: String?, threshold: Double?) -> Bool {
    guard let threshold, let value = WorkSortOrder.metric(rawLikes) else { return false }
    return value >= threshold
  }
}
