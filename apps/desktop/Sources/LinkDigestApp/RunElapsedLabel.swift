import SwiftUI

/// 运行已耗时读数。
///
/// `RunState.thinking` 已经把「连上了、正在想」和「还没连上」分开了，但屏幕上
/// 它仍然只是一个转圈加一句静态文字——而一个不动的转圈，和卡死是同一幅画面。
/// 推理模型出第一个字之前可以静默几十秒，那段时间里用户唯一能做的判断是
/// 「它还在跑吗」。跳动的秒数就是这个问题的答案，也是这里存在的全部理由。
///
/// 实现走 `TimelineView` 而不是 Timer：拍点只重画这一个 `Text`，不触碰
/// `AppViewModel` 的任何被观察属性。若经由观察通知驱动，整棵历史窗口会按拍
/// 重求值——`setRunState` 绕开 `withMutation` 的那条快路径防的就是这件事，
/// 这里不能从另一头把它破坏掉。
///
/// 字体由调用处用 `themedFont(_:weight:monospacedDigit:)` 给，跟随所在那行的
/// 层级；务必带 `monospacedDigit: true`，否则位数变化时读数会左右抖，跳动本身
/// 反倒成了干扰。
///
/// 调用方只在运行处于活动态时插入它，视图消失时 timeline 随之停掉，不留常驻计时器。
struct RunElapsedLabel: View {
  let startedAt: Date

  var body: some View {
    TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
      Text(Self.format(context.date.timeIntervalSince(startedAt)))
        .foregroundStyle(.tertiary)
        // 对读屏隐藏：每 0.1 秒播报一次数字会把状态文字完全淹没。运行状态由
        // 相邻的 `runStatusText` 播报，这里只是给视觉用户的活体证据。
        .accessibilityHidden(true)
    }
  }

  /// 一分钟以内保留 0.1 秒精度：绝大多数运行落在这一档，而跳动的小数位正是
  /// 「还活着」的证据，整秒跳一次会留下长达一秒的静止窗口。
  ///
  /// 超过一分钟改用 `m:ss`：那时候「慢」已成既定事实，秒以下的精度不再有意义，
  /// 而三位数的秒（`83.1s`）反倒要人心算。
  static func format(_ interval: TimeInterval) -> String {
    let seconds = max(0, interval)
    if seconds < 60 {
      return String(format: "%.1fs", seconds)
    }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
