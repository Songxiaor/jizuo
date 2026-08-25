import AppKit
import SwiftUI
import XCTest

@testable import LinkDigestApp

/// 纸质主题的配色不变量。
///
/// 补这一层的理由：把辅助列画布压沉一档（#EFEDE5 → #E6E3D8）时，两个依赖它的
/// 令牌**静默**跌破了各自的下限——次要文字从 4.49:1 掉到 4.10:1（跌破 WCAG AA），
/// 分隔线从 1.067:1 掉到 1.027:1（等于看不见）。当时全套测试是绿的，源码注释里
/// 写着「必须过 4.5:1」也拦不住，因为没有任何一处去核对。
///
/// 所以这里断言的是**关系**而不是色值：改配色不该让测试变红，只有改到把这些
/// 关系破坏掉时才该红。
final class PaperThemeContrastTests: XCTestCase {
  private let tokens = AppearanceTheme.paper.tokens

  // 次要文字压在两种底上——辅助列画布和正文卡片——都必须过 WCAG AA。
  // 这是全窗口出现次数最多的文字层级，掉下去等于整个界面变糊。
  func testSecondaryTextMeetsAAOnBothSurfaces() {
    XCTAssertGreaterThanOrEqual(
      contrastRatio(tokens.secondaryText, tokens.canvas), 4.5,
      "次要文字在辅助列画布上跌破 AA"
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(tokens.secondaryText, tokens.card), 4.5,
      "次要文字在正文卡片上跌破 AA"
    )
  }

  // 正文本身要求更高：AAA 是 7:1。
  func testPrimaryTextMeetsAAAOnBothSurfaces() {
    XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.canvas), 7)
    XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.card), 7)
  }

  // 分隔线不承担可读性，但必须**看得见**。它同时压在两种底上，任何一边
  // 与底色重合，那一侧的分栏和卡片边界就消失了。
  //
  // 1.05 是下限而不是目标：这是一条 1px 的浅灰线，比值再高就从「界线」
  // 变成「框」了。
  func testHairlineStaysVisibleOnBothSurfaces() {
    XCTAssertGreaterThanOrEqual(
      contrastRatio(tokens.hairline, tokens.canvas), 1.05,
      "分隔线在辅助列画布上看不见了"
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(tokens.hairline, tokens.card), 1.05,
      "分隔线在正文卡片上看不见了"
    )
  }

  // 辅助区与正文区的明度差要落在一个区间里，两头都是缺陷：
  //
  // - 太小 → 三栏糊成一片，分不出主次（曾经是 5.3，实测就是「太融为一体」）；
  // - 太大 → 像三个不同的 App 拼在一起。
  //
  // 用 CIE L*（感知明度）而不是 RGB 差值：同样的 RGB 差在暗处和亮处看起来
  // 完全不是一回事，而这两个色都在极亮端。
  func testAuxiliaryAndReadingSurfacesAreDistinctButRelated() {
    let delta = lightness(tokens.card) - lightness(tokens.canvas)
    XCTAssertGreaterThan(delta, 7, "辅助区和正文区的明度差太小，三栏会糊成一片")
    XCTAssertLessThan(delta, 12, "辅助区和正文区的明度差太大，像三个 App 拼在一起")
  }

  // 列表列跟着画布走，不自成一档。三档递进试过，分级方向是反的。
  func testListPaneSharesTheCanvasSurface() {
    XCTAssertEqual(tokens.listPane, tokens.canvas)
  }

  // MARK: - 色度

  /// 取色时必须指定**在哪种外观下**解析。
  ///
  /// 动态语义色（`.primary` / `.secondary`）随外观翻转：深色主题的正文色就是
  /// `.primary`，在浅色外观下解析出来接近纯黑，压在 #1C1C1E 的画布上算出来
  /// 只有 1.2:1。那不是主题坏了，是解析时用错了外观。
  private var appearance: NSAppearance?

  private func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
    var resolved: NSColor?
    let read = { resolved = NSColor(color).usingColorSpace(.sRGB) }
    if let appearance { appearance.performAsCurrentDrawingAppearance(read) } else { read() }
    guard let srgb = resolved else {
      XCTFail("主题令牌必须是可转成 sRGB 的实色，不能是 .clear 或 material")
      return (0, 0, 0)
    }
    return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
  }

  /// WCAG 相对亮度。
  private func relativeLuminance(_ color: Color) -> Double {
    let c = components(color)
    func linear(_ v: Double) -> Double {
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
  }

  private func contrastRatio(_ a: Color, _ b: Color) -> Double {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  /// CIE L*：0 是黑，100 是白，等步长对应等感知明度差。
  private func lightness(_ color: Color) -> Double {
    let y = relativeLuminance(color)
    return y > 0.008856 ? 116 * pow(y, 1.0 / 3.0) - 16 : 903.3 * y
  }

  // 上面几条只盯纸质主题。这一组把同样的门槛铺到**每一个自绘主题**上。
  //
  // 补这一层的理由：暖褐主题的次要文字 #8B7B65 长期只有 2.6:1（远低于 AA），
  // 而当时全套测试是绿的——因为没有任何一条测试看过纸质以外的主题。换配色时
  // 这类缺陷是静默的，只有把门槛铺开才拦得住。
  func testEverySelfDrawnThemeMeetsTheSameContrastFloor() {
    for theme in AppearanceTheme.allCases {
      let t = theme.tokens
      // 系统主题交还 macOS 语义色，canvas 是 .clear，量不出也不该量。
      guard !t.isNative else { continue }
      appearance = theme.renderingAppearance
      defer { appearance = nil }
      let name = theme.displayName
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.secondaryText, t.canvas), 4.5, "\(name)：次要文字在画布上跌破 AA"
      )
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.secondaryText, t.card), 4.5, "\(name)：次要文字在正文卡上跌破 AA"
      )
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.primaryText, t.canvas), 7, "\(name)：正文在画布上跌破 AAA"
      )
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.primaryText, t.card), 7, "\(name)：正文在正文卡上跌破 AAA"
      )
      // 两个面都要验。只验画布是栽过的坑：石楠主题一度想用 ivory-dark 当分隔线，
      // 它对画布 1.290 很正常，对正文卡却只有 1.077——卡片内部的线会消失。
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.hairline, t.canvas), 1.05, "\(name)：分隔线在画布上看不见"
      )
      XCTAssertGreaterThanOrEqual(
        contrastRatio(t.hairline, t.card), 1.05, "\(name)：分隔线在正文卡上看不见"
      )
      // 状态色**故意不在这里断言**。
      //
      // 加过一次，结果把每一套主题都判红了——浅色的 warning 只有 2.58:1、
      // success 3.43:1，深色和高对比也各有不达标的。那是一批更早定下的取值，
      // 波及四套主题的观感，不该在「换掉暖褐」这件事里顺手改掉。
      //
      // 记在这里而不是删掉：这是**已知未修**的一类缺陷，不是没人想到。石楠
      // 主题的状态色已经按 4.5:1 选过（见 SepiaPalette 旁的注释），要收口时
      // 把这段换成真正的断言即可。
      XCTAssertEqual(t.listPane, t.canvas, "\(name)：列表列不该自成一档")
    }
  }

  // 主题之间必须**一眼分得出**，而且分辨点要在底色上——底色占屏幕 95%，
  // 只靠强调色不同不算两套主题。
  //
  // 这条抓到过真事故：旧暖褐画布对浅色画布只有 ΔE 7.0（「接近，易混」），
  // 正文卡之间 5.4，用户的原话是「有点重叠」。
  func testLightThemesAreVisuallyDistinctFromEachOther() {
    // 排除高对比：它的身份是纯黑白的**对比度**，不是底色色相。拿底色 ΔE 去
    // 要求它和浅色拉开，会逼着把它的纯白底染色，反而破坏它存在的理由。
    let lightThemes = AppearanceTheme.allCases.filter {
      !$0.tokens.isNative && $0 != .ink && $0 != .mono
    }
    for (i, a) in lightThemes.enumerated() {
      for b in lightThemes.dropFirst(i + 1) {
        let delta = colorDifference(a.tokens.canvas, b.tokens.canvas)
        XCTAssertGreaterThan(
          delta, 12,
          "\(a.displayName) 和 \(b.displayName) 的画布只差 ΔE \(String(format: "%.1f", delta))，看着是同一套主题"
        )
      }
    }
  }

  /// CIE76 色差。够用：这里只要判「一眼是不是两种颜色」，不需要 CIEDE2000 的精度。
  private func colorDifference(_ a: Color, _ b: Color) -> Double {
    let la = labComponents(a), lb = labComponents(b)
    return sqrt(pow(la.0 - lb.0, 2) + pow(la.1 - lb.1, 2) + pow(la.2 - lb.2, 2))
  }

  private func labComponents(_ color: Color) -> (Double, Double, Double) {
    let c = components(color)
    func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let r = linear(c.r), g = linear(c.g), b = linear(c.b)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
    let fx = f(x), fy = f(y), fz = f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }
}
