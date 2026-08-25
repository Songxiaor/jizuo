import Foundation
import LinkDigestCore

struct RemoteMediaDegradationPresentation: Equatable {
  let kindLabel: String
  let message: String
  let nextAction: String
}

enum CurrentCaptureMediaPreviewState: Equatable {
  case playable(url: URL, kind: MediaKind, companionAudioURL: URL?)
  case expired
  case degraded(RemoteMediaDegradationPresentation)
}

/// 远程预览准备阶段：双轨 `loadTracks` 可能要数秒拉 moov，期间必须有文案。
enum RemotePreviewPreparePhase: Equatable {
  case idle
  case preparing
  case ready
  case failed(RemotePreviewPlaybackFailure)
}

/// 可区分的远程播放失败：断网 vs 地址/播放器问题。
enum RemotePreviewPlaybackFailure: Equatable {
  case networkUnavailable
  case generic
  /// 长片仍带着 DASH 双轨地址：应改拉 progressive mp4，不要卡在合成。
  case longFormDualNeedsRefresh

  var message: String {
    switch self {
    case .networkUnavailable:
      return "网络似乎不可用，暂时无法读取视频流。"
    case .generic:
      return "高清流连接失败（可能是杜比视界/编码不兼容或地址失效）。请点「重新获取可播地址」拉取 AVPlayer 能播的最高清档。"
    case .longFormDualNeedsRefresh:
      return "长视频不适合双轨合成。请点「重新获取可播地址」拉取整段可播 MP4。"
    }
  }
}

/// 历史条目在「没有可播放 descriptor」时的展示决策。
/// descriptor / 签名 URL 只在当前抓取内存中有效，从不写入历史——这是设计，不是故障。
enum HistorySessionMediaPresentation {
  /// 是否应把这条历史当作「曾有会话媒体」。
  ///
  /// 优先用抓取事实，而不是平台白名单：
  /// - `hadMediaDescriptor`：来自 `capture_deliveries.capture_contract_version == 2`。
  ///   扩展侧只有存在 `MediaDescriptor` 时才发 V2（见 `captureEnvelopeForPage`），
  ///   因此覆盖 x / bilibili / xiaohongshu / github / generic 等所有会带媒体的抓取，
  ///   而不会把纯文字的 X 帖误判成视频。
  /// - `wechat` 在扩展 `attachDetectedMedia` 里被显式丢弃 media，不会进 V2，不受影响。
  /// - 抖音图文帖不带 mediaDescriptor，也不是 V2 视频路径；若正文仍命中图文启发式则排除。
  /// - `legacyPlatformHint` 兜底极老的 V1 视频（无 V2 合同行）：抖音、B 站。
  ///   这两类抓取当时不写 `media_assets`，重启后会话流缓存清空就会整块消失。
  static func expectsSessionMedia(
    hadMediaDescriptor: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    if isDouyinImagePost { return false }
    if hadMediaDescriptor { return true }
    // Legacy V1 video-only path (optional CaptureMedia, not MediaDescriptor).
    return legacyPlatformHint == "douyin" || legacyPlatformHint == "bilibili"
  }

  /// 是否应显示「有视频但此处不可播」卡片，而不是整块消失。
  static func shouldShowSessionOnlyUnavailable(
    hadMediaDescriptor: Bool,
    hasLocalMediaFile: Bool,
    hasLocalMediaRow: Bool,
    hasLocalMediaResolutionFailure: Bool,
    isCurrentCaptureWithDescriptor: Bool,
    isYouTube: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    guard !hasLocalMediaFile,
          !hasLocalMediaRow,
          !hasLocalMediaResolutionFailure,
          !isCurrentCaptureWithDescriptor,
          !isYouTube else { return false }
    return expectsSessionMedia(
      hadMediaDescriptor: hadMediaDescriptor,
      isDouyinImagePost: isDouyinImagePost,
      legacyPlatformHint: legacyPlatformHint
    )
  }

  static let title = "此记录包含视频"
  static let explanation =
    "临时播放地址只在抓取当次有效，从不写入历史。这是设计行为，不是故障；换到其它条目后，这里不能继续在线播放。"
  static let openSourceActionTitle = "回到原页面观看"
  static let refreshActionTitle = "重新获取播放"
}
