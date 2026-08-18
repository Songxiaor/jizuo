import Foundation
import Combine

/// 流式正文的专属发布通道。
///
/// 总结/翻译/转写生成期间，正文每约 250ms 增长一次。这些拍点如果写进
/// `AppViewModel` / `HistoryViewModel` 那样的巨型 ObservableObject，
/// `objectWillChange` 会把观察它们的整棵历史窗口（侧栏、元数据、评论区）
/// 全部重新求值——正文越长 diff 越贵，生成期间滚动因此持续卡顿。
///
/// 拍点改写到这个小对象上：只有真正显示这些字的叶子视图订阅它，重绘
/// 范围收窄到那一小块；其余视图只在状态真正切换（开始/思考/停止/终态、
/// 空↔非空边界）时收到通知。
@MainActor
final class LiveRunTextModel: ObservableObject {
  @Published private(set) var text: String = ""

  func setText(_ value: String) {
    if text != value {
      text = value
    }
  }
}
