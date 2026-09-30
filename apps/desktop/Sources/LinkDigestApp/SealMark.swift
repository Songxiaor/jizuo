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
/// - `.pending` 印位：虚线细框、空心字，没有纹样也没有印泥——这道工序还没做。
/// - `.stamped` 盖好：白文（朱底、字和纹样镂空见底色）、双框、寓意纹样、印泥颗粒。
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

  @Environment(\.colorScheme) private var colorScheme

  /// 深色主题下的朱砂：主题里的朱（E07A66）是为了红字在深底上读得清而提亮的，
  /// 整块铺成章就成了粉色瓷砖（2026-09-29 走查）。章本身用沉一些的朱砂，红字不受影响。
  static let darkCinnabar = Color(red: 0xC8 / 255, green: 0x48 / 255, blue: 0x30 / 255)

  /// 盖好的章、印位用的颜色：深色主题换成朱砂，保留调用方给的透明度层级（印位更淡）。
  private var sealColor: Color {
    guard colorScheme == .dark, style != .line else { return color }
    return style == .pending ? Self.darkCinnabar.opacity(0.85) : Self.darkCinnabar
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
      if let glyphPath = SealGeometry.glyphPath(glyph.rawValue, unit: unit) {
        context.stroke(glyphPath, with: .color(sealColor), style: StrokeStyle(lineWidth: max(1.4 * unit, 0.55), lineJoin: .round))
      }
    }
  }

  // MARK: - 盖好的白文印

  private var stampedSeal: some View {
    Canvas { context, canvasSize in
      let unit = canvasSize.width / 100
      // 整方朱底。
      context.fill(SealGeometry.frame(inset: 0, unit: unit), with: .color(sealColor))
      context.stroke(
        SealGeometry.frame(inset: 0, unit: unit), with: .color(sealColor),
        style: StrokeStyle(lineWidth: max(5 * unit, 0.9), lineJoin: .round)
      )
      // 字、内框、纹样都是「刻掉」的：镂空见底色，深浅主题都对。
      context.blendMode = .destinationOut
      context.stroke(
        SealGeometry.frame(inset: 9, unit: unit),
        with: .color(.black.opacity(0.55)),
        lineWidth: max(0.6 * max(2.2 * unit, 0.55), 0.4)
      )
      let motifWidth = max(2.2 * unit, 0.55)
      for element in SealMotifs.elements(for: glyph) {
        let path = element.path(unit: unit)
        switch element.paint {
        case .stroke: context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: motifWidth, lineCap: .round, lineJoin: .round))
        case .faint:
          let dash = (element.dash ?? []).map { $0 * unit }
          context.stroke(path, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: motifWidth, lineCap: .round, lineJoin: .round, dash: dash))
        case .fill: context.fill(path, with: .color(.black))
        }
      }
      if let glyphPath = SealGeometry.glyphPath(glyph.rawValue, unit: unit) {
        context.fill(glyphPath, with: .color(.black))
      }
      // 印泥不匀：按字定下的一把随机小点，把朱色啄掉一些；边缘多啄几下，像手盖的毛边。
      for speck in SealGeometry.specks(seed: glyph.rawValue.unicodeScalars.first?.value ?? 1) {
        let rect = CGRect(
          x: speck.x * unit - speck.r * unit, y: speck.y * unit - speck.r * unit,
          width: speck.r * 2 * unit, height: speck.r * 2 * unit
        )
        context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(speck.alpha)))
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

  /// 印文的字形轮廓（宋体半粗），居中放进 100 格里约 50 格高。
  static func glyphPath(_ text: String, unit: CGFloat) -> Path? {
    guard let base = unitGlyphPath(text) else { return nil }
    return base.applying(CGAffineTransform(scaleX: unit, y: unit))
  }

  // 字形轮廓只在主线程画印时取；NSCache 本身线程安全。
  nonisolated(unsafe) private static let glyphCache = NSCache<NSString, GlyphBox>()
  private final class GlyphBox { let path: Path; init(_ path: Path) { self.path = path } }

  static func unitGlyphPath(_ text: String) -> Path? {
    let key = "\(ReadingFontCatalog.editorialSerifFamily)|\(text)" as NSString
    if let hit = glyphCache.object(forKey: key) { return hit.path }
    let descriptor = NSFontDescriptor(fontAttributes: [.family: ReadingFontCatalog.editorialSerifFamily])
      .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
    let font = NSFont(descriptor: descriptor, size: 100) ?? NSFont.systemFont(ofSize: 100, weight: .semibold)
    let ctFont = font as CTFont
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count),
          let first = glyphs.first,
          let cgPath = CTFontCreatePathForGlyph(ctFont, first, nil) else { return nil }
    // 字形坐标 y 朝上，翻过来；按外框居中、缩到 54 格高。
    var flip = CGAffineTransform(scaleX: 1, y: -1)
    guard let flipped = cgPath.copy(using: &flip) else { return nil }
    let bounds = flipped.boundingBoxOfPath
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let scale = 50 / max(bounds.width, bounds.height)
    let transform = CGAffineTransform(translationX: 50, y: 50)
      .scaledBy(x: scale, y: scale)
      .translatedBy(x: -bounds.midX, y: -bounds.midY)
    let path = Path(flipped).applying(transform)
    glyphCache.setObject(GlyphBox(path), forKey: key)
    return path
  }

  struct Speck { let x: CGFloat; let y: CGFloat; let r: CGFloat; let alpha: Double }

  /// 同一个字每次撒的点都一样（按字取种子），不会一刷新就变样。
  static func specks(seed: UInt32) -> [Speck] {
    var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
    func next() -> CGFloat {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
    var result: [Speck] = []
    // 满版细点：印泥不匀。点要细而密，稀疏的大点看上去像下雪。
    for _ in 0..<420 {
      result.append(Speck(x: 3 + next() * 94, y: 3 + next() * 94, r: 0.22 + next() * 0.45, alpha: 0.25 + Double(next()) * 0.5))
    }
    // 几处印泥没吃透的浅斑。
    for _ in 0..<6 {
      result.append(Speck(x: 8 + next() * 84, y: 8 + next() * 84, r: 2 + next() * 3, alpha: 0.12))
    }
    // 边缘缺口：毛边。
    for _ in 0..<22 {
      let t = next() * 94 + 3
      let side = Int(next() * 4)
      let (x, y): (CGFloat, CGFloat) = switch side {
      case 0: (t, 3 + next() * 2)
      case 1: (97 - next() * 2, t)
      case 2: (t, 97 - next() * 2)
      default: (3 + next() * 2, t)
      }
      result.append(Speck(x: x, y: y, r: 0.6 + next() * 1.2, alpha: 0.9))
    }
    return result
  }
}

/// 每枚印的寓意纹样，画在字和边框之间的留白里（100 格坐标，和样稿同一套数据）。
enum SealMotifs {
  enum Paint { case stroke, faint, fill }

  struct Element {
    let d: String?
    let circle: (x: CGFloat, y: CGFloat, r: CGFloat)?
    let paint: Paint
    var dash: [CGFloat]? = nil

    static func path(_ d: String, _ paint: Paint = .stroke, dash: [CGFloat]? = nil) -> Element {
      Element(d: d, circle: nil, paint: paint, dash: dash)
    }
    static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, filled: Bool = true) -> Element {
      Element(d: nil, circle: (x, y, r), paint: filled ? .fill : .stroke)
    }

    func path(unit: CGFloat) -> Path {
      if let circle {
        return Path(ellipseIn: CGRect(
          x: (circle.x - circle.r) * unit, y: (circle.y - circle.r) * unit,
          width: circle.r * 2 * unit, height: circle.r * 2 * unit
        ))
      }
      return SVGPath.parse(d ?? "").applying(CGAffineTransform(scaleX: unit, y: unit))
    }
  }

  static func elements(for glyph: SealMark.Glyph) -> [Element] {
    switch glyph {
    // 录 · 声纹：右下角一圈圈声波，左上角一小段波形。
    case .record:
      return [
        .path("M80 89 A9 9 0 0 1 89 80 M73 89 A16 16 0 0 1 89 73 M66 89 A23 23 0 0 1 89 66"),
        .path("M11 18 V14 M15 21 V11 M19 19 V13 M23 22 V10 M27 18 V14"),
        .dot(89, 89, 2.2),
      ]
    // 校 · 田字格加一个勾：校稿用的格子，改完打勾。
    case .proof:
      return [
        .path("M50 9 V91 M9 50 H91", .faint, dash: [3, 4]),
        .path("M74 83 L80 89 L91 75"),
        .path("M9 22 H16 M22 9 V16", .faint),
      ]
    // 评 · 云纹：众人议论。
    case .comments:
      return [.path(cloud(70, 18, 1)), .path(cloud(30, 84, -1))]
    // 摘 · 折枝：摘下的一枝。
    case .summary:
      return [
        .path("M9 91 Q17 82 27 76"),
        .path("M17 84 q-9 -1 -9 -9 q8 1 9 9 Z M22 80 q1 -9 9 -9 q-1 8 -9 9 Z", .fill),
        .path("M91 9 Q86 16 79 20"),
        .path("M85 15 q7 1 7 7 q-6 -1 -7 -7 Z", .fill),
      ]
    // 译 · 回纹：一来一回，两种语言之间往返。
    case .translation:
      return [.path(meander(11, flip: false)), .path(meander(89, flip: true))]
    // 图 · 河图点：黑白圆点连成线。
    case .mindMap:
      return [
        .path("M13 13 H23 V23 M77 87 H87 V77 M13 87 L22 80"),
        .dot(13, 13, 3), .dot(23, 13, 3, filled: false), .dot(23, 23, 3),
        .dot(87, 87, 3), .dot(77, 87, 3, filled: false), .dot(87, 77, 3),
        .dot(13, 87, 3, filled: false), .dot(22, 80, 2.2),
      ]
    // 汲 · 水纹：井里打上来的水。
    case .external:
      var front = ""
      var x: CGFloat = 10
      while x < 88 { front += "M\(x) 90 q6.5 -8 13 0 "; x += 13 }
      var back = ""
      var x2: CGFloat = 16.5
      while x2 < 82 { back += "M\(x2) 83 q6.5 -7 13 0 "; x2 += 13 }
      return [.path(front), .path(back, .faint)]
    // 作 · 卷草：自己生长出来的东西。
    case .own:
      return [
        .path("M11 15 c5 -7 12 -7 15 -1 s10 7 15 1 s10 -7 15 -1 s10 7 15 1 s9 -6 14 -1"),
        .path("M11 15 c-2 3 1 6 4 4 M89 15 c2 3 -1 6 -4 4"),
      ]
    }
  }

  private static func cloud(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) -> String {
    "M\(x) \(y) c\(5 * k) -6 \(14 * k) -3 \(13 * k) 4 c\(-1 * k) 5 \(-7 * k) 5 \(-8 * k) 1 c\(-1 * k) -3 \(2 * k) -4 \(3 * k) -2 "
      + "M\(x) \(y) c\(-4 * k) 3 \(-8 * k) 2 \(-10 * k) 6"
  }

  private static func meander(_ y: CGFloat, flip: Bool) -> String {
    let d: CGFloat = flip ? -1 : 1
    var out = ""
    var x: CGFloat = 11
    while x <= 79 {
      out += "M\(x) \(y + 6 * d) V\(y) H\(x + 10) V\(y + 6 * d) H\(x + 4) V\(y + 3 * d) H\(x + 7) "
      x += 14
    }
    return out
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

