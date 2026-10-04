import AVKit
import SwiftUI

/// 视频滚出视野时的小窗。
///
/// 长视频（几小时的课程录像）一边播一边读转写稿时，原来视频卡占着半屏、往下读就看不见画面；
/// 回头看一眼要滚回顶上（2026-10-04 Syc 确认的方案）。现在视频卡滚出可视区、而且正在播，
/// 就在正文区右下角接着放；滚回来小窗收起，画面回到原位。播放器是同一个，进度不断。
@MainActor
final class MiniVideoPlayerController: ObservableObject {
  static let shared = MiniVideoPlayerController()

  struct Content: Equatable {
    let player: AVPlayer
    let aspectRatio: CGFloat
    let ownerID: String
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.player === rhs.player && lhs.aspectRatio == rhs.aspectRatio && lhs.ownerID == rhs.ownerID
    }
  }

  @Published private(set) var content: Content?
  /// 用户点了小窗的「收起」：这一段视频这次不再自动弹小窗，滚回去再滚走也不弹。
  private var dismissedOwners: Set<String> = []

  func show(player: AVPlayer, aspectRatio: CGFloat, ownerID: String) {
    guard !dismissedOwners.contains(ownerID) else { return }
    let next = Content(player: player, aspectRatio: aspectRatio, ownerID: ownerID)
    if content != next { content = next }
  }

  func hide(ownerID: String) {
    guard content?.ownerID == ownerID else { return }
    content = nil
  }

  /// 卡片离开（换了一条、关了详情）：小窗跟着走，下次打开重新允许弹。
  func release(ownerID: String) {
    dismissedOwners.remove(ownerID)
    hide(ownerID: ownerID)
  }

  func dismissByUser() {
    guard let content else { return }
    dismissedOwners.insert(content.ownerID)
    self.content = nil
  }

  func isShowing(player: AVPlayer?) -> Bool {
    guard let player, let content else { return false }
    return content.player === player
  }
}

/// 正文区右下角的小窗。宽 220pt，竖屏视频按比例收窄、最高 260pt。
struct MiniVideoPlayerOverlay: View {
  @ObservedObject private var controller = MiniVideoPlayerController.shared
  @ObservedObject private var cinema = VideoCinemaController.shared
  @State private var isHovering = false

  var body: some View {
    if let content = controller.content, !cinema.isPresenting(player: content.player) {
      let width: CGFloat = content.aspectRatio >= 1 ? 220 : max(120, 260 * content.aspectRatio)
      VideoPlayer(player: content.player)
        .linkDigestVideoSurface(player: content.player)
        .aspectRatio(content.aspectRatio, contentMode: .fit)
        .frame(width: width)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if isHovering {
            HStack(spacing: 4) {
              miniButton("放大", systemImage: "arrow.up.left.and.arrow.down.right") {
                cinema.present(player: content.player, aspectRatio: content.aspectRatio)
              }
              miniButton("收起小窗", systemImage: "xmark") { controller.dismissByUser() }
            }
            .padding(6)
          }
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onHover { isHovering = $0 }
        .videoCinemaDoubleClick {
          cinema.present(player: content.player, aspectRatio: content.aspectRatio)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
        .accessibilityIdentifier("history-mini-video-player")
    }
  }

  private func miniButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(.black.opacity(0.55), in: Circle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
