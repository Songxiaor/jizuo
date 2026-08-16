//  媒体播放相关：预热判定、可播状态投影、播放器控制器，以及四种播放卡片。
//
//  从 HistoryContentView 拆出。那个文件曾有 5503 行、55 个顶层类型，改一处
//  播放逻辑要在几千行里定位；而这一组内部耦合紧、与列表和详情的其余部分几乎
//  不交叉，是最干净的一刀。

import AppKit
import AVKit
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import LinkDigestAdapters
import LinkDigestCore

/// 列表选中时即可预热：只要 selected 仍是当前抓取且 descriptor 可播，不必等详情 SQLite 载入。
enum RemotePlaybackPreheat {
  static func playableTarget(
    selectedTaskID: TaskID?,
    currentCapture: CurrentCapture?,
    now: Date = Date()
  ) -> (url: URL, companionAudioURL: URL?)? {
    guard let selectedTaskID,
          let capture = currentCapture,
          capture.taskID == selectedTaskID,
          let descriptor = capture.mediaDescriptor,
          case let .playable(url, _, companion) = CurrentCaptureMediaPreview.resolve(descriptor, now: now)
    else { return nil }
    return (url, companion)
  }
}

/// Pure projection from the transient V2 descriptor to user-visible playback state.
/// It never stores or serializes the signed URL; callers may only use the returned
/// URL while the current capture remains in memory.
enum CurrentCaptureMediaPreview {
  static func resolve(
    _ descriptor: MediaDescriptor,
    now: Date = Date()
  ) -> CurrentCaptureMediaPreviewState {
    switch descriptor.kind {
    case .directFile, .hls:
      if let rawExpiry = descriptor.expiresAt {
        guard let expiry = parseExpiry(rawExpiry) else {
          return .degraded(.init(
            kindLabel: kindLabel(descriptor.kind),
            message: "播放地址的有效期无法确认。",
            nextAction: "请回到浏览器重新发送当前视频。"
          ))
        }
        guard expiry > now else { return .expired }
      }
      guard let rawURL = descriptor.ephemeralPlaybackURL,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https" else {
        return .degraded(.init(
          kindLabel: kindLabel(descriptor.kind),
          message: "没有可安全移交给 APP 的播放地址。",
          nextAction: "请回到浏览器重新发送当前视频。"
        ))
      }
      // B 站 DASH 等拆轨源：画面在 ephemeralPlaybackURL，声音在 companionAudioURL。
      let companion: URL? = {
        guard let raw = descriptor.companionAudioURL,
              let audioURL = URL(string: raw),
              audioURL.scheme?.lowercased() == "https" else { return nil }
        return audioURL
      }()
      return .playable(url: url, kind: descriptor.kind, companionAudioURL: companion)
    case .embed:
      return .degraded(.init(
        kindLabel: kindLabel(descriptor.kind),
        message: "这是嵌入式视频。本轮只显示承接容器，不在 APP 内加载网页播放器。",
        nextAction: "请返回原浏览器继续观看。"
      ))
    case .browserSessionOnly, .unsupported:
      return .degraded(failurePresentation(for: descriptor))
    }
  }

  static func isFavoriteEligible(_ descriptor: MediaDescriptor) -> Bool {
    descriptor.kind == .directFile
      && descriptor.ephemeralPlaybackURL.flatMap(URL.init(string:))?.scheme?.lowercased() == "https"
  }

  static func favoriteMedia(_ descriptor: MediaDescriptor) -> CaptureMedia? {
    guard isFavoriteEligible(descriptor), let playbackURL = descriptor.ephemeralPlaybackURL else { return nil }
    return CaptureMedia(
      platform: descriptor.platform,
      videoURL: playbackURL,
      // 画面与声音分成两条流时，音轨要一起传下去，否则存到本机的会是无声视频。
      companionAudioURL: descriptor.companionAudioURL,
      coverURL: descriptor.posterURL,
      durationSeconds: descriptor.durationSeconds,
      author: descriptor.author
    )
  }

  static func favoriteUnavailableMessage(_ descriptor: MediaDescriptor) -> String {
    switch descriptor.kind {
    case .hls: "暂不支持保存 HLS；你仍可在当前会话中速览。"
    case .embed: "嵌入式视频暂不支持收藏到本机。"
    case .browserSessionOnly: "该视频只能在原浏览器会话观看，不能收藏到本机。"
    case .unsupported: "该视频当前不能收藏到本机。"
    case .directFile: "当前直连视频地址不可用，请回到浏览器重新发送。"
    }
  }

  static func kindLabel(_ kind: MediaKind) -> String {
    switch kind {
    case .directFile: "直连视频"
    case .hls: "HLS 串流"
    case .embed: "嵌入式视频"
    case .browserSessionOnly: "浏览器会话视频"
    case .unsupported: "暂不支持的视频"
    }
  }

  /// 每次界面重求值都会解析一遍过期时间，formatter 不能每次新建。
  /// `ISO8601DateFormatter` 在当前 SDK 未标 Sendable，但配置在构造闭包里
  /// 一次完成、之后只读；照 OpenAICompatibleProvider 的先例显式标注。
  private nonisolated(unsafe) static let expiryFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private nonisolated(unsafe) static let expiryWholeSecondsFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static func parseExpiry(_ raw: String) -> Date? {
    if let value = expiryFractionalFormatter.date(from: raw) { return value }
    return expiryWholeSecondsFormatter.date(from: raw)
  }

  private static func failurePresentation(for descriptor: MediaDescriptor) -> RemoteMediaDegradationPresentation {
    let message: String
    let nextAction: String
    // X 的 blob/MSE 不是死路：App 会用嵌入式推文的公开端点换回直链，在后台把
    // 视频下下来。下载完成前先如实说「正在获取」，别让用户以为抓失败了——
    // 这段空窗正是「刚抓进来那几秒显示受限、刷新后才正常」的由来。
    if descriptor.platform == "x", descriptor.failureReason == .blobOrMSE {
      return .init(
        kindLabel: "浏览器会话视频",
        message: "正在为这条帖子获取视频…",
        nextAction: "获取完成后会自动出现在这里；若稍后仍是这条提示，说明这条视频没能取到。"
      )
    }
    switch descriptor.failureReason ?? .unknown {
    case .blobOrMSE:
      message = "这个视频使用 blob/MSE，只能在原浏览器会话观看。"
      nextAction = "请返回原浏览器继续观看。"
    case .drmOrEncrypted:
      message = "这个视频受 DRM 或加密保护，APP 不能接管播放。"
      nextAction = "请返回提供内容的原浏览器页面观看。"
    case .multipleCandidates:
      message = "页面上有多个视频，暂时无法唯一确定你要观看的那一个。"
      nextAction = "请在浏览器中播放目标视频后重新发送。"
    case .videoNotLoaded:
      message = "视频尚未加载，浏览器还没有可移交的媒体源。"
      nextAction = "请先在浏览器中播放视频，再重新发送。"
    case .browserSessionRequired:
      message = "播放依赖原浏览器登录会话，APP 不会读取或转移 Cookie。"
      nextAction = "请返回原浏览器继续观看。"
    case .noTransferableSource:
      message = "浏览器没有找到可安全移交给 APP 的媒体源。"
      nextAction = "请回到浏览器确认视频已播放后重新发送。"
    case .unsupportedMediaType:
      message = "当前媒体格式不受 APP 播放器支持。"
      nextAction = "请返回原浏览器继续观看。"
    case .unknown:
      message = "当前视频无法安全移交给 APP。"
      nextAction = "请返回原浏览器继续观看，或稍后重新发送。"
    }
    return .init(kindLabel: kindLabel(descriptor.kind), message: message, nextAction: nextAction)
  }
}

/// Builds AVURLAssets for remote playback. Douyin (`*.douyinvod.com`) and WeChat
/// (`*.qpic.cn`) video CDNs return HTTP 403 to any request that lacks a browser
/// User-Agent and the matching site Referer — AVFoundation's defaults (its own
/// UA, no Referer) are rejected. We attach the required headers for https sources
/// so the App's player is accepted; local `file://` assets are returned unchanged.
///
/// B 站 DASH 的 `.m4s` 常返回 `application/octet-stream`，需额外注入
/// `AVURLAssetOutOfBandMIMETypeKey`（与 HTTP header key 一样是非公开常量字符串）。
/// 构造失败或 playerItem 失败时由 `RemotePreviewPlayerController` 回退到仅 header 路径。
enum RemotePlaybackAsset {
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  static func referer(forHost host: String?) -> String? {
    guard let host = host?.lowercased() else { return nil }
    if host == "douyin.com" || host.hasSuffix(".douyin.com")
      || host.hasSuffix("douyinvod.com") || host.hasSuffix("douyincdn.com") {
      return "https://www.douyin.com/"
    }
    if host.hasSuffix("qpic.cn") || host.hasSuffix("qq.com") {
      return "https://mp.weixin.qq.com/"
    }
    // 实测 `*.bilivideo.com` 无 Referer 一律 403，带站点根 Referer 即 206。
    if host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
      || host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
      return "https://www.bilibili.com/"
    }
    return nil
  }

  static func isBilibiliPlaybackHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "bilivideo.com" || host.hasSuffix(".bilivideo.com")
      || host == "bilibili.com" || host.hasSuffix(".bilibili.com")
      || host.hasSuffix("hdslb.com")
  }

  /// HTTPS 源需要的浏览器 UA + 平台 Referer。`file://` 返回 nil。
  /// B 站会员/高清 CDN 常需会话 Cookie；只用于内存播放请求，永不落盘。
  static func httpHeaders(for url: URL, cookieHeader: String? = nil) -> [String: String]? {
    guard url.scheme?.lowercased() == "https" else { return nil }
    var headers: [String: String] = ["User-Agent": browserUserAgent]
    if let referer = referer(forHost: url.host) {
      headers["Referer"] = referer
      if isBilibiliPlaybackHost(url.host) {
        headers["Origin"] = "https://www.bilibili.com"
      }
    }
    if let cookieHeader, !cookieHeader.isEmpty, isBilibiliPlaybackHost(url.host) {
      headers["Cookie"] = cookieHeader
    }
    return headers
  }

  /// 带 out-of-band MIME 提示的远程资产。`file://` 本地资产维持原样。
  static func make(
    url: URL,
    role: StreamingComposition.MIMERole = .video,
    cookieHeader: String? = nil
  ) -> AVURLAsset {
    StreamingComposition.urlAsset(
      url: url,
      role: role,
      httpHeaders: httpHeaders(for: url, cookieHeader: cookieHeader),
      applyOutOfBandMIME: true
    )
  }

  /// 回退路径：只注入 HTTP header，不加 MIME 提示（改动前的行为）。
  static func makeLegacy(url: URL, cookieHeader: String? = nil) -> AVURLAsset {
    guard let headers = httpHeaders(for: url, cookieHeader: cookieHeader) else {
      return AVURLAsset(url: url)
    }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
  }
}

@MainActor
final class RemotePreviewPlayerController: ObservableObject {
  /// 双轨远程流式合成最长等待；超时后改走「带 Cookie 下载到临时文件再合成」。
  /// 长片 DASH 不宜拖太久——选流层应已优先 progressive。
  static var dualTrackPrepareTimeoutSeconds: TimeInterval = 12
  /// 手选清晰度时的双轨准备超时。12 秒是按 480p 双轨调的（实测 3.3 秒余量充足）；
  /// 4K 的 moov 大好几倍，实测 12 秒内经常下不完，手选高清就多等一会。
  static var dualTrackPrepareTimeoutSecondsUserChosen: TimeInterval = 40
  /// 当前 prepare 是否来自用户手选清晰度（决定超时档位与诊断文案）。
  private var currentAllowsLongFormDual = false
  /// 下载双轨兜底最长等待；仍失败才进入 failed（禁止黑屏假 ready）。
  /// 长片/高清整轨下载通常会因体积预检直接放弃，无需等满。
  static var dualTrackDownloadTimeoutSeconds: TimeInterval = 45
  /// HEAD 预检超时（不可达地址应快速放弃，避免拖死 UI）。
  static var dualTrackProbeTimeoutSeconds: TimeInterval = 2
  /// 已就绪播放器驻留条数：切换历史再回来可秒开，不必黑屏重连。
  static var parkedPlayerCapacity = 4

  @Published private(set) var player: AVPlayer?
  @Published private(set) var preparePhase: RemotePreviewPreparePhase = .idle
  /// 失败时可见的技术细节：走的哪条路、片长、错误码。
  /// 只放非敏感信息——不含签名 URL、不含 Cookie。
  /// 这一层之前完全没有，失败了只能靠猜，反复改了七轮都没定位到根因。
  @Published private(set) var playbackDiagnostic: String?
  private var currentURL: URL?
  private var currentCompanionAudioURL: URL?
  /// 当前准备使用的会话 Cookie（B 站等）；仅内存，不写历史。
  private var currentCookieHeader: String?
  /// 已经走完「仅 header、无 MIME / 无合成」回退时为 true，避免无限重试。
  private var usedLegacyPath = false
  private var prepareTask: Task<Void, Never>?
  /// 双轨下载兜底产生的临时目录；release / 下次 prepare 时清理。
  private var dualTrackTempDirectory: URL?
  /// 最近若干条已就绪播放器（MRU 在末尾）；切走时 park，切回时 restore。
  private var parkedPlayers: [ParkedRemotePlayback] = []

  var hasPlayer: Bool { player != nil }

  /// 增强路径失败后能否退单 URL。双轨 DASH（画面+声音）的 video-only 回退通常黑屏不可播，禁止假 ready。
  var canFallbackToLegacy: Bool {
    !usedLegacyPath && currentURL != nil && currentCompanionAudioURL == nil
  }

  var isPreparing: Bool { preparePhase == .preparing }

  /// 测试/诊断：当前驻留的 ready 播放器数量。
  var parkedPlayerCount: Int { parkedPlayers.count }

  func prepare(
    url: URL,
    companionAudioURL: URL? = nil,
    cookieHeader: String? = nil,
    durationSeconds: Double? = nil,
    allowLongFormDual: Bool = false
  ) {
    // 长片 + DASH 双轨：禁止进入易卡死的合成路径。
    // progressive mp4 可单轨；纯 m4s 双轨则立刻 failed，催促重新获取整段 MP4。
    // 例外：用户手选了清晰度（allowLongFormDual）——高清只存在于双轨里，
    // 硬闸不让位的话会和粘住的 override 打成刷新死循环。合成路径自身有
    // 12 秒超时和下载兜底，不会无限卡。
    var companion = companionAudioURL
    if companion != nil,
       !allowLongFormDual,
       BilibiliPlaybackRefresher.prefersProgressiveForDuration(durationSeconds) {
      if Self.isLikelyProgressiveMuxedURL(url) {
        companion = nil
      } else {
        if currentURL == url, currentCompanionAudioURL == companionAudioURL,
           case .failed(.longFormDualNeedsRefresh) = preparePhase {
          return
        }
        parkCurrentIfReady()
        cancelPrepare()
        cleanupDualTrackTemp()
        currentURL = url
        currentCompanionAudioURL = companionAudioURL
        currentCookieHeader = cookieHeader
        usedLegacyPath = false
        player = nil
        preparePhase = .failed(.longFormDualNeedsRefresh)
        return
      }
    }

    // 同一目标已在准备中或已就绪：列表预热与详情卡 onAppear 共用，禁止重启 cancel。
    if currentURL == url,
       currentCompanionAudioURL == companion,
       (cookieHeader == nil || cookieHeader == currentCookieHeader) {
      switch preparePhase {
      case .preparing, .ready:
        return
      case .failed:
        break // 允许重试
      case .idle:
        if player != nil { return }
      }
    }

    // 驻留命中：切回历史条目时直接恢复，避免黑屏重连。
    if let parked = takeParked(url: url, companionAudioURL: companion) {
      parkCurrentIfReady()
      cancelPrepare()
      cleanupDualTrackTemp()
      currentURL = parked.url
      currentCompanionAudioURL = parked.companionAudioURL
      currentCookieHeader = parked.cookieHeader ?? cookieHeader
      usedLegacyPath = parked.usedLegacyPath
      player = parked.player
      preparePhase = .ready
      return
    }

    // 切换目标：把当前 ready 播放器 park 起来，而不是毁掉。
    parkCurrentIfReady()
    cancelPrepare()
    cleanupDualTrackTemp()
    player = nil
    currentURL = url
    currentCompanionAudioURL = companion
    currentCookieHeader = cookieHeader
    currentAllowsLongFormDual = allowLongFormDual
    usedLegacyPath = false
    preparePhase = .preparing

    if companion != nil || needsSessionCookieLookup(for: url) {
      // 双轨 / B 站：异步取 Cookie 再合成；禁止无限 preparing。
      prepareTask = Task { @MainActor in
        await self.prepareRemotePlayback(
          url: url,
          companionAudioURL: companion,
          providedCookie: cookieHeader
        )
      }
    } else {
      installEnhancedVideoOnly(url: url, cookieHeader: cookieHeader)
    }
  }

  /// 离开可播上下文时：驻留 ready 播放器，清空当前展示（不销毁缓存）。
  func parkAndIdle() {
    parkCurrentIfReady()
    cancelPrepare()
    cleanupDualTrackTemp()
    player = nil
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  static func isLikelyProgressiveMuxedURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let abs = url.absoluteString.lowercased()
    return path.hasSuffix(".mp4") || path.contains(".mp4") || abs.contains(".mp4")
  }

  private func needsSessionCookieLookup(for url: URL) -> Bool {
    RemotePlaybackAsset.isBilibiliPlaybackHost(url.host)
  }

  /// 取会话 Cookie（若调用方未传）→ 双轨合成或单轨增强。
  private func prepareRemotePlayback(
    url: URL,
    companionAudioURL: URL?,
    providedCookie: String?
  ) async {
    var cookie = providedCookie
    if cookie == nil || cookie?.isEmpty == true,
       RemotePlaybackAsset.isBilibiliPlaybackHost(url.host) {
      cookie = await SiteSessionController.bilibili.cookieHeader()
      if !Task.isCancelled, currentURL == url {
        currentCookieHeader = cookie
      }
    }
    guard !Task.isCancelled, currentURL == url else { return }

    if let companionAudioURL {
      await prepareDualTrack(
        url: url,
        companionAudioURL: companionAudioURL,
        cookieHeader: cookie
      )
    } else {
      installEnhancedVideoOnly(url: url, cookieHeader: cookie)
    }
  }

  /// 1) 远程流式双轨合成（快）→ 2) 带 Cookie 下载到临时文件再合成（稳）→ 3) failed。
  /// 绝不回退到「仅画面 m4s 假 ready」（黑屏 --:--）。
  private func prepareDualTrack(
    url: URL,
    companionAudioURL: URL,
    cookieHeader: String?
  ) async {
    let headers = RemotePlaybackAsset.httpHeaders(for: url, cookieHeader: cookieHeader)
    let box = DualTrackAssetBox()
    let work = Task { @MainActor in
      do {
        box.asset = try await StreamingComposition.makePlayableAsset(
          videoURL: url,
          companionAudioURL: companionAudioURL,
          httpHeaders: headers,
          applyOutOfBandMIME: true
        )
      } catch {
        box.error = error
      }
      box.done = true
    }
    let timeoutSeconds = currentAllowsLongFormDual
      ? Self.dualTrackPrepareTimeoutSecondsUserChosen
      : Self.dualTrackPrepareTimeoutSeconds
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(timeoutSeconds)
    var timedOut = false
    while !box.done {
      if Task.isCancelled {
        work.cancel()
        return
      }
      if Date() >= deadline {
        work.cancel()
        timedOut = true
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    guard !Task.isCancelled, currentURL == url else { return }

    if let asset = box.asset {
      player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      preparePhase = .ready
      return
    }
    if Self.isNetworkUnavailable(box.error) {
      playbackDiagnostic = Self.diagnosticLine(
        stage: "准备阶段",
        isDual: true,
        host: url.host,
        error: box.error
      )
      preparePhase = .failed(.networkUnavailable)
      return
    }

    // 远程流式失败/超时：改用「带 Cookie 下载双轨 → 本地合成」。
    // AVPlayer 对流式 m4s 偶发挂起，但同一 URL 用 URLSession 下载通常可通。
    if let asset = await downloadAndComposeDualTrack(
      videoURL: url,
      audioURL: companionAudioURL,
      headers: headers
    ) {
      guard !Task.isCancelled, currentURL == url else { return }
      player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      preparePhase = .ready
      return
    }
    guard !Task.isCancelled, currentURL == url else { return }
    // 超时和真失败必须分开写：超时时 box.error 是 nil，混在一起就成了
    // 没有任何线索的「连接失败」。附上实际等待秒数和超时档位。
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    let stage = timedOut
      ? "流式合成超时（等了 \(elapsed)s / 上限 \(Int(timeoutSeconds))s）· 下载兜底也未成"
      : "准备阶段（含下载兜底）"
    playbackDiagnostic = Self.diagnosticLine(
      stage: stage,
      isDual: true,
      host: url.host,
      error: box.error
    )
    preparePhase = .failed(.generic)
  }

  /// 用与 AVPlayer 相同的 UA/Referer/Cookie 下载两条轨到临时目录，再内存合成。
  /// 跳过超大体积（4K 整片数 GB）——会拖死 90s 超时且占满磁盘；应依赖可播档位选流。
  private static let dualTrackDownloadMaxBytes: Int64 = 180 * 1_024 * 1_024

  private func downloadAndComposeDualTrack(
    videoURL: URL,
    audioURL: URL,
    headers: [String: String]?
  ) async -> AVAsset? {
    cleanupDualTrackTemp()

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-dual-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    dualTrackTempDirectory = dir

    let videoDest = dir.appendingPathComponent("video.m4s")
    let audioDest = dir.appendingPathComponent("audio.m4s")
    let maxBytes = Self.dualTrackDownloadMaxBytes
    let box = DualTrackAssetBox()
    let work = Task { @MainActor in
      do {
        // HEAD 体积预检放在限时 work 内，避免不可达地址拖死 preparing。
        let probeTimeout = Self.dualTrackProbeTimeoutSeconds
        if let videoLen = await Self.probeContentLength(
          url: videoURL, headers: headers, timeout: probeTimeout
        ), videoLen > maxBytes {
          throw URLError(.dataLengthExceedsMaximum)
        }
        if let audioLen = await Self.probeContentLength(
          url: audioURL, headers: headers, timeout: probeTimeout
        ), audioLen > maxBytes {
          throw URLError(.dataLengthExceedsMaximum)
        }
        // 并行下载两条轨；合成仍在 MainActor。
        async let videoDL: Void = Self.downloadFile(from: videoURL, to: videoDest, headers: headers)
        async let audioDL: Void = Self.downloadFile(from: audioURL, to: audioDest, headers: headers)
        try await videoDL
        try await audioDL
        // 本地 file:// 不再需要 MIME/header。
        box.asset = try await StreamingComposition.makePlayableAsset(
          videoURL: videoDest,
          companionAudioURL: audioDest,
          httpHeaders: nil,
          applyOutOfBandMIME: false
        )
      } catch {
        box.error = error
      }
      box.done = true
    }

    let deadline = Date().addingTimeInterval(Self.dualTrackDownloadTimeoutSeconds)
    while !box.done {
      if Task.isCancelled {
        work.cancel()
        cleanupDualTrackTemp()
        return nil
      }
      if Date() >= deadline {
        work.cancel()
        cleanupDualTrackTemp()
        return nil
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if let asset = box.asset {
      return asset
    }
    cleanupDualTrackTemp()
    return nil
  }

  nonisolated private static func downloadFile(
    from url: URL,
    to destination: URL,
    headers: [String: String]?
  ) async throws {
    var request = URLRequest(url: url)
    request.timeoutInterval = 60
    if let headers {
      for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    let (tempURL, response) = try await URLSession.shared.download(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: tempURL, to: destination)
  }

  nonisolated private static func probeContentLength(
    url: URL,
    headers: [String: String]?,
    timeout: TimeInterval
  ) async -> Int64? {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = max(0.05, timeout)
    if let headers {
      for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode)
    else { return nil }
    let length = http.expectedContentLength
    return length > 0 ? length : nil
  }

  /// playerItem 进入 `.failed` 时调用：退回旧的单 URL + header 路径（仅单轨源）。
  @discardableResult
  func fallbackToLegacyIfNeeded() -> Bool {
    guard canFallbackToLegacy, let url = currentURL else { return false }
    installLegacy(url: url, cookieHeader: currentCookieHeader)
    return true
  }

  /// 播放器运行时失败：区分断网与一般失败，供 UI 展示与重试。
  func markPlaybackFailed(error: Error?) {
    playbackDiagnostic = Self.diagnosticLine(
      stage: "播放中",
      isDual: currentCompanionAudioURL != nil,
      error: error
    )
    if Self.isNetworkUnavailable(error) {
      preparePhase = .failed(.networkUnavailable)
    } else {
      preparePhase = .failed(.generic)
    }
  }

  /// 状态监视的两种收场：条目失败（走回退/失败呈现），或需要重新锚定
  /// （播放器被替换、准备阶段变化、观察流结束）。
  enum PlaybackMonitorOutcome {
    case failed
    case reanchor
  }

  /// 挂起观察一个 currentItem，直到「失败」或「需要重新锚定」。
  ///
  /// 取代原先的定时轮询：那个循环在 ready 之后也每 300ms 醒一次主线程，
  /// 只要播放卡片开着就永不退出。这里改成事件驱动——status 的 KVO 流
  /// （含订阅时的当前值，因此检查与订阅之间没有竞态窗口）加上播放器
  /// 替换、准备阶段变化两路合并；readyToPlay 稳态下零唤醒。
  /// 中途失败仍会因 status → .failed 被叫醒，回退语义与轮询版一致。
  func observePlaybackOutcome(of item: AVPlayerItem) async -> PlaybackMonitorOutcome {
    enum Event {
      case status(AVPlayerItem.Status)
      case reanchor
    }
    let statusEvents = item.publisher(for: \.status).map(Event.status)
    let playerEvents = $player.dropFirst().map { _ in Event.reanchor }
    let phaseEvents = $preparePhase.dropFirst().map { _ in Event.reanchor }
    for await event in Publishers.Merge3(statusEvents, playerEvents, phaseEvents).values {
      switch event {
      case .status(.failed): return .failed
      case .status: continue
      case .reanchor: return .reanchor
      }
    }
    // 流结束（item 释放或任务取消）：交回外层循环重新判断。
    return .reanchor
  }

  /// 拼一行可见的失败细节。只用非敏感字段：轨道形态、主机名、错误域与码。
  /// 明确不含签名 URL 的 query（里面有 deadline / 鉴权串）和 Cookie。
  static func diagnosticLine(
    stage: String,
    isDual: Bool,
    host: String? = nil,
    durationSeconds: Double? = nil,
    error: Error?
  ) -> String {
    var parts: [String] = [stage, isDual ? "双轨合成" : "整段单轨"]
    if let durationSeconds, durationSeconds > 0 {
      parts.append(String(format: "片长 %.0f 分钟", durationSeconds / 60))
    }
    if let host, !host.isEmpty { parts.append(host) }
    if let error = error as NSError? {
      parts.append("\(error.domain) \(error.code)")
    }
    return parts.joined(separator: " · ")
  }

  /// 用户点「重试」：同一 URL 重新 prepare（含网络恢复后 / 重新取 Cookie）。
  func retry() {
    guard let url = currentURL else { return }
    let companion = currentCompanionAudioURL
    let cookie = currentCookieHeader
    // 丢掉该 URL 的驻留，强制重连。
    removeParked(url: url, companionAudioURL: companion)
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    player = nil
    usedLegacyPath = false
    preparePhase = .idle
    prepare(url: url, companionAudioURL: companion, cookieHeader: cookie)
  }

  /// 彻底释放：清空当前 + 全部驻留（App 退出可播区或显式销毁时用）。
  func release() {
    cancelPrepare()
    cleanupDualTrackTemp()
    disposePlayer(player)
    player = nil
    for slot in parkedPlayers {
      disposePlayer(slot.player)
    }
    parkedPlayers.removeAll()
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  /// 单 URL 增强路径（muxed mp4 / HLS 等）。DASH 拆轨不应走这里当「成功」。
  private func installEnhancedVideoOnly(url: URL, cookieHeader: String? = nil) {
    usedLegacyPath = false
    player = AVPlayer(
      playerItem: AVPlayerItem(
        asset: RemotePlaybackAsset.make(url: url, cookieHeader: cookieHeader)
      )
    )
    preparePhase = .ready
  }

  private func installLegacy(url: URL, cookieHeader: String? = nil) {
    usedLegacyPath = true
    player = AVPlayer(
      playerItem: AVPlayerItem(
        asset: RemotePlaybackAsset.makeLegacy(url: url, cookieHeader: cookieHeader)
      )
    )
    preparePhase = .ready
  }

  private func cancelPrepare() {
    prepareTask?.cancel()
    prepareTask = nil
  }

  private func cleanupDualTrackTemp() {
    if let dir = dualTrackTempDirectory {
      try? FileManager.default.removeItem(at: dir)
      dualTrackTempDirectory = nil
    }
  }

  /// 把当前 ready 播放器放进驻留表，供切回秒开。
  private func parkCurrentIfReady() {
    guard preparePhase == .ready,
          let player,
          let url = currentURL else {
      if preparePhase == .preparing {
        cancelPrepare()
        disposePlayer(self.player)
        self.player = nil
      }
      return
    }
    player.pause()
    // 同 key 只保留一份最新。
    removeParked(url: url, companionAudioURL: currentCompanionAudioURL)
    parkedPlayers.append(
      ParkedRemotePlayback(
        url: url,
        companionAudioURL: currentCompanionAudioURL,
        cookieHeader: currentCookieHeader,
        player: player,
        usedLegacyPath: usedLegacyPath
      )
    )
    while parkedPlayers.count > Self.parkedPlayerCapacity {
      let evicted = parkedPlayers.removeFirst()
      disposePlayer(evicted.player)
    }
    self.player = nil
    currentURL = nil
    currentCompanionAudioURL = nil
    currentCookieHeader = nil
    usedLegacyPath = false
    preparePhase = .idle
  }

  private func takeParked(url: URL, companionAudioURL: URL?) -> ParkedRemotePlayback? {
    guard let index = parkedPlayers.firstIndex(where: {
      $0.url == url && $0.companionAudioURL == companionAudioURL
    }) else { return nil }
    return parkedPlayers.remove(at: index)
  }

  private func removeParked(url: URL, companionAudioURL: URL?) {
    parkedPlayers.removeAll {
      guard $0.url == url, $0.companionAudioURL == companionAudioURL else { return false }
      disposePlayer($0.player)
      return true
    }
  }

  private func disposePlayer(_ player: AVPlayer?) {
    player?.pause()
    player?.replaceCurrentItem(with: nil)
  }

  /// 用 NSURLError 域判断断网；不依赖 Network.framework，测试可用 fake NSError。
  static func isNetworkUnavailable(_ error: Error?) -> Bool {
    guard let error else { return false }
    var current: Error? = error
    while let ns = current as NSError? {
      if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
          return true
        default:
          break
        }
      }
      current = ns.userInfo[NSUnderlyingErrorKey] as? Error
    }
    return false
  }
}

/// 双轨合成结果盒：仅在 MainActor 上读写，避免 AVAsset 跨隔离传递。
@MainActor
private final class DualTrackAssetBox {
  var done = false
  var asset: AVAsset?
  var error: Error?
}

/// 已就绪远程播放器驻留项（进程内 LRU，不落盘）。
private struct ParkedRemotePlayback {
  let url: URL
  let companionAudioURL: URL?
  let cookieHeader: String?
  let player: AVPlayer
  let usedLegacyPath: Bool
}

/// 在线转写流式预览的叶子视图：partial 拍点只重绘这一小块
/// （见 HistoryViewModel.setOnlineTranscriptionPreview）。
private struct OnlineTranscriptionPreviewText: View {
  @ObservedObject var live: LiveRunTextModel

  var body: some View {
    ScrollView {
      Text(live.text)
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 120)
    .accessibilityIdentifier("remote-transcribe-preview")
  }
}

/// 拆出本文件后不再是 file-private —— 使用方 HistoryContentView 已不同文件。
struct CurrentCaptureMediaPreviewCard: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  let descriptor: MediaDescriptor
  let taskID: TaskID
  let snapshotID: ContentSnapshotID
  @ObservedObject var model: HistoryViewModel
  let onlineTranscriptionModel: String?
  let tidyModel: String?
  let autoTidyEnabled: Bool
  /// 与列表预热共享；卡片不 release，由 HistoryContentView 在离开可播上下文时释放。
  @ObservedObject var playback: RemotePreviewPlayerController
  /// 会话流失败时：清缓存并重新拉取可播档（避开 DV 等不可播编码）。
  var onRefreshStream: (() -> Void)? = nil
  /// 用户手动选清晰度。默认档以起播速度优先，这里让他知情地换成画质优先。
  var onSelectQuality: ((BilibiliStreamQualityPreference) -> Void)? = nil
  var selectedQuality: BilibiliStreamQualityPreference? = nil
  /// 「长片双轨 → 自动重拉整段」只许触发一次；重拉结果仍是双轨时绝不再来，
  /// 否则和粘住的清晰度 override 形成 1 秒一圈的刷新死循环。
  @State private var hasAutoRequestedProgressive = false
  @ObservedObject private var cinema = VideoCinemaController.shared
  private var isInCinema: Bool { cinema.isPresenting(player: playback.player) }
  @State private var videoDisplaySize: CGSize?
  /// 实际解码出来的画面高度（像素），取自轨道 naturalSize——是真正在播的那一档，
  /// 不是 API 声称的档位。「画质到底多少」只有这个数说了算。
  @State private var videoPixelHeight: Int?
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var playerStatusTask: Task<Void, Never>?

  private var previewState: CurrentCaptureMediaPreviewState {
    CurrentCaptureMediaPreview.resolve(descriptor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.headline)
        Text(CurrentCaptureMediaPreview.kindLabel(descriptor.kind))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
        // 真正在播的那一档。标题写「4K」不代表播的是 4K——
        // 拿不到会员档时会退到公开档，不显示出来根本无从判断。
        // 选的哪条路：整段 mp4（快、上限 720P/1080P）还是 DASH 双轨（能到 4K，慢）。
        // 没有这个标签，「选了高清没变化」分不清是没换路还是换了路仍拿不到高档。
        Text(descriptor.companionAudioURL == nil ? "整段" : "双轨")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
          .accessibilityIdentifier("history-video-preview-track-mode")
        if let videoPixelHeight {
          Text("\(videoPixelHeight)P")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .accessibilityIdentifier("history-video-preview-resolution")
        }
        Spacer(minLength: 0)
      }

      switch previewState {
      case let .playable(url, kind, companionAudioURL):
        playableContent(url: url, kind: kind, companionAudioURL: companionAudioURL)
      case .expired:
        degradationContent(
          message: "播放地址已过期，请回到浏览器重新发送。",
          nextAction: "APP 不会在后台静默重新解析播放地址。",
          identifier: "history-video-preview-expired"
        )
      case let .degraded(presentation):
        degradationContent(
          message: presentation.message,
          nextAction: presentation.nextAction,
          identifier: "history-video-preview-degradation"
        )
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear { synchronizePlayback() }
    .onChange(of: descriptor) { _, _ in
      cancelGeometryAndStatusMonitors()
      synchronizePlayback()
    }
    .onChange(of: model.transcriptionState) { oldState, newState in
      // 本机与在线转写共用同一完成态；用户开启自动校对后，两条路线都应在
      // 当前远程视频上继续执行文本模型处理，而不是只有“已保存到本机”的卡片能触发。
      // 必须确实从本次转写过程进入完成态；打开一条已有转写的历史记录也会恢复为
      // `.completed`，不能因此重复调用模型、重复计费。
      guard autoTidyEnabled, oldState.isActive, newState == .completed,
            model.transcriptionTaskID == taskID,
            model.canTidyTranscript(taskID: taskID) else { return }
      model.startTranscriptTidyAuto(taskID: taskID, model: tidyModel)
    }
    .onDisappear {
      // 不 release 共享 controller：列表预热与快速切回同一抓取需要保留。
      cancelGeometryAndStatusMonitors()
    }
    .accessibilityIdentifier("history-video-preview-card")
  }

  @ViewBuilder
  private func playableContent(url: URL, kind: MediaKind, companionAudioURL: URL?) -> some View {
    // 核心操作放在视频上方。竖屏视频很高；放在播放器下方时，转写与校对会被
    // 推出首屏，功能已经存在却看起来像不存在。
    HStack(spacing: 10) {
      if kind == .directFile {
        Button {
          Task {
            await model.favoriteCurrentCaptureMedia(
              descriptor,
              taskID: taskID,
              snapshotID: snapshotID
            )
          }
        } label: {
          Label("保存到本地", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canFavoriteCurrentCaptureMedia)
        .accessibilityIdentifier("history-video-preview-favorite")
      } else {
        Text("暂不支持保存 HLS")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-video-preview-favorite")
      }
      favoriteStatus
      Spacer(minLength: 0)
      if kind == .directFile {
        remoteTranscriptionControl
      } else {
        Text("当前 Debug 暂不支持 HLS 转写")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("remote-transcribe")
      }
      remoteTranscriptTidyControl
      qualityMenu
      if let player = playback.player, !isInCinema {
        Button {
          cinema.present(
            player: player,
            aspectRatio: videoDisplaySize
              .map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0)
          )
        } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
          .buttonStyle(.link)
          .font(.caption)
          .accessibilityIdentifier("history-video-preview-cinema")
      }
      Button("在浏览器中打开", action: openInBrowser)
        .buttonStyle(.link)
        .controlSize(.small)
    }

    remoteTranscriptionStatus
    remoteTranscriptTidyStatus

    switch playback.preparePhase {
    case let .failed(failure):
      VStack(alignment: .leading, spacing: 8) {
        Label(
          failure.message,
          systemImage: failure == .networkUnavailable ? "wifi.slash" : "exclamationmark.triangle.fill"
        )
          .font(.caption)
          .foregroundStyle(appTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
        // 失败时把走的哪条路、哪个主机、什么错误码摆出来。没有这一行，
        // 排查只能靠猜——之前就是这么反复改了七轮还没定位到根因。
        if let diagnostic = playback.playbackDiagnostic {
          Text(diagnostic)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("history-video-preview-diagnostic")
        }
        HStack(spacing: 10) {
          if let onRefreshStream {
            Button(
              failure == .longFormDualNeedsRefresh ? "重新获取整段 MP4" : "重新获取可播地址"
            ) {
              onRefreshStream()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("history-video-preview-refresh-stream")
          }
          if failure != .longFormDualNeedsRefresh {
            Button("重试") { playback.retry() }
              .controlSize(.small)
              .accessibilityIdentifier("history-video-preview-retry")
          }
          Button("回到原页面观看") { openInBrowser() }
            .controlSize(.small)
        }
      }
      .accessibilityIdentifier(
        failure == .networkUnavailable
          ? "history-video-preview-network-unavailable"
          : "history-video-preview-degradation"
      )
      .onAppear {
        // 长片 dual：有重拉回调则自动拉 progressive，少一次手动点击。
        if failure == .longFormDualNeedsRefresh, let onRefreshStream {
          onRefreshStream()
        }
      }
    case .preparing:
      preparingPlaceholder(url: url, companionAudioURL: companionAudioURL)
    case .idle where playback.player == nil:
      preparingPlaceholder(url: url, companionAudioURL: companionAudioURL)
    case .ready, .idle:
      VideoPlayer(player: playback.player)
        .aspectRatio(
          videoDisplaySize.map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0),
          contentMode: .fit
        )
        .frame(
          maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
          maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
          alignment: .leading
        )
        .background(Color.black)
        .background(VideoScrollWheelAnchor().allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-video-remote-player")
    }

  }

  /// 清晰度切换。默认走「最快起播」，想细看再手动升档——
  /// 升档可能要换成 DASH 双轨，长视频起播会明显变慢，所以菜单里如实写清楚。
  @ViewBuilder
  private var qualityMenu: some View {
    if let onSelectQuality, descriptor.platform == "bilibili" {
      Menu {
        ForEach(BilibiliStreamQualityPreference.allCases, id: \.self) { option in
          Button {
            onSelectQuality(option)
          } label: {
            if option == selectedQuality {
              Label(option.settingsTitle, systemImage: "checkmark")
            } else {
              Text(option.settingsTitle)
            }
          }
        }
      } label: {
        Label("清晰度", systemImage: "slider.horizontal.3")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .font(.caption)
      .accessibilityIdentifier("history-video-preview-quality")
    }
  }

  /// 菜单里禁用的「在线转写」必须自己说明为什么灰。
  /// 「没配模型」和「地址过期」的解法完全不同，只灰不说等于让用户猜。
  private var onlineTranscribeTitle: String {
    let trimmed = onlineTranscriptionModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed?.isEmpty != false {
      return "在线转写（未配置模型，见 设置 → 模型与识别）"
    }
    return "在线转写"
  }

  @ViewBuilder private var remoteTranscriptionControl: some View {
    let state = model.transcriptionState(for: taskID)
    switch state {
    case .preparingMedia, .checkingModel, .preparingModel, .extractingAudio, .transcribing:
      Button("取消转写", role: .cancel, action: model.cancelTranscription)
        .controlSize(.small)
        .accessibilityIdentifier("remote-transcribe-cancel")
    case .failed, .cancelled:
      Menu("重试转写") {
        Button("本机转写") { model.retryRemoteTranscription(descriptor, taskID: taskID) }
        Button(onlineTranscribeTitle) {
          model.requestOnlineTranscription(descriptor, taskID: taskID, model: onlineTranscriptionModel)
        }
        .disabled(!model.canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: onlineTranscriptionModel))
      }
      .controlSize(.small)
      .accessibilityIdentifier("remote-transcribe-retry")
    case .idle, .completed:
      Menu {
        Button("本机转写") { model.requestRemoteTranscription(descriptor, taskID: taskID) }
          .disabled(!model.canTranscribeCurrentCapture(descriptor, taskID: taskID))
        Button(onlineTranscribeTitle) {
          model.requestOnlineTranscription(descriptor, taskID: taskID, model: onlineTranscriptionModel)
        }
        .disabled(!model.canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: onlineTranscriptionModel))
      } label: {
        Label(state == .completed ? "重新转写" : "转写", systemImage: "waveform")
      }
      .controlSize(.small)
      .accessibilityIdentifier("remote-transcribe")
    case .awaitingModelDownload:
      Text("等待模型下载确认")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("remote-transcribe-state")
    }
  }

  @ViewBuilder private var remoteTranscriptTidyControl: some View {
    let blockedReason = model.transcriptTidyUnavailableReason(taskID: taskID)
    Button("模型校对") {
      model.requestTranscriptTidy(taskID: taskID, model: tidyModel)
    }
    .controlSize(.small)
    .disabled(blockedReason != nil)
    .help(
      blockedReason
        ?? "只把转写文字发送给聊天模型，修正标点、分段和明显错别字；不发送视频或音频，原始转写保留。"
    )
    .accessibilityIdentifier("remote-transcript-tidy")
  }

  @ViewBuilder private var remoteTranscriptionStatus: some View {
    let state = model.transcriptionState(for: taskID)
    let preview = model.onlineTranscriptionPreview
    let timings = model.onlineTranscriptionTimings
    let cleanupFailure = model.transcriptionCleanupFailure
    // 空闲且没有补充信息时不要创建一个空 VStack。它虽然高度为 0，仍会让外层
    // VStack 在操作栏、空状态和播放器之间各加一次 spacing，视觉上就变成大空洞。
    if state != .idle || preview?.isEmpty == false || timings != nil || cleanupFailure != nil {
      VStack(alignment: .leading, spacing: 7) {
        switch state {
        case .idle:
          EmptyView()
        case .preparingMedia:
          HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在准备临时媒体…") }
        case .checkingModel:
          HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在检查中文离线模型…") }
        case .awaitingModelDownload:
          Text("等待确认 Apple 中文离线模型下载")
        case .preparingModel:
          HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在准备中文离线模型…") }
        case .extractingAudio:
          HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在提取音频…") }
        case .transcribing:
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(
              model.transcriptionUsesOnlineService
                ? (model.onlineTranscriptionPhase ?? "正在在线转写…")
                : "正在本机转写，音频不会上传…"
            )
          }
        case .completed:
          Label("转写已保存为最新原文", systemImage: "checkmark.circle.fill").foregroundStyle(appTheme.success)
        case .cancelled:
          Text(LocalVideoTranscriptionError.cancelled.userMessage).foregroundStyle(.secondary)
        case let .failed(message):
          Text(message).foregroundStyle(appTheme.danger)
        }
        // 流式通道边转写边出字：先看到文字，等待感就和总耗时脱钩了。
        // 预览文本单独成叶子视图观察 LiveRunTextModel：partial 拍点只重绘
        // 这一小块，视频卡与详情其余部分不受影响。
        if let preview, !preview.isEmpty {
          OnlineTranscriptionPreviewText(live: model.liveOnlineTranscriptionPreview)
        }
        if let timings {
          Text(timings)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("remote-transcribe-timings")
        }
        if let cleanupFailure {
          VStack(alignment: .leading, spacing: 6) {
            Text(cleanupFailure).foregroundStyle(appTheme.danger)
            Button("重试清理", action: model.retryTranscriptionCleanup)
              .controlSize(.small)
              .accessibilityIdentifier("remote-transcribe-cleanup-retry")
          }
          .accessibilityIdentifier("remote-transcribe-cleanup-failure")
        }
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("remote-transcribe-state")
    }
  }

  @ViewBuilder private var remoteTranscriptTidyStatus: some View {
    let state = model.transcriptTidyState(for: taskID)
    let blockedReason = model.transcriptTidyUnavailableReason(taskID: taskID)
    if state != .idle || blockedReason != nil {
      VStack(alignment: .leading, spacing: 6) {
        switch state {
        case .idle:
          if let blockedReason {
            Text(blockedReason)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("remote-transcript-tidy-blocked-reason")
          }
        case .running:
          HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在用模型校对转写稿…") }
        case .completed:
          let tokens = model.transcriptTidyTokenSummary(for: taskID)
          Label(tokens.map { "校对稿已保存 · \($0)" } ?? "校对稿已保存为最新原文", systemImage: "checkmark.circle.fill")
            .foregroundStyle(appTheme.success)
        case .cancelled:
          Text(TranscriptTidyError.cancelled.userMessage).foregroundStyle(.secondary)
        case let .failed(message):
          Text(message).foregroundStyle(appTheme.danger)
        }
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("remote-transcript-tidy-state")
    }
  }

  @ViewBuilder private var favoriteStatus: some View {
    switch model.remoteMediaFavoriteState {
    case .idle:
      EmptyView()
    case .saving:
      HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在保存到本地…") }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    case .saved:
      Label("已保存到本地", systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(appTheme.success)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    case let .failed(message):
      Text(message)
        .font(.caption)
        .foregroundStyle(appTheme.danger)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("history-video-preview-favorite-status")
    }
  }

  private func degradationContent(message: String, nextAction: String, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: descriptor.kind == .embed ? "rectangle.on.rectangle.slash" : "exclamationmark.triangle.fill")
        .font(.callout.weight(.medium))
      Text(nextAction).font(.caption).foregroundStyle(.secondary)
      Button("返回浏览器", action: openInBrowser)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    .accessibilityIdentifier(identifier)
  }

  private func preparingPlaceholder(url: URL, companionAudioURL: URL?) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .fill(Color.black.opacity(0.9))
      VStack(spacing: 10) {
        ProgressView("正在连接视频流…")
          .tint(.white)
          .foregroundStyle(.white)
        Text(companionAudioURL == nil
          ? "正在读取远程视频信息"
          : "正在连接高清双轨（会员清晰度）；必要时会短暂下载后播放")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.75))
          .multilineTextAlignment(.center)
        Button("取消并重试") {
          playback.retry()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("history-video-preview-preparing-retry")
      }
      .padding()
    }
    .frame(height: 220)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("history-video-preview-preparing")
  }

  private func synchronizePlayback() {
    guard case let .playable(url, _, companionAudioURL) = previewState else {
      cancelGeometryAndStatusMonitors()
      return
    }
    // 长片仍带着 DASH 双轨：自动清缓存重拉 progressive，避免卡在「连接高清双轨」。
    //
    // 两个例外，缺一个就会闭环（实测烧到过第 107 次尝试，约 1 秒一圈）：
    // - 用户手选了清晰度：粘住的 override 每次都会重新拿回双轨，这里再触发重拉
    //   就和它互相打架。手选高清本来就该走双轨合成（有 12 秒超时和下载兜底）。
    // - 自动重拉只许一次：重拉的结果如果仍是双轨（缓存、账号档位等原因），
    //   第二次触发就是死循环的开始，改为交给失败卡片让用户手动决定。
    if companionAudioURL != nil,
       selectedQuality == nil,
       !hasAutoRequestedProgressive,
       BilibiliPlaybackRefresher.prefersProgressiveForDuration(descriptor.durationSeconds),
       !RemotePreviewPlayerController.isLikelyProgressiveMuxedURL(url),
       let onRefreshStream {
      hasAutoRequestedProgressive = true
      onRefreshStream()
      return
    }
    preparePlayback(url, companionAudioURL: companionAudioURL)
  }

  private func preparePlayback(_ url: URL, companionAudioURL: URL?) {
    playback.prepare(
      url: url,
      companionAudioURL: companionAudioURL,
      durationSeconds: descriptor.durationSeconds,
      // 手选清晰度 = 用户明确要画质，长片双轨硬闸让位。
      allowLongFormDual: selectedQuality != nil
    )
    loadVideoGeometry(url)
    monitorPlayerStatus()
  }

  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    videoDisplaySize = nil
    videoPixelHeight = nil
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform),
            !Task.isCancelled else { return }
      let displaySize = VideoDisplayGeometry.displaySize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
      guard displaySize.width > 0, displaySize.height > 0 else { return }
      videoDisplaySize = displaySize
      // 竖屏经 transform 后宽高互换，取短边才是「多少 P」。
      videoPixelHeight = Int(min(displaySize.width, displaySize.height).rounded())
    }
  }

  private func monitorPlayerStatus() {
    playerStatusTask?.cancel()
    // 双轨异步 prepare 时 currentItem 可能尚未就绪，短轮询只存在于 prepare
    // 窗口（有 12–45 秒超时兜底）；item 就位后转为事件驱动挂起，ready 稳态零唤醒。
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        if case .failed = playback.preparePhase { return }
        guard let item = playback.player?.currentItem else {
          try? await Task.sleep(for: .milliseconds(50))
          continue
        }
        switch await playback.observePlaybackOutcome(of: item) {
        case .failed:
          // MIME / 合成路径失败时退回旧的单 URL 路径；仍失败再暴露给 UI。
          if playback.fallbackToLegacyIfNeeded() {
            continue
          }
          playback.markPlaybackFailed(error: item.error)
          return
        case .reanchor:
          continue
        }
      }
    }
  }

  private func cancelGeometryAndStatusMonitors() {
    videoGeometryTask?.cancel()
    videoGeometryTask = nil
    playerStatusTask?.cancel()
    playerStatusTask = nil
    videoDisplaySize = nil
  }

  private func openInBrowser() {
    guard let url = URL(string: descriptor.pageURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    NSWorkspace.shared.open(url)
  }
}

/// 历史条目有视频事实，但临时播放地址不在内存时：说明设计边界，并提供恢复动作。
/// 拆出本文件后不再是 file-private —— 使用方 HistoryContentView 已不同文件。
struct HistorySessionMediaUnavailableCard: View {
  @Environment(\.appTheme) private var appTheme
  let sourceURL: String
  let phase: SessionMediaPlaybackController.RefreshPhase
  /// 已发起的刷新次数；大于 1 表示在被反复重启，而不是单次请求慢。
  var refreshAttempts: Int = 1
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(HistorySessionMediaPresentation.title, systemImage: "play.rectangle")
        .font(.headline)
      Text(HistorySessionMediaPresentation.explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      switch phase {
      case .refreshing:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          // 次数大于 1 说明刷新在被反复取消重启，而不是请求慢——两者界面本来一模一样。
          Text(refreshAttempts > 1 ? "正在重新获取播放…（第 \(refreshAttempts) 次尝试）" : "正在重新获取播放…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("history-video-session-refreshing")
      case let .failed(message):
        Text(message)
          .font(.caption)
          .foregroundStyle(appTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history-video-session-refresh-failed")
        HStack(spacing: 10) {
          Button(HistorySessionMediaPresentation.refreshActionTitle, action: onRefresh)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-refresh")
          Button(HistorySessionMediaPresentation.openSourceActionTitle, action: openSource)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-open-source")
        }
      case .idle:
        HStack(spacing: 10) {
          Button(HistorySessionMediaPresentation.refreshActionTitle, action: onRefresh)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-refresh")
          Button(HistorySessionMediaPresentation.openSourceActionTitle, action: openSource)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("history-video-session-open-source")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .accessibilityIdentifier("history-video-session-unavailable")
  }

  private func openSource() {
    guard let url = URL(string: sourceURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    NSWorkspace.shared.open(url)
  }
}

/// Top-of-detail video card for Loop V captures. Plays a local file only —
/// never streams a remote signed URL from History.
/// 空格播放/暂停的窗口级兜底：AVPlayerView 只在自己是 first responder 时
/// 响应空格，而阅读区视图切换（转写流式面板出现/消失等）会把窗口焦点清空，
/// 空格随之失效。此视图不参与命中，只挂本窗口的 keyDown 监视器；焦点在
/// 输入框或其它控件上时空格原样放行，焦点空置时由本卡播放器接管。
/// macOS 会把窗口里第一个文本控件设成 `initialFirstResponder`，搜索框因此一开
/// 窗就叼着光标——空格全打进搜索框，到不了播放器。窗口首次出现时把 first
/// responder 交还给空；只在搜索框确实空着时才动，不打断已经输入的搜索词。
/// 用户点搜索框或按 ⌘F 仍能正常聚焦。
/// 拆出本文件后不再是 file-private —— 使用方 HistoryContentView 已不同文件。
struct ReleaseInitialSearchFocus: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ReleaseView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class ReleaseView: NSView {
    private var released = false

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !released, window != nil else { return }
      released = true
      // 让 SwiftUI 先把它的初始焦点设完，再交还，否则会被下一帧覆盖回去。
      DispatchQueue.main.async { [weak self] in
        guard let window = self?.window,
              let editor = window.firstResponder as? NSText,
              editor.isEditable,
              editor.string.isEmpty
        else { return }
        window.makeFirstResponder(nil)
      }
    }
  }
}

private struct PlayerSpaceKeyToggle: NSViewRepresentable {
  let player: AVPlayer?

  func makeNSView(context: Context) -> CatcherView { CatcherView() }

  func updateNSView(_ nsView: CatcherView, context: Context) {
    nsView.player = player
  }

  final class CatcherView: NSView {
    var player: AVPlayer?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        removeMonitor()
      } else {
        installMonitor()
      }
    }

    private func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }

        // 点击输入框外的区域时结束输入焦点：搜索框（SwiftUI FocusState）
        // 会一直持有 first responder，点静态内容不会自动交出，空格便
        // 永远打进搜索框而到不了播放器。
        if event.type == .leftMouseDown {
          if let editor = window.firstResponder as? NSText, editor.isEditable {
            let point = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
            let hit = window.contentView?.hitTest(point)
            if !(hit is NSText), !(hit is NSTextField), hit !== editor.delegate as? NSView {
              window.makeFirstResponder(nil)
            }
          }
          return event
        }

        guard event.keyCode == 49, // Space
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let player = self.player else { return event }
        // 正在输入的文本框、以及真的把空格当激活键的控件，自己消费空格。
        //
        // 这里不能笼统地放行 NSControl：NSTableView 也是 NSControl 子类，而
        // macOS 上 SwiftUI 的 List 底层正是它。抓取完成后列表刷新、新条目被
        // 选中，first responder 就落在列表上，空格于是被让给滚动视图当翻页
        // 用——屏幕一闪一闪就是不播放，必须先点几下视频把 first responder
        // 抢给 AVPlayerView 才有反应。
        switch window.firstResponder {
        case let text as NSText where text.isEditable:
          // 搜索框空着只是叼着光标（macOS 会把窗口里第一个文本控件设成
          // initialFirstResponder），此时空格的意图是播放而不是打字。真在
          // 输入的搜索词仍旧能正常敲空格。
          if text.string.isEmpty { break }
          return event
        case is NSButton, is NSTextField, is NSComboBox,
             is NSPopUpButton, is NSSegmentedControl: return event
        default: break
        }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        return nil
      }
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// 拆出本文件后不再是 file-private —— 使用方 HistoryContentView 已不同文件。
struct HistoryVideoPlayerCard: View {
  // 错误色走主题，理由同其它视图：写死 .red 在低对比与高对比主题上都不成立。
  @Environment(\.appTheme) private var appTheme
  let fileURL: URL
  let media: MediaAsset?
  let taskID: TaskID
  @ObservedObject var model: HistoryViewModel
  let onlineTranscriptionModel: String?
  let tidyModel: String?
  let autoTidyEnabled: Bool
  @State private var player: AVPlayer?
  @State private var surfaceGeometry: PlaybackSurfaceGeometry = .loading
  /// 既有版式按"有尺寸/没尺寸"分支，这里保持它的语义不变。
  private var videoDisplaySize: CGSize? { surfaceGeometry.displaySize }
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var saveFeedback: String?
  @State private var saveFeedbackTask: Task<Void, Never>?
  @State private var isSaveFailurePresented = false
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 本卡的播放器正被影院 overlay 放大：卡内显示占位，避免双重渲染。
  private var isInCinema: Bool { cinema.isPresenting(player: player) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // All facts and actions precede playback so the player never pushes its
      // ownership/status controls below a tall portrait video.
      HStack(spacing: 12) {
        if let durationSeconds = media?.durationSeconds, durationSeconds > 0 {
          Label(Self.formatDuration(durationSeconds), systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let byteSize = media?.byteSize, byteSize > 0 {
          Label("已保存到本机 · \(Self.formatByteSize(byteSize))", systemImage: "internaldrive.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("history-video-local-size")
        }
        Spacer(minLength: 0)
        if let saveFeedback {
          Label(saveFeedback, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(appTheme.success)
            .accessibilityIdentifier("history-video-save-feedback")
        }
      }

      HStack(spacing: 10) {
        transcriptionControl
        Button("另存一份", systemImage: "square.and.arrow.down", action: saveToLocalFile)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!LocalMediaExport.isSupportedLocalFile(fileURL))
          .accessibilityIdentifier("history-video-save-local")
        if model.isReadOnly {
          Text("只读模式不能保存转写结果；恢复可写存储后可重试。")
            .font(.caption)
            .foregroundStyle(appTheme.warning)
            .accessibilityIdentifier("history-video-transcription-read-only")
        } else {
          transcriptionStatus
          transcriptTidyStatus
        }
        Spacer(minLength: 0)
      }
      .onChange(of: model.transcriptionState) { oldState, newState in
        // 设置勾选即持久授权：自动校对不再逐次弹发送确认。只有本次转写从运行态
        // 进入完成态才触发；历史状态恢复成 `.completed` 时不能重复调用模型。
        guard autoTidyEnabled, oldState.isActive, newState == .completed,
              model.transcriptionTaskID == taskID,
              model.canTidyTranscript(taskID: taskID) else { return }
        model.startTranscriptTidyAuto(taskID: taskID, model: tidyModel)
      }

      playerSurface

      // 「放大」是所有视频卡的固定能力，与 YouTube 卡同位：视频正下方右对齐。
      if let videoDisplaySize, player != nil, !isInCinema {
        HStack {
          Spacer()
          Button {
            guard let player else { return }
            cinema.present(
              player: player,
              aspectRatio: VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize)
            )
          } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("history-video-cinema")
        }
        // 右对齐要对到视频右边缘，不是阅读区右边缘：竖屏视频收窄后，按整行
        // 右对齐会把按钮甩到离视频很远的地方。
        .frame(maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize))
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear {
      if player == nil {
        player = AVPlayer(url: fileURL)
      }
      loadVideoGeometry(fileURL)
    }
    .onChange(of: fileURL) { _, newURL in
      if isInCinema { cinema.dismiss() }
      player?.pause()
      player = AVPlayer(url: newURL)
      loadVideoGeometry(newURL)
    }
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      player?.pause()
      videoGeometryTask?.cancel()
      videoGeometryTask = nil
      saveFeedbackTask?.cancel()
      saveFeedbackTask = nil
    }
    .alert("无法保存视频", isPresented: $isSaveFailurePresented) {
      Button("好", role: .cancel) {}
    } message: {
      Text("原本机视频没有被改动。请检查保存位置的权限或可用空间后重试。")
    }
  }

  @MainActor
  private func saveToLocalFile() {
    guard LocalMediaExport.isSupportedLocalFile(fileURL) else {
      isSaveFailurePresented = true
      return
    }

    let panel = NSSavePanel()
    panel.title = "另存一份视频"
    panel.prompt = "保存"
    panel.nameFieldStringValue = fileURL.lastPathComponent
    panel.allowedContentTypes = [LocalMediaExport.contentType(for: fileURL)]
    panel.allowsOtherFileTypes = false
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false

    guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

    do {
      try LocalMediaExport.copyLocalFile(from: fileURL, to: destinationURL)
      saveFeedbackTask?.cancel()
      saveFeedback = "已保存"
      saveFeedbackTask = Task { @MainActor in
        do {
          try await Task.sleep(nanoseconds: 2_200_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        saveFeedback = nil
        saveFeedbackTask = nil
      }
    } catch {
      isSaveFailurePresented = true
    }
  }

  @ViewBuilder private var playerSurface: some View {
    if let videoDisplaySize {
      if isInCinema {
        // 影院放大期间，卡内显示占位；播放器只存在于 overlay。
        // 空格监视器保留在占位上，影院里空格依旧切换同一个播放器。
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .fill(Color.black.opacity(0.85))
          .aspectRatio(VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize), contentMode: .fit)
          .frame(
            maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
            maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
            alignment: .leading
          )
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .overlay {
            VStack(spacing: 6) {
              Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
              Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
          }
      } else {
        VideoPlayer(player: player)
          .aspectRatio(VideoDisplayGeometry.aspectRatio(displaySize: videoDisplaySize), contentMode: .fit)
          // 竖屏视频（9:16）的黑底必须收到视频自身宽度，否则两侧就是死黑边。
          // 横屏仍被阅读区宽度约束，表现与之前一致。
          .frame(
            maxWidth: VideoDisplayGeometry.inlineMaximumWidth(displaySize: videoDisplaySize),
            maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
            alignment: .leading
          )
          .background(Color.black)
          .background(VideoScrollWheelAnchor().allowsHitTesting(false))
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-video-player")
      }
    } else if surfaceGeometry == .loading {
      ZStack {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .fill(Color.black.opacity(0.9))
        ProgressView("正在读取视频尺寸…")
          .tint(.white)
          .foregroundStyle(.white)
      }
      .frame(height: 220)
      .accessibilityIdentifier("history-video-geometry-placeholder")
    } else {
      // 没有画面可显示时给一条可播放的音频条，而不是继续转圈。转写照常可用，
      // 它本来就只需要声音。
      VStack(alignment: .leading, spacing: 8) {
        Label(
          surfaceGeometry == .audioOnly
            ? "这条媒体只有声音，没有画面"
            : "读不出画面，仅按声音播放",
          systemImage: "waveform"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        VideoPlayer(player: player)
          .frame(height: 64)
          .background(Color.black)
          .background(PlayerSpaceKeyToggle(player: player).allowsHitTesting(false))
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("history-audio-only-player")
    }
  }

  @ViewBuilder private var transcriptionControl: some View {
    let state = model.transcriptionState(for: taskID)
    switch state {
    case .preparingMedia, .checkingModel, .preparingModel, .extractingAudio, .transcribing:
      Button("取消", role: .cancel, action: model.cancelTranscription)
        .controlSize(.small)
        .accessibilityIdentifier("history-video-transcription-cancel")
    case .failed, .cancelled:
      Button("重试", action: model.retryTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo)
        .accessibilityIdentifier("history-video-transcription-retry")
    case .completed:
      Button("重新转写", action: model.requestTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo)
        .accessibilityIdentifier("history-video-transcription-start")
    case .idle, .awaitingModelDownload:
      Button("转写", action: model.requestTranscription)
        .controlSize(.small)
        .disabled(!model.canTranscribeVideo || state == .awaitingModelDownload)
        .accessibilityIdentifier("history-video-transcription-start")
    }
    // 本机模型准确率与标点有限；已存视频随时可改走在线转写换取
    // Whisper 级质量。音频分片在本机提取后上传，发送前必经同意弹窗。
    if !state.isActive {
      Button("在线转写") {
        model.requestOnlineTranscriptionFromLocalMedia(taskID: taskID, model: onlineTranscriptionModel)
      }
      .controlSize(.small)
      .disabled(!model.canTranscribeLocalMediaOnline(taskID: taskID, model: onlineTranscriptionModel))
      .help("把本机提取的音频分片发送到你配置的在线转写服务，获得更准的文字和标点。需在设置中配置在线转写模型。")
      .accessibilityIdentifier("history-video-transcription-online")
      // 转写后整理：只发送文字给聊天模型修标点/分段/错别字，不发送媒体。
      let tidyBlockedReason = model.transcriptTidyUnavailableReason(taskID: taskID)
      Button("模型校对") {
        model.requestTranscriptTidy(taskID: taskID, model: tidyModel)
      }
      .controlSize(.small)
      .disabled(tidyBlockedReason != nil)
      .help(
        tidyBlockedReason
          ?? "把转写文字发送给你配置的聊天模型，修正标点、分段和明显错别字，不改写内容。原始转写稿保留在历史中。"
      )
      .accessibilityIdentifier("history-transcript-tidy")
      // 灰按钮必须自己说明为什么不能点。
      //
      // 这个按钮受五个条件约束，而灰掉的按钮在 SwiftUI 里颜色很淡、和旁边说明文字
      // 混在一起，扫一眼注意不到——实际收到过「一直没看到这个功能」的反馈，功能却
      // 一直都在。把理由摆在旁边，才不会让人以为功能不存在。
      if let tidyBlockedReason {
        Text(tidyBlockedReason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-transcript-tidy-blocked-reason")
      }
    }
  }

  @ViewBuilder private var transcriptTidyStatus: some View {
    switch model.transcriptTidyState(for: taskID) {
    case .idle: EmptyView()
    case .running: ProgressView().controlSize(.small); Text("正在用模型校对转写稿…").font(.caption)
    case .completed:
      let tokens = model.transcriptTidyTokenSummary(for: taskID)
      Label(
        tokens.map { "校对稿已保存 · \($0)" } ?? "校对稿已保存为最新原文",
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption).foregroundStyle(appTheme.success)
    case .cancelled: Text(TranscriptTidyError.cancelled.userMessage).font(.caption).foregroundStyle(.secondary)
    case let .failed(message): Text(message).font(.caption).foregroundStyle(appTheme.danger).lineLimit(3)
    }
  }

  @ViewBuilder private var transcriptionStatus: some View {
    switch model.transcriptionState(for: taskID) {
    case .idle:
      if let status = media?.transcriptionStatus, status != .none {
        Text(Self.transcriptionStatusText(status)).font(.caption).foregroundStyle(.secondary)
      }
    case .preparingMedia: ProgressView().controlSize(.small); Text("正在准备临时媒体…").font(.caption)
    case .checkingModel: ProgressView().controlSize(.small); Text("正在检查中文离线模型…").font(.caption)
    case .awaitingModelDownload: Text("等待确认模型下载").font(.caption).foregroundStyle(.secondary)
    case .preparingModel: ProgressView().controlSize(.small); Text("正在准备中文离线模型…").font(.caption)
    case .extractingAudio: ProgressView().controlSize(.small); Text("正在从本机视频提取音频…").font(.caption)
    case .transcribing: ProgressView().controlSize(.small); Text("正在本机转写，音频不会上传…").font(.caption)
    case .completed: Label("转写已保存为最新原文", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(appTheme.success)
    case .cancelled: Text(LocalVideoTranscriptionError.cancelled.userMessage).font(.caption).foregroundStyle(.secondary)
    case let .failed(message): Text(message).font(.caption).foregroundStyle(appTheme.danger).lineLimit(3)
    }
  }

  /// 必须落到一个确定状态。旧实现在拿不到视频轨时直接 return，界面就永远停在
  /// "正在读取视频尺寸…"——纯音轨的媒体每次都会这样。
  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    surfaceGeometry = .loading
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      var videoTrack: (naturalSize: CGSize, preferredTransform: CGAffineTransform)?
      if let track = try? await asset.loadTracks(withMediaType: .video).first,
         let naturalSize = try? await track.load(.naturalSize),
         let preferredTransform = try? await track.load(.preferredTransform) {
        videoTrack = (naturalSize, preferredTransform)
      }
      let hasAudioTrack = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
      guard !Task.isCancelled else { return }
      surfaceGeometry = VideoDisplayGeometry.surfaceGeometry(
        videoTrack: videoTrack,
        hasAudioTrack: hasAudioTrack
      )
    }
  }

  private static func formatByteSize(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  private static func transcriptionStatusText(_ status: TranscriptionStatus) -> String {
    switch status {
    case .none: "尚未转写"
    case .pending: "等待本机转写"
    case .running: "本机转写中"
    case .completed: "已完成本机转写"
    case .failed: "上次转写未完成"
    }
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%d:%02d", minutes, remainder)
  }
}

/// Streaming video card for persisted browser captures whose V2 media
/// descriptor was mapped to `CaptureMedia`. Plays the ephemeral HTTPS URL
/// without requiring a local download. If the URL has expired or playback
/// fails, the user can reopen the source page in the browser.
private struct HistoryStreamingMediaCard: View {
  @Environment(\.appTheme) private var appTheme
  let media: CaptureMedia
  let sourceURL: String
  @ObservedObject var model: HistoryViewModel
  @StateObject private var playback = RemotePreviewPlayerController()
  @State private var videoDisplaySize: CGSize?
  @State private var videoGeometryTask: Task<Void, Never>?
  @State private var playerStatusTask: Task<Void, Never>?
  @State private var playbackFailed = false
  @ObservedObject private var cinema = VideoCinemaController.shared

  /// 本卡的播放器正被影院 overlay 放大：卡内显示占位，避免双重渲染。
  private var isInCinema: Bool { cinema.isPresenting(player: playback.player) }

  private var streamingAspectRatio: CGFloat {
    videoDisplaySize.map { VideoDisplayGeometry.aspectRatio(displaySize: $0) } ?? (16.0 / 9.0)
  }

  private var videoURL: URL? {
    guard let url = URL(string: media.videoURL),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  private var companionAudioURL: URL? {
    guard let raw = media.companionAudioURL,
          let url = URL(string: raw),
          url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Label("视频速览", systemImage: "play.rectangle.fill")
          .font(.headline)
        Text("联网播放")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1), in: Capsule())
        Spacer(minLength: 0)
        if let author = media.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
          Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if let durationSeconds = media.durationSeconds, durationSeconds > 0 {
          Text(Self.formatDuration(durationSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      if playbackFailed {
        VStack(alignment: .leading, spacing: 8) {
          Label("远程播放失败。地址可能已失效。", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(appTheme.warning)
          Text("临时播放地址不会写入历史；APP 重启或地址过期后，请回到浏览器重新同步。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("在浏览器中打开", action: openInBrowser)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-video-streaming-failed")
      } else if videoURL != nil {
        if isInCinema {
          // 影院放大期间，卡内显示占位；播放器只存在于 overlay。
          RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .fill(Color.black.opacity(0.85))
            .aspectRatio(streamingAspectRatio, contentMode: .fit)
            .frame(
              maxWidth: VideoDisplayGeometry.inlineMaximumHeight * streamingAspectRatio,
              maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
              alignment: .leading
            )
            .background(PlayerSpaceKeyToggle(player: playback.player).allowsHitTesting(false))
            .overlay {
              VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").font(.title2).foregroundStyle(.white.opacity(0.7))
                Text("正在放大播放…").font(.caption).foregroundStyle(.white.opacity(0.7))
              }
            }
        } else {
          VideoPlayer(player: playback.player)
            .aspectRatio(streamingAspectRatio, contentMode: .fit)
            .frame(
              maxWidth: VideoDisplayGeometry.inlineMaximumHeight * streamingAspectRatio,
              maxHeight: VideoDisplayGeometry.inlineMaximumHeight,
              alignment: .leading
            )
            .background(Color.black)
            .background(VideoScrollWheelAnchor().allowsHitTesting(false))
            .background(PlayerSpaceKeyToggle(player: playback.player).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history-video-streaming-player")
        }
      }

      HStack(spacing: 10) {
        Button("在浏览器中打开", action: openInBrowser)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("history-video-streaming-open-browser")
        Spacer(minLength: 0)
        // 「放大」是所有视频卡的固定能力。
        if let player = playback.player, !playbackFailed, !isInCinema {
          Button {
            cinema.present(player: player, aspectRatio: streamingAspectRatio)
          } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("history-video-streaming-cinema")
        }
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .onAppear {
      if let url = videoURL {
        playback.prepare(url: url, companionAudioURL: companionAudioURL)
        loadVideoGeometry(url)
        monitorPlayerStatus()
      }
    }
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      // 这里原本是 release()，而 release() 会 parkedPlayers.removeAll()。
      // 切换历史条目必然触发 onDisappear，于是那份 4 条驻留缓存每次都被清空，
      // 切回来还得重连——驻留等于没做。park 只收起当前这个，保留其余。
      playback.parkAndIdle()
      videoGeometryTask?.cancel()
      videoGeometryTask = nil
      playerStatusTask?.cancel()
      playerStatusTask = nil
    }
  }

  private func openInBrowser() {
    if let url = URL(string: sourceURL) {
      NSWorkspace.shared.open(url)
    }
  }

  private func loadVideoGeometry(_ url: URL) {
    videoGeometryTask?.cancel()
    videoDisplaySize = nil
    videoGeometryTask = Task { @MainActor in
      let asset = RemotePlaybackAsset.make(url: url)
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform),
            !Task.isCancelled else { return }
      let displaySize = VideoDisplayGeometry.displaySize(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      )
      guard displaySize.width > 0, displaySize.height > 0 else { return }
      videoDisplaySize = displaySize
    }
  }

  private func monitorPlayerStatus() {
    playerStatusTask?.cancel()
    // 与详情卡同一策略：prepare 窗口短轮询，item 就位后事件驱动挂起，
    // 不再在 ready 稳态下每 300ms 唤醒主线程。
    playerStatusTask = Task { @MainActor in
      while !Task.isCancelled {
        guard let item = playback.player?.currentItem else {
          try? await Task.sleep(nanoseconds: 50_000_000)
          continue
        }
        switch await playback.observePlaybackOutcome(of: item) {
        case .failed:
          if playback.fallbackToLegacyIfNeeded() {
            continue
          }
          playbackFailed = true
          return
        case .reanchor:
          continue
        }
      }
    }
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%d:%02d", minutes, remainder)
  }
}

/// Geometry-only helper so rotation and fit behavior can be tested without AVKit.
/// 播放面的几何状态。**只有音轨的媒体读不出画面尺寸**——B 站的 DASH 把画面和
/// 声音拆成两条流，抓取拿到的是声音那条——所以"没有画面"必须与"仍在读取"分开，

/// Copies an already-cached local video to a user-selected destination. This
/// component deliberately has no remote URL or downloader responsibility.
enum LocalMediaExport {
  private static let allowedExtensions: Set<String> = ["mp4", "mov"]

  static func contentType(for url: URL) -> UTType {
    url.pathExtension.lowercased() == "mov" ? .quickTimeMovie : .mpeg4Movie
  }

  static func isSupportedLocalFile(
    _ url: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    guard url.isFileURL,
          allowedExtensions.contains(url.pathExtension.lowercased()) else { return false }
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  static func copyLocalFile(
    from sourceURL: URL,
    to destinationURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let sourceExtension = sourceURL.pathExtension.lowercased()
    guard isSupportedLocalFile(sourceURL, fileManager: fileManager),
          destinationURL.isFileURL,
          destinationURL.pathExtension.lowercased() == sourceExtension else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }

    let source = sourceURL.standardizedFileURL
    let destination = destinationURL.standardizedFileURL
    guard source != destination else { return }

    let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
      ".linkdigest-export-\(UUID().uuidString).\(destination.pathExtension)"
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try fileManager.copyItem(at: source, to: temporaryURL)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destination)
    }
  }
}
