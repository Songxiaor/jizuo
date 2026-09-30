import AppKit
import CoreText
import SwiftUI

/// 汲作的印。
///
/// 两类：
/// - **归属印**「作 / 汲」：自有内容落款，外部内容鉴藏。侧栏、列表用墨线稿（`.line`）。
/// - **工序印**「录 校 评 摘 译 图」：一道加工一枚（2026-09-28 Syc 认可工序印样稿第五版）。
///
/// 一枚印的三个样子：
/// - `.pending` 印位：虚线细框、空心字——这道工序还没做。
/// - `.stamped` 盖好：「汲」圆朱文，其余白文（朱底、字镂空见底色）。印文是《说文》小篆。
/// - 盖下的那一刻由 `SealStampAnimation` 负责。
struct SealMark: View {
  enum Glyph: String, CaseIterable {
    case own = "作"
    case external = "汲"
    case record = "录"
    case proof = "校"
    case comments = "评"
    case summary = "摘"
    case translation = "译"
    case mindMap = "图"

    var accessibilityName: String {
      switch self {
      case .own: "自有"
      case .external: "外部"
      case .record: "转写"
      case .proof: "校对"
      case .comments: "评论"
      case .summary: "总结"
      case .translation: "翻译"
      case .mindMap: "脑图"
      }
    }
  }

  enum Style: Equatable {
    /// 墨线稿：侧栏「自有 / 外部」图标、列表行尾的小「作」。
    case line
    /// 印位：还没盖。
    case pending
    /// 盖好的白文印。
    case stamped
  }

  let glyph: Glyph
  var size: CGFloat = 18
  var color: Color
  var style: Style = .line
  /// 墨线稿的内框细线：题跋旧样式用，侧栏和列表不用。
  var showsInnerFrame = true
  /// 手盖的章总有一点歪。
  var rotation: Double = 0

  /// 印泥色（2026-09-30 Syc 定稿 B · 朱砂）：取自赵孟頫印蜕实拍的印泥，整体压沉一档。
  /// 比界面文字用的朱（theme.seal）亮：那个是为了红字读得清压暗的，铺成整方印就像漆面（09-30 对照实拍）。
  /// 深浅主题同一个颜色：真印泥不随灯光换色。
  static let stampInk = Color(red: 0xDA / 255, green: 0x4F / 255, blue: 0x34 / 255)

  /// 盖好的章、印位用印泥色，印位淡一些；墨线稿仍用调用方给的颜色（侧栏选中、未选中的灰）。
  private var sealColor: Color {
    switch style {
    case .line: color
    case .pending: Self.stampInk.opacity(0.7)
    case .stamped: Self.stampInk
    }
  }

  var body: some View {
    Group {
      switch style {
      case .line: lineSeal
      case .pending: pendingSeal
      case .stamped: stampedSeal
      }
    }
    .frame(width: size, height: size)
    .rotationEffect(.degrees(rotation))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(glyph.accessibilityName)
  }

  // MARK: - 墨线稿

  private var lineSeal: some View {
    ZStack {
      SealFrame(inset: 0)
        .stroke(color, style: StrokeStyle(lineWidth: max(0.9, size * 0.05), lineJoin: .round))
      if showsInnerFrame {
        SealFrame(inset: size * 0.1)
          .stroke(color.opacity(0.28), lineWidth: 0.5)
      }
      Text(glyph.rawValue)
        // 20pt 以下宋体笔画太细、字认不出，小印改用系统黑体半粗；大印才用宋体。
        .font(size < 20
          ? .system(size: size * 0.62, weight: .semibold)
          : .custom(ReadingFontCatalog.editorialSerifFamily, size: size * 0.56).weight(.semibold))
        .foregroundStyle(color)
        .offset(y: -size * 0.02)
    }
  }

  // MARK: - 印位

  private var pendingSeal: some View {
    Canvas { context, canvasSize in
      let unit = canvasSize.width / 100
      let frameWidth = max(2.4 * unit, 0.8)
      context.stroke(
        SealGeometry.frame(inset: 0, unit: unit),
        with: .color(sealColor),
        style: StrokeStyle(lineWidth: frameWidth, lineJoin: .round, dash: [7 * unit, 5 * unit])
      )
      if let glyphPath = SealGeometry.glyphPath(glyph, unit: unit) {
        context.stroke(glyphPath, with: .color(sealColor), style: StrokeStyle(lineWidth: max(1.2 * unit, 0.5), lineJoin: .round))
      }
    }
  }

  // MARK: - 盖好的印

  /// 「汲」是鉴藏印，圆朱文：朱色细框、朱色字，其余见纸。其余七枚是白文：整方朱底，字镂空见纸。
  /// 2026-09-30 Syc 定稿：明代文人印式、新盖的真印不做旧，所以不再有纹样和印泥颗粒。
  private var stampedSeal: some View {
    Canvas { context, canvasSize in
      let unit = canvasSize.width / 100
      if glyph == .external {
        context.stroke(
          SealGeometry.frame(inset: 1.2, unit: unit), with: .color(sealColor),
          style: StrokeStyle(lineWidth: max(2.6 * unit, 0.7), lineJoin: .round)
        )
        if let glyphPath = SealGeometry.glyphPath(glyph, unit: unit) {
          context.fill(glyphPath, with: .color(sealColor))
          context.stroke(glyphPath, with: .color(sealColor), style: StrokeStyle(lineWidth: max(0.5 * unit, 0.25), lineJoin: .round))
        }
        return
      }
      context.fill(SealGeometry.frame(inset: 0, unit: unit), with: .color(sealColor))
      // 字是「刻掉」的：镂空见底色，深浅主题都对。
      context.blendMode = .destinationOut
      if let glyphPath = SealGeometry.glyphPath(glyph, unit: unit) {
        context.fill(glyphPath, with: .color(.black))
        context.stroke(glyphPath, with: .color(.black), style: StrokeStyle(lineWidth: 1.1 * unit, lineJoin: .round))
      }
    }
    // 镂空只作用在印自己这一层，不把背后的界面也掏空。
    .compositingGroup()
  }
}

/// 略带手刻不齐的方框：四个角各偏一点点，不做仿古纹理。
private struct SealFrame: Shape {
  let inset: CGFloat

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: inset + 0.6, dy: inset + 0.6)
    let w = r.width
    var path = Path()
    path.move(to: CGPoint(x: r.minX + w * 0.01, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + w * 0.015))
    path.addLine(to: CGPoint(x: r.maxX - w * 0.005, y: r.maxY))
    path.addLine(to: CGPoint(x: r.minX, y: r.maxY - w * 0.012))
    path.closeSubpath()
    return path
  }
}

/// 印的几何：100 格坐标，画的时候乘 `unit`。
enum SealGeometry {
  static func frame(inset: CGFloat, unit: CGFloat) -> Path {
    let a = inset + 3
    let w = 100 - a * 2
    var path = Path()
    path.move(to: CGPoint(x: (a + w * 0.01) * unit, y: a * unit))
    path.addLine(to: CGPoint(x: (a + w) * unit, y: (a + w * 0.015) * unit))
    path.addLine(to: CGPoint(x: (a + w - w * 0.005) * unit, y: (a + w) * unit))
    path.addLine(to: CGPoint(x: a * unit, y: (a + w - w * 0.012) * unit))
    path.closeSubpath()
    return path
  }

  /// 印文：《说文》小篆字形，已按印面排好（`SealGlyphData`）。
  static func glyphPath(_ glyph: SealMark.Glyph, unit: CGFloat) -> Path? {
    unitPath(glyph.rawValue)?.applying(CGAffineTransform(scaleX: unit, y: unit))
  }

  // 字形只在主线程画印时取；NSCache 本身线程安全。
  nonisolated(unsafe) private static let glyphCache = NSCache<NSString, GlyphBox>()
  private final class GlyphBox { let path: Path; init(_ path: Path) { self.path = path } }

  /// 100 格坐标里的一块印文；`key` 是单字印的字，或两字印的 `brand-zuo` / `brand-ji`。
  static func unitPath(_ key: String) -> Path? {
    if let hit = glyphCache.object(forKey: key as NSString) { return hit.path }
    guard let d = SealGlyphData.paths[key] else { return nil }
    let path = SVGPath.parse(d)
    glyphCache.setObject(GlyphBox(path), forKey: key as NSString)
    return path
  }
}

/// 「汲作」两字印（2026-09-30 Syc 定稿丙，朱砂）：右「汲」朱文、左「作」白文，古法右起读。
/// 白文「作」是自有，朱文「汲」是外部，一方印里两类都在。用在侧栏顶部。
struct BrandSealMark: View {
  var size: CGFloat = 36

  var body: some View {
    Canvas { context, canvasSize in
      let unit = canvasSize.width / 100
      let ink = SealMark.stampInk
      // 左半：朱底，「作」镂空。
      var left = Path()
      left.addRoundedRect(in: CGRect(x: 3.5 * unit, y: 3.5 * unit, width: 47.1 * unit, height: 93 * unit), cornerSize: CGSize(width: 1.5 * unit, height: 1.5 * unit))
      context.drawLayer { layer in
        layer.fill(left, with: .color(ink))
        layer.blendMode = .destinationOut
        if let zuo = SealGeometry.unitPath("brand-zuo")?.applying(CGAffineTransform(scaleX: unit, y: unit)) {
          layer.fill(zuo, with: .color(.black))
          layer.stroke(zuo, with: .color(.black), style: StrokeStyle(lineWidth: 1.4 * unit, lineJoin: .round))
        }
      }
      // 右半：朱框，「汲」朱文。
      var right = Path()
      right.move(to: CGPoint(x: 50.6 * unit, y: 5.2 * unit))
      right.addLine(to: CGPoint(x: 94.8 * unit, y: 5.2 * unit))
      right.addLine(to: CGPoint(x: 94.8 * unit, y: 94.8 * unit))
      right.addLine(to: CGPoint(x: 50.6 * unit, y: 94.8 * unit))
      context.stroke(right, with: .color(ink), style: StrokeStyle(lineWidth: 3.4 * unit, lineJoin: .round))
      if let ji = SealGeometry.unitPath("brand-ji")?.applying(CGAffineTransform(scaleX: unit, y: unit)) {
        context.fill(ji, with: .color(ink))
        context.stroke(ji, with: .color(ink), style: StrokeStyle(lineWidth: 0.84 * unit, lineJoin: .round))
      }
    }
    .frame(width: size, height: size)
    .compositingGroup()
    .accessibilityHidden(true)
  }
}

/// 最小的 SVG 路径解析：M L H V Q C S A Z（含小写相对坐标），够画印的纹样。
enum SVGPath {
  static func parse(_ d: String) -> Path {
    var tokens = tokenize(d)
    var path = Path()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var lastControl: CGPoint?
    var command: Character = "M"
    func number() -> CGFloat { tokens.isEmpty ? 0 : CGFloat(Double(tokens.removeFirst()) ?? 0) }
    while !tokens.isEmpty {
      if let first = tokens.first?.first, first.isLetter {
        command = first
        tokens.removeFirst()
      }
      let relative = command.isLowercase
      let base = relative ? current : .zero
      switch command.uppercased().first! {
      case "M":
        current = CGPoint(x: base.x + number(), y: base.y + number())
        start = current
        path.move(to: current)
        command = relative ? "l" : "L"
        lastControl = nil
      case "L":
        current = CGPoint(x: base.x + number(), y: base.y + number())
        path.addLine(to: current)
        lastControl = nil
      case "H":
        current = CGPoint(x: (relative ? current.x : 0) + number(), y: current.y)
        path.addLine(to: current)
        lastControl = nil
      case "V":
        current = CGPoint(x: current.x, y: (relative ? current.y : 0) + number())
        path.addLine(to: current)
        lastControl = nil
      case "Q":
        let control = CGPoint(x: base.x + number(), y: base.y + number())
        current = CGPoint(x: base.x + number(), y: base.y + number())
        path.addQuadCurve(to: current, control: control)
        lastControl = nil
      case "C":
        let c1 = CGPoint(x: base.x + number(), y: base.y + number())
        let c2 = CGPoint(x: base.x + number(), y: base.y + number())
        current = CGPoint(x: base.x + number(), y: base.y + number())
        path.addCurve(to: current, control1: c1, control2: c2)
        lastControl = c2
      case "S":
        let reflected = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
        let c2 = CGPoint(x: base.x + number(), y: base.y + number())
        current = CGPoint(x: base.x + number(), y: base.y + number())
        path.addCurve(to: current, control1: reflected, control2: c2)
        lastControl = c2
      case "A":
        // 只用到正圆弧：rx = ry、不旋转。按端点求圆心再画。
        let radius = number()
        _ = number(); _ = number()
        let largeArc = number() != 0
        let sweep = number() != 0
        let end = CGPoint(x: base.x + number(), y: base.y + number())
        addArc(to: &path, from: current, to: end, radius: radius, largeArc: largeArc, sweep: sweep)
        current = end
        lastControl = nil
      case "Z":
        path.closeSubpath()
        current = start
        lastControl = nil
      default:
        tokens.removeFirst()
      }
    }
    return path
  }

  private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, radius: CGFloat, largeArc: Bool, sweep: Bool) {
    let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
    let dx = p1.x - p0.x, dy = p1.y - p0.y
    let chord = sqrt(dx * dx + dy * dy)
    guard chord > 0, radius * 2 >= chord else { path.addLine(to: p1); return }
    let h = sqrt(radius * radius - (chord / 2) * (chord / 2))
    // 两个候选圆心，按 largeArc / sweep 选一个。
    let sign: CGFloat = (largeArc != sweep) ? 1 : -1
    let center = CGPoint(x: mid.x - sign * h * dy / chord, y: mid.y + sign * h * dx / chord)
    let a0 = atan2(p0.y - center.y, p0.x - center.x)
    let a1 = atan2(p1.y - center.y, p1.x - center.x)
    // SVG 的 sweep=1 是顺时针（y 朝下的屏幕坐标里角度增大）。
    path.addArc(center: center, radius: radius, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: !sweep)
  }

  private static func tokenize(_ d: String) -> [String] {
    var tokens: [String] = []
    var number = ""
    func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
    for character in d {
      if character.isLetter, character != "e" {
        flush(); tokens.append(String(character))
      } else if character == "-" {
        flush(); number = "-"
      } else if character == " " || character == "," {
        flush()
      } else {
        number.append(character)
      }
    }
    flush()
    return tokens
  }
}

/// 墨线闲章：设置里「通用」各页和工序下的子页用（2026-09-28 Syc 选定方案一）。
///
/// 朱色只给工序；这些不是工序，用灰色墨线：细框、实心字、不上朱。和主窗口侧栏
/// 「自有 / 外部」那两枚墨线印同一种画法。印文取名字里的一个字，一看就对得上。
struct InkSealMark: View {
  let character: String
  var size: CGFloat = 20
  var color: Color

  var body: some View {
    ZStack {
      SealFrame(inset: 0)
        .stroke(color, style: StrokeStyle(lineWidth: max(0.9, size * 0.05), lineJoin: .round))
      Text(character)
        .font(size < 24
          ? .system(size: size * 0.6, weight: .medium)
          : .custom(ReadingFontCatalog.editorialSerifFamily, size: size * 0.56).weight(.semibold))
        .foregroundStyle(color)
        .offset(y: -size * 0.02)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  /// 设置页名字 → 印文。侧栏和页头都查这一张表，改一处两边一起变。
  static let settingsGlyphs: [String: String] = [
    "工序总览": "序",
    "浏览器支持": "扩",
    "站点登录": "登",
    "视频存储": "存",
    "模型服务": "模",
    "外观": "观",
    "数据与备份": "备",
    "知识库同步": "库",
    "手机同步": "机",
    "AI 助手接入": "接",
    "版本与更新": "新",
    "实验室": "试",
  ]
}

