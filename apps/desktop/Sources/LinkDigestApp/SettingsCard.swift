import SwiftUI

/// 设置页的统一卡片：标题 + 控件 + 一句关键说明 + 收起的详细说明。
///
/// 排版约定：**一个设置项 = 一个 Section = 一张卡片**。
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
    case .full: nil
    }
  }
}

struct SettingsCard<Control: View>: View {
  let title: String
  /// 一句话说清这个设置是干什么的。必填——写不出一句话，多半是这张卡装了不止一件事。
  let summary: String
  /// 次要信息：边界条件、隐私说明、失败后果。默认收起，但一条都不该删。
  var details: String?
  var summaryPlacement: SettingsSummaryPlacement = .belowControl
  var controlWidth: SettingsControlWidth = .compact
  @ViewBuilder var control: () -> Control

  @ViewBuilder private var summaryText: some View {
    Text(summary)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      if summaryPlacement == .aboveControl { summaryText }
      control()
        .frame(maxWidth: controlWidth.maximum, alignment: .leading)
      if summaryPlacement == .belowControl { summaryText }
      if let details {
        DisclosureGroup("了解更多") {
          Text(details)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.caption)
      }
    }
    .padding(.vertical, 4)
  }
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
