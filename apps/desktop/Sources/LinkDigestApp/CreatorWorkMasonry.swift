import SwiftUI
import LinkDigestCore

/// 博主作品页的瀑布流（小红书式）：每列各自往下排，卡片高矮不一。
///
/// 分列只看**每张卡自己的内容**估出来的高度，按出现顺序放进当前最矮的一列。
/// 翻页加载的新作品排在后面，只会接在后面分列，不会让已经显示的卡片换列——
/// 否则往下滑时整片内容重排，会出现滑到一半卡住、抽动。
enum CreatorWorkMasonry {
  /// 估算用的卡片高度（pt）。只用于分列，不参与真实布局。
  ///
  /// 中文一个字约占一个字号宽，英文字母约半个：不分开算，纯英文卡会被高估、
  /// 纯中文卡被低估，最后一列提前排完，滑到底时一整列空着。
  static func estimatedHeight(text: String?, hasHeading: Bool = false, hasCover: Bool, columnWidth: CGFloat) -> CGFloat {
    let chrome: CGFloat = 56 // 内边距 + 底部互动行
    if hasCover {
      return columnWidth * 9 / 16 + chrome + 44
    }
    let fontSize: CGFloat = 15
    let units = (text ?? "").reduce(CGFloat(0)) { total, character in
      total + (character.unicodeScalars.first.map { $0.value >= 0x2E80 } == true ? 1 : 0.52)
    }
    let perLine = max(1, (columnWidth - 20) / fontSize)
    let lines = min(CGFloat(CreatorWorkCardLayout.textPostLineLimit), max(1, (units / perLine).rounded(.up)))
    return chrome + lines * 19 + (hasHeading ? 44 : 0)
  }

  /// 按顺序把每一项放进当前估算最矮的列，返回每列的下标数组。
  ///
  /// `pinned` 是之前已经分好的列：只要还在，就留在原列，不按新的估高重分。
  /// 翻页后「预留卡」换成「已保存卡」、估高变了，也不会换列。
  static func columns(
    ids: [AnyHashable]? = nil,
    heights: [CGFloat],
    count: Int,
    pinned: [AnyHashable: Int] = [:]
  ) -> [[Int]] {
    let count = max(1, count)
    var columns = Array(repeating: [Int](), count: count)
    var totals = Array(repeating: CGFloat(0), count: count)
    for (index, height) in heights.enumerated() {
      let id = ids.flatMap { index < $0.count ? $0[index] : nil }
      let target: Int
      if let id, let column = pinned[id], column < count {
        target = column
      } else {
        target = totals.indices.min { totals[$0] < totals[$1] } ?? 0
      }
      columns[target].append(index)
      totals[target] += height
    }
    return columns
  }
}

/// 卡片真实高度的暂存处。故意不是 @Observable：一百张卡各量一次就触发一百次整页重算；
/// 这里先攒着，停止变化一小会儿后再通过一次状态更新统一交给布局。
@MainActor
final class CreatorMasonryHeightBox {
  var key = ""
  var heights: [AnyHashable: CGFloat] = [:]
  private var commitTask: Task<Void, Never>?

  func record(_ height: CGFloat, for id: AnyHashable, key: String, commit: @escaping @MainActor () -> Void) {
    if self.key != key {
      self.key = key
      heights = [:]
    }
    guard abs((heights[id] ?? -1) - height) > 0.5 else { return }
    heights[id] = height
    commitTask?.cancel()
    commitTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      commit()
    }
  }
}

/// 选择圆圈只在鼠标移上去、或已经在多选时出现：平时不压住文字帖的正文。
struct CreatorWorkHoverSelection<Content: View, Control: View>: View {
  let alwaysVisible: Bool
  @ViewBuilder var content: () -> Content
  @ViewBuilder var control: () -> Control
  @State private var isHovering = false

  var body: some View {
    content()
      .overlay(alignment: .topTrailing) {
        if alwaysVisible || isHovering {
          control()
        }
      }
      .onHover { isHovering = $0 }
  }
}
