import SwiftUI

/// 设置详情页统一的内容边距标准。**所有设置页共用这一处**，别再各写各的数值——
/// 原来六个页面各自只设了 `.contentMargins(.bottom, 24)`，上边距和左右全靠 Form 默认，
/// 于是「上下左右比例」在各页之间没有一致基准。
///
/// 水平方向刻意不覆盖：grouped Form 自己负责卡片的水平内缩，那部分本就跨页一致；
/// 再叠一层 `.contentMargins(.horizontal:)` 只会和它相加，把卡片越推越窄。所以标准
/// 只钉上下——顶部留一档呼吸，底部留够，让首张/末张卡都不贴着窗口边。
enum SettingsMetrics {
  static let contentTop: CGFloat = 18
  static let contentBottom: CGFloat = 28
}

extension View {
  /// 设置详情页统一套这一个，取代散落各页的 `.contentMargins(.bottom, 24)`。
  func settingsDetailContentMargins() -> some View {
    self
      .contentMargins(.top, SettingsMetrics.contentTop, for: .scrollContent)
      .contentMargins(.bottom, SettingsMetrics.contentBottom, for: .scrollContent)
  }

  /// Form Section header 的统一字号：`.footnote.weight(.medium)` + `.secondary`。
  ///
  /// 原来各页的 header 各写各的（有的用系统默认、有的自己套了别的字号），
  /// 于是「已保存的视频」这类组标题在不同页看着不一样重。收进这一个修改点，
  /// 别再一页一改。
  func settingsSectionHeaderStyle() -> some View {
    self
      .font(.footnote.weight(.medium))
      .foregroundStyle(.secondary)
  }
}

/// 设置分类图标 chip 的底色。只从 `HistoryThemeTokens` 已有语义色里分配，不新造色值。
///
/// 高对比主题靠形状而不是色相编码（`encodesStatusByShape`），chip 改用 `primaryText`
/// 单色，形状还在，颜色不再承担分类信息。
enum SettingsCategoryChip {
  static func fill(for category: String, theme: HistoryThemeTokens) -> Color {
    if theme.encodesStatusByShape {
      return theme.primaryText
    }
    switch category {
    case "service": return theme.accent
    case "generation": return theme.info
    case "appearance": return theme.warning
    case "labs": return theme.danger
    case "browserSupport": return theme.info
    case "siteLogin": return theme.success
    case "mediaStorage": return theme.warning
    case "knowledgeVault": return theme.accent
    default: return theme.accent
    }
  }
}

/// 设置侧栏 / 页头用的彩色小方块：白图标压在语义色底上。
///
/// 装饰性图形，VoiceOver 不读——旁边的分类名才是标签。
struct SettingsSidebarChip: View {
  let symbol: String
  let fill: Color
  var edge: CGFloat = DesignTokens.Layout.settingsSidebarChip

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: symbolPointSize, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: edge, height: edge)
      .background(
        fill,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
      )
      .accessibilityHidden(true)
  }

  private var symbolPointSize: CGFloat {
    edge >= DesignTokens.IconSize.empty
      ? DesignTokens.IconSize.section
      : DesignTokens.IconSize.control
  }
}

/// 详情页页头：分类 chip + 页名 + 一句话说明。替代「直接怼卡片」的开场。
///
/// 直接坐进 `SettingsPlainPage` 内容 `VStack` 的第一个元素，贴画布渲染，
/// 不进任何卡片容器——原来专门给它准备的 `SettingsPageHeaderSection`（借用
/// Form Section 的 header 槽位实现同样效果）已经随 Form 一起撤掉。
struct SettingsPageHeader: View {
  let title: String
  let symbol: String
  let caption: String
  let fill: Color
  var captionIdentifier: String? = nil

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Space.md) {
      SettingsSidebarChip(
        symbol: symbol,
        fill: fill,
        edge: DesignTokens.IconSize.empty
      )
      VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
        Text(title)
          .font(.title2.weight(.semibold))
          .foregroundStyle(.primary)
        captionText
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, DesignTokens.Space.xs)
  }

  @ViewBuilder private var captionText: some View {
    let text = Text(caption)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    if let captionIdentifier {
      text.accessibilityIdentifier(captionIdentifier)
    } else {
      text
    }
  }
}

/// 六个「非站点登录」设置详情页共用的页面容器：`ScrollView` 手排 + 自绘卡序列，
/// 不再进 Form。
///
/// macOS 给 grouped Form 的 Section 画的默认容器卡完全不受 `listRowBackground`
/// 控制（见 `SettingsThemedCardChrome` 的注释），压在暖纸画布上永远是一块和画布
/// 色不搭的系统冷灰。`SiteLoginSettingsView` 最早验证过这条路线的替代方案：整页
/// 换成 `ScrollView` 手排，容器卡完全靠自绘。这里把该实现收成共享容器，别再每页
/// 各写一份「ScrollView + 内边距 + 画布底色」。
struct SettingsPlainPage<Content: View>: View {
  @Environment(\.appTheme) private var theme
  @ViewBuilder var content: () -> Content

  /// 与 `SiteLoginSettingsView` 相同的水平内距：项目里没有专门收拢这个数值的
  /// 令牌，两处都是手排页，保持同一个数字才不会切换 tab 时观感跳一下。
  private static var horizontalInset: CGFloat { 20 }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Self.horizontalInset)
    }
    .background(theme.isNative ? Color.clear : theme.canvas)
    .settingsDetailContentMargins()
  }
}

/// 原 Section 的 header / footer 文本，改放进卡片外的一小段 `VStack`。
///
/// grouped Form 里，Section 的 header 贴在容器卡上方、footer 贴在容器卡下方，
/// 两者都贴画布渲染、不进容器卡本身。离开 Form 之后没有这两个槽位了，这里用
/// 一个小 `VStack` 还原同样的相对位置：组标题在上、卡片内容在中、说明在下。
/// 没有组标题的 Section（这是多数情况）传 `nil` 即可，这时它只是一层透明的
/// `VStack` 包装，不额外产生视觉差异。
struct SettingsCardGroup<Content: View>: View {
  var header: String? = nil
  var footer: String? = nil
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      if let header {
        Text(header).settingsSectionHeaderStyle()
      }
      content()
      if let footer {
        Text(footer)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// 一行设置：左侧标签（+ 可选 caption），右侧控件，垂直居中。
///
/// 简单开关、下拉、按钮走这一行，再由 `SettingsRowGroup` 收进一张卡。
/// 复杂块（模型网格、主题色卡、单选组）继续用 `SettingsCard`。
struct SettingsRow<Control: View>: View {
  let title: String
  var caption: String? = nil
  var details: String? = nil
  @ViewBuilder var control: () -> Control

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDetailsPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .center, spacing: DesignTokens.Space.lg) {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            Text(title)
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
            if details != nil {
              settingsInfoButton(
                title: title,
                isExpanded: $isDetailsPresented,
                reduceMotion: reduceMotion
              )
            }
            Spacer(minLength: 0)
          }
          if let caption {
            Text(caption)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        control()
      }
      if isDetailsPresented, let details {
        Text(details)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, DesignTokens.Space.sm)
    .padding(.horizontal, DesignTokens.Space.lg)
    .accessibilityElement(children: .contain)
  }
}

/// 若干 `SettingsRow` 收成一张圆角卡，行间 hairline。
///
/// 不再进 Form：调用方需要组标题时用
/// `SettingsCardGroup(header: "组标题") { SettingsRowGroup { … } }`，
/// 把组标题放在卡片外左上；没有组标题就直接用，不用另包一层。
///
/// 卡面自带 `SettingsThemedCardChrome`（底色 + hairline 描边 + 浅色主题下的
/// 轻投影），和 `SiteLoginSettingsView` 里 `sitesCard` 的做法同一个模式。
struct SettingsRowGroup<Content: View>: View {
  @ViewBuilder var content: () -> Content

  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content()) { subviews in
        let lastID = subviews.last?.id
        ForEach(subviews) { subview in
          subview
          if subview.id != lastID {
            Rectangle()
              .fill(theme.hairline)
              .frame(height: 1)
              .padding(.leading, DesignTokens.Space.lg)
          }
        }
      }
    }
    .padding(.vertical, DesignTokens.Space.sm)
    .modifier(SettingsThemedCardChrome())
  }
}

/// 卡片的统一外观：令牌底色、hairline 描边、浅色主题下的轻投影。
///
/// `SiteLoginSettingsView` 最早验证过这条路线：整页从 `Form` 换成
/// `ScrollView` 手排后，容器卡完全靠这一层自绘，不再依赖 Section 的系统
/// 外壳——那层外壳不受 `listRowBackground` 控制，叠上自绘卡面就是「卡中卡」，
/// 发灰发闷、和画布色不搭。
///
/// 现在设置窗口的六个详情页全部走这条路线，统一直通、不再对原生主题特殊
/// 处理——原生主题下 `theme.card` 取的是 `.textBackgroundColor`，本身就是
/// 一个能打的卡面底色，不需要再交给谁兜底。
struct SettingsThemedCardChrome: ViewModifier {
  @Environment(\.appTheme) private var theme
  @AppStorage(AppearanceTheme.storageKey) private var appearanceRaw = AppearanceTheme.glass.rawValue

  func body(content: Content) -> some View {
    let appearance = AppearanceTheme(rawValue: appearanceRaw) ?? .glass
    let lifts = (appearance == .paper || appearance == .sepia)
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
    return content
      .background(theme.card, in: shape)
      .overlay(shape.strokeBorder(theme.hairline))
      .designShadow(lifts ? .raised : .flat, tint: theme.canvas)
  }
}

/// 设置页的统一卡片：标题 + 控件 + 一句关键说明 + 收起的详细说明。
///
/// 排版约定：复杂设置项仍是 **一个设置项 = 一张卡片**；相关的简单项改由
/// `SettingsRow` + `SettingsRowGroup` 合并进一张卡。
///
/// 改这套之前，设置项普遍写成「Section header + 控件行 + 卡片外的长 footer」。
/// 两个后果：
/// - 说明离它控制的控件隔着一整块间距，读的时候对不上号；
/// - footer 一律展开，四五行密字把页面撑满，实际控件密度极低。
///
/// 抽成共享组件而不是各页各写一份：三处复制迟早各自漂移，而这种漂移不报错、
/// 不崩溃，只会让设置页慢慢变回原样。
/// 说明放在控件前还是控件后。
///
/// 开关和输入框放后面合适：先看到控件，再看补充。但**控件自带逐项解释**时
/// （比如一组单选，每项下面都有一句话），说明再放后面就读成倒的——先读到
/// 某一项的解释，才读到整张卡在讲什么。这种卡必须前置。
enum SettingsSummaryPlacement {
  case belowControl
  case aboveControl
}

/// 控件占多宽。
///
/// 设置窗口的详情区有 600pt 以上，而 Form 行会撑满整行——于是 Toggle 的开关、
/// LabeledContent 的值、Picker 的下拉全被推到最右端，和自己的标题隔着大半个
/// 窗口，看的时候要来回扫。macOS 系统设置是靠窄内容列避开这件事的，这里同理：
/// 默认给控件设一个上限宽度，文字仍然可以用满整行保持可读性。
///
/// `full` 留给本来就需要整行的控件：多行文本框、成组的列表行、自带布局的链条。
///
/// 定义在顶层而不是嵌进 `SettingsCard`：嵌套类型带着外层的泛型参数，
/// 调用方写类型标注时会被迫绑定一个具体的 Control 类型。
enum SettingsControlWidth {
  case compact
  case full

  var maximum: CGFloat? {
    switch self {
    case .compact: 440
    // 显式撑满而不是 nil：grouped Form 时代行会自动撑满整行，nil 无所谓；
    // 迁到 ScrollView 手排后没有这层兜底，nil 会让 LabeledContent 抱团
    // 靠左挤在标签旁边，标签和值的两端对齐就没了。
    case .full: .infinity
    }
  }
}

struct SettingsCard<Control: View, TitleAccessory: View>: View {
  let title: String
  /// 一句话说清这个设置是干什么的。必填——写不出一句话，多半是这张卡装了不止一件事。
  let summary: String
  /// 次要信息：边界条件、隐私说明、失败后果。默认收起，但一条都不该删。
  var details: String?
  var summaryPlacement: SettingsSummaryPlacement = .belowControl
  var controlWidth: SettingsControlWidth = .compact
  @ViewBuilder var control: () -> Control
  /// 这张卡的**主控件**，画在标题行右端。
  ///
  /// 见下面 `SettingsControlWidth` 的注释：`compact` 只能让控件不撑满整行，
  /// 挡不住 `Toggle`／`LabeledContent` 把自己的控件推到那个上限的右边缘——
  /// 于是开关停在卡片中间，既不贴标签也不与任何东西对齐。
  ///
  /// 一张卡只有一个主控件时，正确答案不是把它往标签边上挪，而是让它和卡片标题
  /// 同一行、右对齐：整页所有卡片的控件因此排成一列，「输出语言」那行一直是这么画的。
  /// 顺带消掉一处重复——卡片标题「翻译模型」和控件标签「翻译使用不同模型」讲的是同一件事。
  @ViewBuilder var titleAccessory: () -> TitleAccessory
  @State private var isDetailsPresented = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @ViewBuilder private var summaryText: some View {
    Text(summary)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(title).font(.headline)
        Spacer(minLength: 12)
        titleAccessory()
        if details != nil {
          settingsInfoButton(
            title: title,
            isExpanded: $isDetailsPresented,
            reduceMotion: reduceMotion
          )
        }
      }
      if summaryPlacement == .aboveControl { summaryText }
      control()
        .frame(maxWidth: controlWidth.maximum, alignment: .leading)
      if summaryPlacement == .belowControl { summaryText }
      if isDetailsPresented, let details {
        Text(details)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, DesignTokens.Space.md)
    .padding(.horizontal, DesignTokens.Space.lg)
    .modifier(SettingsThemedCardChrome())
  }
}

/// 没有标题行控件的卡片照旧只写 `control`。
///
/// 用受约束的扩展而不是给 `titleAccessory` 一个默认值：默认值推不出泛型参数，
/// 每个老调用点都得手写 `SettingsCard<_, EmptyView>` 才能编译。
extension SettingsCard where TitleAccessory == EmptyView {
  init(
    title: String,
    summary: String,
    details: String? = nil,
    summaryPlacement: SettingsSummaryPlacement = .belowControl,
    controlWidth: SettingsControlWidth = .compact,
    @ViewBuilder control: @escaping () -> Control
  ) {
    self.init(
      title: title,
      summary: summary,
      details: details,
      summaryPlacement: summaryPlacement,
      controlWidth: controlWidth,
      control: control,
      titleAccessory: { EmptyView() })
  }
}

@MainActor @ViewBuilder
private func settingsInfoButton(
  title: String,
  isExpanded: Binding<Bool>,
  reduceMotion: Bool
) -> some View {
  Button {
    withAnimation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)
    ) {
      isExpanded.wrappedValue.toggle()
    }
  } label: {
    Image(systemName: "info.circle")
  }
  .buttonStyle(.borderless)
  .foregroundStyle(.secondary)
  .help("查看\(title)说明")
  .accessibilityLabel("\(title)详细说明")
}

/// 一组单选，每项自带解释。
///
/// 用它替代 `Picker(.inline)`：在 grouped Form 里那个样式会把单选钮甩到行的最右端，
/// 离它自己的标题隔着整行宽度，而且只有选中项的解释会显示——**要比较两个选项就得
/// 先各点一次**。这里把选择钮贴回文字左边，并让每一项都带着自己的解释。
struct SettingsChoiceList<Value: Hashable>: View {
  struct Choice: Identifiable {
    let value: Value
    let title: String
    let explanation: String
    var id: Value { value }
  }

  let choices: [Choice]
  @Binding var selection: Value
  var identifierPrefix: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(choices) { choice in
        let isSelected = choice.value == selection
        Button {
          selection = choice.value
        } label: {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
              .font(.body)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text(choice.title)
                .font(.body)
                .foregroundStyle(.primary)
              Text(choice.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix)-\(String(describing: choice.value))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      }
    }
  }
}

/// 指向另一页设置的可执行提示。
///
/// 「B 站高清依赖站点登录」这类跨页依赖原来只是 footer 里的一句话，读者知道了
/// 也还得自己去找那一页。说明依赖就要给出去处。
struct SettingsCrossReference: View {
  let message: String
  var systemImage: String = "arrow.turn.down.right"

  var body: some View {
    Label(message, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
