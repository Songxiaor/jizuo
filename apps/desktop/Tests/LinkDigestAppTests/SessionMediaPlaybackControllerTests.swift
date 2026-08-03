import XCTest

@testable import LinkDigestAdapters
@testable import LinkDigestApp
@testable import LinkDigestCore

/// 锁住两个真机上烧过的时序缺陷。它们都属于「每一环单独读都是对的，
/// 改回去也不会有编译错误」的类型，没有测试就只能等下一次真机复发：
/// 1. 用户手选的清晰度被后续不带 override 的自动刷新覆盖（选了高清没反应）；
/// 2. 详情页重入时把在飞的刷新取消重启，形成 1 秒一圈的死循环
///    （真机烧到过第 107 次尝试）。
@MainActor
final class SessionMediaPlaybackControllerTests: XCTestCase {
  private let pageURL = "https://www.bilibili.com/video/BV1ehge6jE6h"
  private let taskID = TaskID()

  private func makeStore() throws -> UserDefaultsMediaStoragePreferenceStore {
    let (suite, defaults) = try ephemeralDefaults("linkdigest-session-playback-")
    return UserDefaultsMediaStoragePreferenceStore(defaults: defaults, key: suite)
  }

  private func makeController(
    resources: any SafeResourceFetching
  ) throws -> SessionMediaPlaybackController {
    let store = try makeStore()
    store.sessionMediaRestoreMode = .automatic
    return SessionMediaPlaybackController(
      preferenceStore: store,
      refreshService: SessionMediaRefreshService(resources: resources)
    )
  }

  private func waitUntilIdle(
    _ controller: SessionMediaPlaybackController,
    timeout: TimeInterval = 5
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while controller.phase == .refreshing, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func testManualQualityChoiceSticksAcrossOverrideFreeRefreshes() async throws {
    let fake = BilibiliPlayURLFake()
    let controller = try makeController(resources: fake)

    controller.requestRefresh(
      taskID: taskID, platform: "bilibili", sourceURL: pageURL, author: nil,
      qualityOverride: .highest
    )
    await waitUntilIdle(controller)
    XCTAssertTrue(
      fake.playURLQNs.contains("127"),
      "手选「尽量高清」应以 qn=127 请求，实际 \(fake.playURLQNs)"
    )

    // 关键回归：后续不带 override 的刷新（自动恢复、失败卡重试都走这条）
    // 曾把手选结果盖成默认档。粘住的 chosenQuality 必须继续生效。
    fake.playURLQNs.removeAll()
    controller.invalidateAndRefresh(
      taskID: taskID, platform: "bilibili", sourceURL: pageURL, author: nil
    )
    await waitUntilIdle(controller)
    XCTAssertFalse(fake.playURLQNs.isEmpty, "第二次刷新应真的发出 playurl 请求")
    XCTAssertTrue(
      fake.playURLQNs.allSatisfy { $0 == "127" },
      "不带 override 的刷新必须沿用手选档 qn=127，实际 \(fake.playURLQNs)"
    )
  }

  func testDetailReentryDoesNotRestartInFlightRefresh() async throws {
    let fake = BilibiliPlayURLFake()
    fake.hangForever = true
    let controller = try makeController(resources: fake)

    controller.requestRefresh(
      taskID: taskID, platform: "bilibili", sourceURL: pageURL, author: nil
    )
    // 给挂起的请求一点时间进入 refreshing。
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.phase, .refreshing)
    XCTAssertEqual(controller.refreshAttempts, 1)

    // 视图重建会反复走到 detailBecameActive；同一条+仍在刷新时必须原地不动，
    // 否则「取消 → 重启 → generation+1 → 重建视图 → 再取消」1 秒一圈永不收敛。
    for _ in 0..<3 {
      controller.detailBecameActive(
        taskID: taskID, platform: "bilibili", sourceURL: pageURL, author: nil,
        hadMediaDescriptor: true, hasLocalMedia: false,
        isCurrentCaptureWithDescriptor: false, isYouTube: false
      )
    }
    XCTAssertEqual(
      controller.refreshAttempts, 1,
      "详情页重入不得重启在飞的刷新"
    )
    XCTAssertEqual(controller.phase, .refreshing)
  }

  func testDouyinHistoryRefreshUsesRenderedCaptureCallback() async throws {
    let expected = MediaDescriptor(
      kind: .directFile,
      pageURL: "https://www.douyin.com/video/7661288207509769506",
      canonicalURL: "https://www.douyin.com/video/7661288207509769506",
      platform: "douyin",
      ephemeralPlaybackURL: "https://v3.douyinvod.com/video.mp4",
      posterURL: "https://p3.douyinpic.com/cover.jpeg",
      durationSeconds: 165,
      author: "青山言",
      transcriptionCapability: .supported,
      selectionReason: .singleCandidate,
      playbackState: .unknown
    )
    let service = SessionMediaRefreshService(
      resources: BilibiliPlayURLFake(),
      douyinRefresh: { sourceURL, author in
        guard sourceURL == expected.pageURL, author == "旧作者" else {
          throw SessionMediaRefreshError.networkOrParse
        }
        return expected
      }
    )

    let actual = try await service.refresh(
      platform: "douyin",
      sourceURL: expected.pageURL,
      author: "旧作者"
    )

    XCTAssertEqual(actual, expected)
  }
}

/// 最小 B 站 playurl 桩：view 返回 13 分钟长片，playurl 返回可通过
/// CDN 白名单与编码筛选的 DASH 双轨。记录每次 playurl 的 qn。
private final class BilibiliPlayURLFake: SafeResourceFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var qns: [String] = []
  var hangForever = false

  var playURLQNs: [String] {
    get { lock.withLock { qns } }
    set { lock.withLock { qns = newValue } }
  }

  func fetchResource(_ request: SafeResourceRequest) async throws -> SafeResourceResponse {
    if hangForever {
      try await Task.sleep(for: .seconds(3600))
      throw CancellationError()
    }
    let path = request.url.path
    let json: String
    if path.contains("web-interface/view") {
      json = #"{"code":0,"data":{"cid":123456,"duration":780,"owner":{"name":"大耳朵 TV"}}}"#
    } else if path.contains("player/playurl") {
      let qn = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "qn" })?.value ?? "?"
      lock.withLock { qns.append(qn) }
      json = #"""
      {"code":0,"data":{"timelength":780000,"quality":120,"dash":{
        "video":[{"id":120,"width":3840,"height":2160,"bandwidth":8000000,
          "codecs":"avc1.640033",
          "baseUrl":"https://upos-sz-mirror08h.bilivideo.com/v.m4s?deadline=9999999999"}],
        "audio":[{"id":30280,"bandwidth":192000,"codecs":"mp4a.40.2",
          "baseUrl":"https://upos-sz-mirror08h.bilivideo.com/a.m4s?deadline=9999999999"}]
      }}}
      """#
    } else {
      json = #"{"code":0,"data":{}}"#
    }
    return .init(
      url: request.url, statusCode: 200,
      contentType: "application/json", body: Data(json.utf8)
    )
  }
}
