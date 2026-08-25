import CoreGraphics
import Foundation

/// 否则界面会永远停在转圈上。读取失败同理：给它一个明确出口，而不是无限等待。
enum PlaybackSurfaceGeometry: Equatable {
  case loading
  case video(CGSize)
  case audioOnly
  case unavailable

  var displaySize: CGSize? {
    if case let .video(size) = self { return size }
    return nil
  }
}

struct VideoDisplayGeometry {
  /// 内联播放器高度上限。竖屏视频按它算出的宽度约 292，横屏先撞阅读区宽度。
  static let inlineMaximumHeight: CGFloat = 520

  /// 由已读到的轨道信息判定播放面状态。抽成纯函数是为了能脱离 AVFoundation 资源
  /// 直接测：有画面就给尺寸，没画面但有声音就是纯音频，两者都没有才是读不出。
  static func surfaceGeometry(
    videoTrack: (naturalSize: CGSize, preferredTransform: CGAffineTransform)?,
    hasAudioTrack: Bool
  ) -> PlaybackSurfaceGeometry {
    if let videoTrack {
      let size = displaySize(
        naturalSize: videoTrack.naturalSize,
        preferredTransform: videoTrack.preferredTransform
      )
      if size.width > 0, size.height > 0 { return .video(size) }
    }
    return hasAudioTrack ? .audioOnly : .unavailable
  }

  /// 内联播放器的宽度上限：让黑底收到视频自身宽度，竖屏才不会挂着两条死黑边。
  /// 单给 `maxHeight` 不够——弹性 frame 会把整块可用宽度占满，比例只作用在内部。
  static func inlineMaximumWidth(displaySize: CGSize?) -> CGFloat {
    let ratio = displaySize.map(aspectRatio(displaySize:)) ?? (16.0 / 9.0)
    return inlineMaximumHeight * ratio
  }

  static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    return CGSize(width: abs(transformed.width), height: abs(transformed.height))
  }

  static func aspectRatio(displaySize: CGSize) -> CGFloat {
    guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
    return displaySize.width / displaySize.height
  }

  static func fittedSize(displaySize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard displaySize.width > 0, displaySize.height > 0, maxWidth > 0, maxHeight > 0 else { return .zero }
    let scale = min(maxWidth / displaySize.width, maxHeight / displaySize.height)
    return CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
  }
}
