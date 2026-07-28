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
struct SettingsCard<Control: View>: View {
  let title: String
  /// 一句话说清这个设置是干什么的。必填——写不出一句话，多半是这张卡装了不止一件事。
  let summary: String
  /// 次要信息：边界条件、隐私说明、失败后果。默认收起，但一条都不该删。
  var details: String?
  @ViewBuilder var control: () -> Control

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      control()
      Text(summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
