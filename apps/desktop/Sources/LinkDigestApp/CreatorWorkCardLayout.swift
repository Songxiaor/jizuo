import SwiftUI
import LinkDigestCore

/// Shared work-card geometry for import selection, reserved queue, and saved cards.
enum CreatorWorkCardLayout {
  /// 所有平台卡片同一个媒体区比例。16:9 而不是 2.35：竖版视频和公众号封面在
  /// 2.35 的窄条里只剩中间一截，16:9 是各平台封面的最大公约数。
  static let coverAspect: CGFloat = 16.0 / 9.0
  /// 按平台定封面比例（2026-09-25）：抖音、小红书本来就是竖屏，3:4 竖卡能看全，
  /// 原来一律 16:9，竖封面只剩中间一截、人脸常被切掉。同一个平台的卡片墙里比例一致，整排仍然齐。
  static func coverAspect(forHost host: String) -> CGFloat {
    switch HistoryPlatformRegistry.canonicalHost(for: host) {
    case "douyin.com", "xiaohongshu.com": 3.0 / 4.0
    default: coverAspect
    }
  }
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
  var aspect: CGFloat = CreatorWorkCardLayout.coverAspect
  @ViewBuilder var content: () -> Content

  var body: some View {
    Color.clear
      .aspectRatio(aspect, contentMode: .fit)
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
    GeometryReader { geometry in
      fill(containerAspect: geometry.size.height > 0 ? geometry.size.width / geometry.size.height : 16.0 / 9.0)
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }

  /// 图和框的比例差得多（竖图放横框、横图放竖框）时，整张放在中间、模糊的同图做底；
  /// 比例接近时直接铺满。原来只判断「是不是竖图」，竖框出现后横图会被裁掉两边。
  @ViewBuilder private func fill(containerAspect: CGFloat) -> some View {
    let imageAspect = image.size.height > 0 ? image.size.width / image.size.height : containerAspect
    let mismatch = max(imageAspect, containerAspect) / max(0.01, min(imageAspect, containerAspect))
    if mismatch > 1.3 {
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
  /// 只显示一个数（卡片墙用，2026-09-25）：点赞优先，其余数字放进悬停提示。
  /// 原来四五个数字挤一排，看不出重点；卡片墙的排序也只按点赞或时间。
  var showsPrimaryOnly: Bool = false

  var body: some View {
    if showsPrimaryOnly {
      primaryStrip
    } else if !visibleSlots.isEmpty {
      // 五个数字放不下时退成只显示一个：原来 fixedSize 的数字把整列撑出窗口，
      // 卡片墙最右一列被切掉半张（2026-10-01 走查，「52.4万」只剩「52.4」）。
      ViewThatFits(in: .horizontal) {
        fullStrip
        primaryStrip
      }
    }
  }

  @ViewBuilder private var primaryStrip: some View {
    if let slot = visibleSlots.first(where: { $0 == .likes }) ?? visibleSlots.first {
      let shown = CreatorWorkMetricLayout.displayValue(values(slot))
      HStack(alignment: .firstTextBaseline, spacing: CreatorWorkCardLayout.metricIconSpacing) {
        Image(systemName: slot.systemImage)
        Text(shown.visible).monospacedDigit().fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 0)
      }
      .lineLimit(1)
      .themedFont(.caption2)
      .foregroundStyle(theme.secondaryText)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .help(visibleSlots.map { helpText($0, shown: CreatorWorkMetricLayout.displayValue(values($0))) }.joined(separator: "\n"))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(slot.title(forHost: host))
      .accessibilityValue(shown.accessibility)
    }
  }

  private var fullStrip: some View {
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
  /// 卡片墙只露点赞（见 `CreatorWorkMetricStrip.showsPrimaryOnly`）。
  var showsPrimaryMetricOnly: Bool = false
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
          CreatorWorkMetricStrip(host: host, theme: theme, values: metric, helpSuffix: metricHelpSuffix, showsPrimaryOnly: showsPrimaryMetricOnly)
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

/// 封面是不是几乎一片纯色（2026-09-25 走查：有的视频封面是全黑首帧，有的是一整张浅色渐变，
/// 一整格什么都看不出来）。缩到 16×16 看亮度起伏，起伏很小就当没有封面。
enum CoverBlankness {
  static func isNearlyUniform(_ image: CGImage) -> Bool {
    let side = 16
    guard let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return false }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = context.data else { return false }
    let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
    var sum = 0.0, squares = 0.0
    for index in 0..<(side * side) {
      let value = Double(pixels[index])
      sum += value; squares += value * value
    }
    let count = Double(side * side)
    let mean = sum / count
    let deviation = (squares / count - mean * mean).squareRoot()
    return deviation < 6
  }
}
