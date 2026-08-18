import AVFoundation
import Foundation
import XCTest
import LinkDigestCore
@testable import LinkDigestApp

/// 播放层：prepare 的单轨/双轨去重、预热取消、断网/过期可区分。
@MainActor
final class RemotePlaybackPrepareTests: XCTestCase {
  func testResolvePassesCompanionAudioURLForDualTrackDescriptor() throws {
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://www.bilibili.com/video/BV1test",
      canonicalURL: "https://www.bilibili.com/video/BV1test",
      platform: "bilibili",
      ephemeralPlaybackURL: "https://upos.bilivideo.com/video.m4s",
      companionAudioURL: "https://upos.bilivideo.com/audio.m4s",
      mimeType: "application/octet-stream",
      transcriptionCapability: .supported
    )
    let state = CurrentCaptureMediaPreview.resolve(descriptor, now: Date(timeIntervalSince1970: 1_784_500_000))
    guard case let .playable(url, kind, companion) = state else {
      return XCTFail("expected playable state")
    }
    XCTAssertEqual(url.absoluteString, "https://upos.bilivideo.com/video.m4s")
    XCTAssertEqual(kind, .directFile)
    XCTAssertEqual(companion?.absoluteString, "https://upos.bilivideo.com/audio.m4s")
  }

  func testResolveOmitsCompanionWhenAbsent() throws {
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/watch",
      canonicalURL: "https://example.test/watch",
      platform: "fixture",
      ephemeralPlaybackURL: "https://media.example.test/video.mp4",
      companionAudioURL: nil,
      mimeType: "video/mp4",
      transcriptionCapability: .supported
    )
    let state = CurrentCaptureMediaPreview.resolve(descriptor, now: Date(timeIntervalSince1970: 1_784_500_000))
    guard case let .playable(_, _, companion) = state else {
      return XCTFail("expected playable state")
    }
    XCTAssertNil(companion)
  }

  func testPrepareSingleTrackCreatesPlayer() {
    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/a.mp4")!
    controller.prepare(url: url)
    XCTAssertTrue(controller.hasPlayer)
    XCTAssertEqual(controller.preparePhase, .ready)
    XCTAssertTrue(controller.canFallbackToLegacy, "增强路径失败前应仍可回退")
    controller.release()
    XCTAssertFalse(controller.hasPlayer)
    XCTAssertEqual(controller.preparePhase, .idle)
    XCTAssertFalse(controller.canFallbackToLegacy)
  }

  func testPrepareDedupesSameURLAndCompanion() {
    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/a.mp4")!
    // 单轨同步路径：同一 URL 再次 prepare 应保持现有 player。
    controller.prepare(url: url)
    let firstPlayer = controller.player
    controller.prepare(url: url)
    XCTAssertTrue(controller.player === firstPlayer)
    XCTAssertTrue(controller.hasPlayer)
  }

  func testParkedPlayerRestoredWhenSwitchingBack() {
    let previous = RemotePreviewPlayerController.parkedPlayerCapacity
    RemotePreviewPlayerController.parkedPlayerCapacity = 4
    defer { RemotePreviewPlayerController.parkedPlayerCapacity = previous }

    let controller = RemotePreviewPlayerController()
    let a = URL(string: "https://media.example.test/park-a.mp4")!
    let b = URL(string: "https://media.example.test/park-b.mp4")!

    controller.prepare(url: a)
    let playerA = controller.player
    XCTAssertNotNil(playerA)
    XCTAssertEqual(controller.preparePhase, .ready)

    // 切到 B：A 应驻留，不能被毁掉后重连。
    controller.prepare(url: b)
    XCTAssertEqual(controller.preparePhase, .ready)
    XCTAssertEqual(controller.parkedPlayerCount, 1)
    XCTAssertFalse(controller.player === playerA)

    // 切回 A：应从驻留恢复同一 AVPlayer，秒开。
    controller.prepare(url: a)
    XCTAssertTrue(controller.player === playerA)
    XCTAssertEqual(controller.preparePhase, .ready)
    controller.release()
    XCTAssertEqual(controller.parkedPlayerCount, 0)
  }

  func testLongFormDualTrackFailsFastWithoutPreparingHang() {
    let controller = RemotePreviewPlayerController()
    let video = URL(string: "https://upos.bilivideo.com/long-video.m4s")!
    let audio = URL(string: "https://upos.bilivideo.com/long-audio.m4s")!
    controller.prepare(
      url: video,
      companionAudioURL: audio,
      durationSeconds: 63 * 60
    )
    // 不得进入 preparing 双轨合成；立刻引导重新获取 progressive。
    XCTAssertEqual(controller.preparePhase, .failed(.longFormDualNeedsRefresh))
    XCTAssertFalse(controller.hasPlayer)
    controller.release()
  }

  func testLongFormProgressiveMP4StripsCompanionAndPlaysSingleTrack() {
    let controller = RemotePreviewPlayerController()
    // 非 bilivideo host：避免异步 Cookie 查找，同步验证 companion 被剥离。
    let video = URL(string: "https://media.example.test/long-form.mp4")!
    let audio = URL(string: "https://media.example.test/ignored-audio.m4s")!
    controller.prepare(
      url: video,
      companionAudioURL: audio,
      durationSeconds: 63 * 60
    )
    // progressive mp4 丢弃 companion，走单轨同步 ready。
    XCTAssertEqual(controller.preparePhase, .ready)
    XCTAssertTrue(controller.hasPlayer)
    controller.release()
  }

  func testQualitySwitchKeepsCurrentPlayerWhileNewDualTrackPrepares() {
    let controller = RemotePreviewPlayerController()
    let current = URL(string: "https://media.example.test/current.mp4")!
    let nextVideo = URL(string: "https://upos.bilivideo.com/next-video.m4s")!
    let nextAudio = URL(string: "https://upos.bilivideo.com/next-audio.m4s")!

    controller.prepare(url: current)
    let visible = controller.player
    XCTAssertNotNil(visible)
    XCTAssertEqual(controller.preparePhase, .ready)

    controller.prepare(
      url: nextVideo,
      companionAudioURL: nextAudio,
      durationSeconds: 11 * 60,
      allowLongFormDual: true
    )
    XCTAssertTrue(controller.player === visible, "换高清时旧画面必须继续留着")
    XCTAssertEqual(controller.preparePhase, .preparing)
    controller.release()
  }

  func testQualitySwitchResumeSeeksPastTheStartAndIgnoresTheOpening() {
    XCTAssertFalse(MediaPlaybackRestart.shouldSeek(.zero))
    XCTAssertFalse(MediaPlaybackRestart.shouldSeek(.invalid))
    XCTAssertFalse(MediaPlaybackRestart.shouldSeek(CMTime(seconds: 0.05, preferredTimescale: 600)))
    XCTAssertTrue(MediaPlaybackRestart.shouldSeek(CMTime(seconds: 12, preferredTimescale: 1)))
    XCTAssertNil(MediaPlaybackRestart.switchResume(from: nil))
  }

  func testPrepareWithCompanionUsesAsyncPathAndTracksCompanionForDedup() {
    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/video.m4s")!
    let audio1 = URL(string: "https://media.example.test/audio-1.m4s")!
    let audio2 = URL(string: "https://media.example.test/audio-2.m4s")!

    // 双轨路径异步启动：DASH 不得退到假单轨 ready（会黑屏）。
    controller.prepare(url: url, companionAudioURL: audio1)
    XCTAssertEqual(controller.preparePhase, .preparing)
    XCTAssertFalse(controller.canFallbackToLegacy)

    // 伴随音轨变化必须参与去重键，否则换源时不会刷新。
    controller.prepare(url: url, companionAudioURL: audio2)
    XCTAssertEqual(controller.preparePhase, .preparing)
    XCTAssertFalse(controller.canFallbackToLegacy)
    controller.release()
    XCTAssertFalse(controller.hasPlayer)
    XCTAssertEqual(controller.preparePhase, .idle)
  }

  func testDualTrackPrepareTimeoutFailsInsteadOfBlackVideoOnlyReady() async {
    let previousStream = RemotePreviewPlayerController.dualTrackPrepareTimeoutSeconds
    let previousDownload = RemotePreviewPlayerController.dualTrackDownloadTimeoutSeconds
    let previousProbe = RemotePreviewPlayerController.dualTrackProbeTimeoutSeconds
    RemotePreviewPlayerController.dualTrackPrepareTimeoutSeconds = 0.05
    RemotePreviewPlayerController.dualTrackDownloadTimeoutSeconds = 0.05
    RemotePreviewPlayerController.dualTrackProbeTimeoutSeconds = 0.05
    defer {
      RemotePreviewPlayerController.dualTrackPrepareTimeoutSeconds = previousStream
      RemotePreviewPlayerController.dualTrackDownloadTimeoutSeconds = previousDownload
      RemotePreviewPlayerController.dualTrackProbeTimeoutSeconds = previousProbe
    }

    let controller = RemotePreviewPlayerController()
    // 不可达的双轨 URL：流式 + 下载兜底都会失败；超时后必须离开 preparing，且不能假 ready。
    let url = URL(string: "https://198.51.100.1/unreachable-video.m4s")!
    let audio = URL(string: "https://198.51.100.1/unreachable-audio.m4s")!
    controller.prepare(url: url, companionAudioURL: audio)
    XCTAssertEqual(controller.preparePhase, .preparing)

    let deadline = Date().addingTimeInterval(6)
    while controller.preparePhase == .preparing, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertNotEqual(
      controller.preparePhase,
      .preparing,
      "timeout must end preparing so UI is not stuck forever"
    )
    // DASH 双轨超时：失败+重试，禁止黑屏假 ready。
    if case .ready = controller.preparePhase {
      XCTFail("dual-track timeout must not report ready with unplayable video-only m4s")
    }
    XCTAssertFalse(controller.hasPlayer)
    controller.release()
  }

  func testBilibiliHeadersIncludeCookieAndOriginWhenProvided() {
    let headers = RemotePlaybackAsset.httpHeaders(
      for: URL(string: "https://xy123.bilivideo.com/upgcxcode/video.m4s")!,
      cookieHeader: "SESSDATA=test-session; DedeUserID=1"
    )
    XCTAssertEqual(headers?["Referer"], "https://www.bilibili.com/")
    XCTAssertEqual(headers?["Origin"], "https://www.bilibili.com")
    XCTAssertEqual(headers?["Cookie"], "SESSDATA=test-session; DedeUserID=1")
    XCTAssertNotNil(headers?["User-Agent"])
  }

  func testNonBilibiliHostDoesNotReceiveCookieHeader() {
    let headers = RemotePlaybackAsset.httpHeaders(
      for: URL(string: "https://media.example.test/video.mp4")!,
      cookieHeader: "SESSDATA=should-not-leak"
    )
    XCTAssertNil(headers?["Cookie"])
  }

  func testRapidSwitchCancelsPreviousAsyncPrepareWithoutLeavingStaleReadyState() {
    let controller = RemotePreviewPlayerController()
    let videoA = URL(string: "https://media.example.test/a-video.m4s")!
    let audioA = URL(string: "https://media.example.test/a-audio.m4s")!
    let videoB = URL(string: "https://media.example.test/b-video.m4s")!
    let audioB = URL(string: "https://media.example.test/b-audio.m4s")!

    controller.prepare(url: videoA, companionAudioURL: audioA)
    XCTAssertEqual(controller.preparePhase, .preparing)

    // 快速切到 B：必须取消 A 的未完成 prepare，状态仍是 preparing（B），不是 ready(A)。
    controller.prepare(url: videoB, companionAudioURL: audioB)
    XCTAssertEqual(controller.preparePhase, .preparing)
    XCTAssertFalse(controller.hasPlayer, "异步路径尚未完成时不应提前 ready")

    // 离开可播上下文：release 清空，供列表预热宿主在切走历史条目时调用。
    controller.release()
    XCTAssertEqual(controller.preparePhase, .idle)
    XCTAssertFalse(controller.hasPlayer)
  }

  func testPreheatTargetOnlyWhenSelectedIsCurrentPlayableCapture() {
    let taskID = TaskID()
    let otherID = TaskID()
    let descriptor = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://www.bilibili.com/video/BV1preheat",
      canonicalURL: "https://www.bilibili.com/video/BV1preheat",
      platform: "bilibili",
      ephemeralPlaybackURL: "https://upos.bilivideo.com/preheat-video.m4s",
      companionAudioURL: "https://upos.bilivideo.com/preheat-audio.m4s",
      mimeType: "application/octet-stream",
      transcriptionCapability: .supported
    )
    let envelope = CaptureEnvelopeV2(
      requestId: "req-preheat",
      createdAt: "2026-07-25T00:00:00Z",
      source: .init(
        kind: "url",
        url: descriptor.pageURL,
        title: "Preheat",
        platform: "bilibili"
      ),
      capture: .init(
        method: "dom",
        text: "caption for preheat fixture",
        characterCount: 24,
        completeness: "full",
        capturedAt: "2026-07-25T00:00:00Z"
      ),
      evidence: .init(sourceLabel: "extension", usedCookie: false),
      media: descriptor
    )
    let capture = CurrentCapture(
      envelope: envelope,
      taskID: taskID,
      snapshotID: ContentSnapshotID()
    )

    let hit = RemotePlaybackPreheat.playableTarget(selectedTaskID: taskID, currentCapture: capture)
    XCTAssertEqual(hit?.url.absoluteString, "https://upos.bilivideo.com/preheat-video.m4s")
    XCTAssertEqual(hit?.companionAudioURL?.absoluteString, "https://upos.bilivideo.com/preheat-audio.m4s")

    XCTAssertNil(RemotePlaybackPreheat.playableTarget(selectedTaskID: otherID, currentCapture: capture))
    XCTAssertNil(RemotePlaybackPreheat.playableTarget(selectedTaskID: taskID, currentCapture: nil))
  }

  func testNetworkUnavailableIsDistinctFromGenericAndExpired() {
    XCTAssertTrue(
      RemotePreviewPlayerController.isNetworkUnavailable(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
      )
    )
    XCTAssertTrue(
      RemotePreviewPlayerController.isNetworkUnavailable(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
      )
    )
    XCTAssertFalse(
      RemotePreviewPlayerController.isNetworkUnavailable(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
      )
    )
    XCTAssertFalse(RemotePreviewPlayerController.isNetworkUnavailable(nil))

    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/a.mp4")!
    controller.prepare(url: url)
    controller.markPlaybackFailed(
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    )
    XCTAssertEqual(controller.preparePhase, .failed(.networkUnavailable))
    if case let .failed(kind) = controller.preparePhase {
      XCTAssertTrue(kind.message.contains("网络似乎不可用"))
    }

    controller.markPlaybackFailed(error: NSError(domain: "AVFoundationErrorDomain", code: -11828))
    XCTAssertEqual(controller.preparePhase, .failed(.generic))
    if case let .failed(kind) = controller.preparePhase {
      XCTAssertFalse(kind.message.contains("网络似乎不可用"))
    }

    // 过期是 resolve 层语义，不是 runtime failure。
    let expired = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://example.test/watch",
      canonicalURL: "https://example.test/watch",
      platform: "fixture",
      ephemeralPlaybackURL: "https://media.example.test/expired.mp4",
      expiresAt: "2020-01-01T00:00:00Z",
      transcriptionCapability: .supported
    )
    XCTAssertEqual(
      CurrentCaptureMediaPreview.resolve(expired, now: Date(timeIntervalSince1970: 1_784_500_000)),
      .expired
    )
  }

  func testRetryAfterNetworkFailureRestartsPrepare() {
    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/retry.mp4")!
    controller.prepare(url: url)
    controller.markPlaybackFailed(
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    )
    XCTAssertEqual(controller.preparePhase, .failed(.networkUnavailable))

    controller.retry()
    // 单轨同步：retry 后应再次 ready（不需要真实网络就能建 AVPlayer）。
    XCTAssertEqual(controller.preparePhase, .ready)
    XCTAssertTrue(controller.hasPlayer)
  }

  func testFallbackToLegacyDisablesFurtherFallback() {
    let controller = RemotePreviewPlayerController()
    let url = URL(string: "https://media.example.test/a.mp4")!
    controller.prepare(url: url)
    XCTAssertTrue(controller.canFallbackToLegacy)
    XCTAssertTrue(controller.fallbackToLegacyIfNeeded())
    XCTAssertTrue(controller.hasPlayer)
    XCTAssertFalse(controller.canFallbackToLegacy)
    XCTAssertFalse(controller.fallbackToLegacyIfNeeded())
  }

  func testRemotePlaybackAssetLeavesFileURLUnchanged() {
    let fileURL = URL(fileURLWithPath: "/tmp/linkdigest-local-preview.mp4")
    let asset = RemotePlaybackAsset.make(url: fileURL)
    XCTAssertEqual(asset.url, fileURL)
  }

  func testBilibiliHostGetsRefererHeader() {
    let headers = RemotePlaybackAsset.httpHeaders(
      for: URL(string: "https://xy123.bilivideo.com/upgcxcode/video.m4s")!
    )
    XCTAssertEqual(headers?["Referer"], "https://www.bilibili.com/")
    XCTAssertEqual(headers?["Origin"], "https://www.bilibili.com")
    XCTAssertNotNil(headers?["User-Agent"])
    XCTAssertNil(headers?["Cookie"])
  }
}
