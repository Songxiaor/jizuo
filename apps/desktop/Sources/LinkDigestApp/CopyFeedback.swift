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

  func flash() {
    hideTask?.cancel()
    withAnimation(.spring(duration: 0.25)) { isVisible = true }
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.3)) { self?.isVisible = false }
    }
  }
}

/// 挂在窗口内容之上的药丸浮层；不拦截任何点击。
struct CopyFeedbackOverlay: View {
  @ObservedObject private var controller = CopyFeedbackController.shared

  var body: some View {
    VStack {
      Spacer()
      if controller.isVisible {
        Label("已复制", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .padding(.vertical, 8).padding(.horizontal, 16)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
          .transition(.opacity.combined(with: .scale(scale: 0.9)).combined(with: .move(edge: .bottom)))
          .padding(.bottom, 28)
          .accessibilityIdentifier("copy-feedback-pill")
      }
    }
    .allowsHitTesting(false)
    .animation(.spring(duration: 0.25), value: controller.isVisible)
  }
}
