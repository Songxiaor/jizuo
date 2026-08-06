import AppKit
import SwiftUI

/// 全局「已复制」反馈：任何复制动作后弹一枚小药丸，让用户确定内容已上剪贴板。
/// 同时提供统一的复制入口，避免各处重复 clearContents/setString 样板。
@MainActor final class CopyFeedbackController: ObservableObject {
  static let shared = CopyFeedbackController()
  @Published private(set) var isVisible = false
  private var hideTask: Task<Void, Never>?

  /// 写剪贴板并弹提示；所有 App 内复制动作统一走这里。
  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    flash()
  }

  /// 只改状态，不在这里包 `withAnimation`。
  ///
  /// 动画交给 `CopyFeedbackOverlay` 上的 `.animation(_:value:)` 统一驱动：
  /// 一来这里包一层、视图上再挂一个是双重动画；二来「减弱动态效果」是
  /// 环境值，只有视图取得到，controller 里包死的曲线绕不过那个设置。
  func flash() {
    hideTask?.cancel()
    isVisible = true
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard !Task.isCancelled else { return }
      self?.isVisible = false
    }
  }
}

/// 挂在窗口内容之上的药丸浮层；不拦截任何点击。
struct CopyFeedbackOverlay: View {
  @ObservedObject private var controller = CopyFeedbackController.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack {
      Spacer()
      if controller.isVisible {
        Label("已复制", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .padding(.vertical, 8).padding(.horizontal, 16)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
          // 开了「减弱动态效果」就只淡入淡出：缩放和位移正是那个设置要避免的
          // 两类运动，而「已复制」这个提示本身靠出现/消失就说清楚了。
          .transition(
            reduceMotion
              ? .opacity
              : .opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .bottom))
          )
          .padding(.bottom, 28)
          .accessibilityIdentifier("copy-feedback-pill")
      }
    }
    .allowsHitTesting(false)
    .animation(historyUIAnimation(reduceMotion: reduceMotion), value: controller.isVisible)
  }
}
