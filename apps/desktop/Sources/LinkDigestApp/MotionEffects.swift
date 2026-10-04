import SwiftUI

/// 换内容时的轻淡入：`key` 一变，新内容从半透明 0.15 秒淡到不透明。
///
/// 不用 `.id(key)` + `.transition`——那会把整棵详情树拆掉重建，长文每切一次要多跑一整轮
/// 排版（见 `articleDetail` 的注释）。
///
/// **只动透明度，不动位置。** 第一版还让内容从下方 4pt 升上来，Instruments 实测每切一条
/// 主线程连续忙 0.7–0.8 秒、掉帧 5–13 帧一次：详情里套着滚动视图，位置每帧一变，SwiftUI
/// 就把整篇长文重新量一遍，窗口还跟着重算标题栏拖拽区域（2026-10-04）。透明度只改绘制，
/// 不触发排版。系统「减少动态效果」打开时整段不做。
struct SwapReveal<Key: Hashable>: ViewModifier {
  let key: Key
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isSettled = true

  func body(content: Content) -> some View {
    content
      // 限定范围：动画只作用在这一层透明度上，同一时间详情里别的变化（图片到了、高度变了）
      // 照常一步到位，不会被顺带做成逐帧动画。
      .animation(isSettled ? .easeOut(duration: 0.15) : nil) {
        $0.opacity(isSettled ? 1 : 0.35)
      }
      .onChange(of: key) {
        guard !reduceMotion else { return }
        isSettled = false
        // 同一拍里先置 false 再置 true 会被合并成「没变」，动画就丢了：下一拍再放。
        DispatchQueue.main.async { isSettled = true }
      }
  }
}

extension View {
  func swapReveal<Key: Hashable>(on key: Key) -> some View {
    modifier(SwapReveal(key: key))
  }
}

