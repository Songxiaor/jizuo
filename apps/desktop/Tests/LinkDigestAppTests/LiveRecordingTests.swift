import Foundation
import XCTest
@testable import LinkDigestApp
@testable import LinkDigestCore

@MainActor
final class LiveRecordingTests: XCTestCase {
  private let pageURL = "https://live.douyin.com/427518068747"

  // MARK: - 合同

  private func requestJSON(
    quality: String = "origin",
    variants: [[String: Any]]? = nil
  ) throws -> Data {
    let defaultVariants: [[String: Any]] = [
      ["quality": "origin", "container": "hls", "url": "https://pull-hls.example.test/stream.m3u8?sign=sanitized", "resolution": "1080x1920", "label": "蓝光"],
      ["quality": "origin", "container": "flv", "url": "https://pull-flv.example.test/stream.flv?sign=sanitized"],
      ["quality": "hd", "container": "flv", "url": "https://pull-flv.example.test/stream_hd.flv?sign=sanitized"],
      ["quality": "hd", "container": "hls", "url": "https://pull-hls.example.test/stream_hd.m3u8?sign=sanitized"],
      ["quality": "sd", "container": "flv", "url": "https://pull-flv.example.test/stream_sd.flv?sign=sanitized"],
      ["quality": "ld", "container": "flv", "url": "https://pull-flv.example.test/stream_ld.flv?sign=sanitized"],
    ]
    let object: [String: Any] = [
      "kind": "liveRecording",
      "version": 1,
      "requestId": "req-live-1",
      "createdAt": "2026-11-11T12:00:00Z",
      "platform": "douyin",
      "pageURL": pageURL,
      "roomID": "427518068747",
      "anchorName": "示例主播",
      "anchorID": "SEC_demo",
      "anchorAvatarURL": "https://avatar.example.test/anchor.jpg",
      "anchorProfileURL": "https://www.douyin.com/user/SEC_demo",
      "title": "示例直播",
      "quality": quality,
      "variants": variants ?? defaultVariants,
      "requestHeaders": [
        "referer": "https://live.douyin.com/",
        "userAgent": "Mozilla/5.0 (Macintosh) Test",
      ],
    ]
    return try JSONSerialization.data(withJSONObject: object)
  }

  func testDecodesLiveRecordingMessageAndPrefersHLSForOrigin() throws {
    let request = try XCTUnwrap(try LiveRecordingRequest.decode(requestJSON()))
    XCTAssertEqual(request.requestId, "req-live-1")
    XCTAssertEqual(request.platform, .douyin)
    XCTAssertEqual(request.quality, .origin)
    XCTAssertEqual(request.anchorName, "示例主播")
    XCTAssertEqual(request.anchorID, "SEC_demo")
    XCTAssertEqual(request.anchorAvatarURL, "https://avatar.example.test/anchor.jpg")
    XCTAssertEqual(request.anchorProfileURL, "https://www.douyin.com/user/SEC_demo")
    XCTAssertEqual(request.variants.count, 6)
    XCTAssertEqual(request.selectedVariant()?.container, .hls)
    XCTAssertEqual(request.selectedVariant()?.quality, .origin)

    let hd = try XCTUnwrap(try LiveRecordingRequest.decode(requestJSON(quality: "hd")))
    XCTAssertEqual(hd.selectedVariant()?.container, .flv, "非原画优先 FLV")
  }

  func testUnknownKindIsNotALiveMessage() throws {
    let other = try JSONSerialization.data(withJSONObject: ["kind": "taskAccepted", "version": 1, "requestId": "x"])
    XCTAssertNil(try LiveRecordingRequest.decode(other))
  }

  func testCaptureReceiverRoutesLiveRecordingAndAcksWithRecordingID() async throws {
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(),
      nowMilliseconds: { 0 },
      captureSink: { _ in },
      liveRecordingSink: { request in
        XCTAssertEqual(request.requestId, "req-live-1")
        return .accepted(recordingID: "recording-1")
      }
    )
    let response = await receiver.process(try requestJSON())
    guard case let .liveRecordingAccepted(version, requestID, recordingID) = response else {
      return XCTFail("应回 liveRecordingAccepted，实际 \(response)")
    }
    XCTAssertEqual(version, 1)
    XCTAssertEqual(requestID, "req-live-1")
    XCTAssertEqual(recordingID, "recording-1")
  }

  func testCaptureReceiverSurfacesRejectedLiveRecordingCode() async throws {
    let receiver = CaptureReceiver(
      history: nil,
      storageWriteGate: StorageWriteGate(),
      nowMilliseconds: { 0 },
      captureSink: { _ in },
      liveRecordingSink: { _ in .rejected(code: "LIVE_FFMPEG_NOT_FOUND") }
    )
    let response = await receiver.process(try requestJSON())
    guard case let .error(error) = response else {
      return XCTFail("应回错误，实际 \(response)")
    }
    XCTAssertEqual(error.code, "LIVE_FFMPEG_NOT_FOUND")
    XCTAssertFalse(error.retryable)
  }

  func testRejectsOriginWithoutHLSAndNonLivePage() throws {
    let originFLVOnly: [[String: Any]] = [
      ["quality": "origin", "container": "flv", "url": "https://pull-flv.example.test/stream.flv?sign=sanitized"],
    ]
    XCTAssertThrowsError(try LiveRecordingRequest.decode(requestJSON(variants: originFLVOnly)))

    let badPage = try JSONSerialization.data(withJSONObject: [
      "kind": "liveRecording",
      "version": 1,
      "requestId": "req-bad",
      "createdAt": "2026-11-11T12:00:00Z",
      "platform": "douyin",
      "pageURL": "https://www.douyin.com/root/live/1",
      "quality": "hd",
      "variants": [["quality": "hd", "container": "flv", "url": "https://pull-flv.example.test/a.flv"]],
    ])
    XCTAssertThrowsError(try LiveRecordingRequest.decode(badPage))
  }

  func testFallsBackToLowerQualityWhenRequestedTierIsMissing() {
    let variants = [
      LiveStreamVariant(quality: .sd, container: .hls, url: "https://x.test/sd.m3u8"),
      LiveStreamVariant(quality: .ld, container: .flv, url: "https://x.test/ld.flv"),
    ]
    XCTAssertEqual(LiveRecordingRequest.select(variants: variants, requested: .hd)?.quality, .sd)
    XCTAssertEqual(LiveRecordingRequest.select(variants: variants, requested: .origin)?.quality, .sd)
    XCTAssertNil(LiveRecordingRequest.select(variants: [], requested: .origin))
    // 小红书原画是 FLV，可以直接选，不需要 HLS。
    let xhs = [LiveStreamVariant(quality: .origin, container: .flv, url: "https://x.test/a.flv")]
    XCTAssertEqual(LiveRecordingRequest.select(variants: xhs, requested: .origin, platform: .xiaohongshu)?.container, .flv)
    XCTAssertNil(LiveRecordingRequest.select(variants: xhs, requested: .origin, platform: .douyin))
  }

  // MARK: - ffmpeg

  func testRecordArgumentsUseStreamCopyHeadersReconnectAndHVC1OnlyForOrigin() {
    let origin = FFmpegCommand.record(
      inputURL: "https://pull.example.test/a.m3u8?sign=1",
      outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
      userAgent: "UA",
      referer: "https://live.douyin.com/",
      quality: .origin
    )
    XCTAssertEqual(Array(origin.prefix(2)), ["-hide_banner", "-nostdin"])
    XCTAssertTrue(origin.contains("-loglevel"))
    XCTAssertEqual(origin[origin.firstIndex(of: "-loglevel")! + 1], "quiet")
    XCTAssertTrue(origin.contains("Referer: https://live.douyin.com/\r\n"))
    XCTAssertTrue(origin.contains("-reconnect"))
    XCTAssertTrue(origin.contains("-reconnect_streamed"))
    XCTAssertTrue(origin.contains("-rw_timeout"))
    XCTAssertEqual(origin[origin.firstIndex(of: "-rw_timeout")! + 1], "15000000")
    XCTAssertTrue(origin.contains("-c") && origin.contains("copy"))
    XCTAssertTrue(origin.contains("0:v:0") && origin.contains("0:a:0?"))
    XCTAssertFalse(origin.contains("hvc1"), "录制阶段不能盲打 hvc1：同一档可能是 H.264")
    XCTAssertTrue(origin.contains("+faststart"))
    XCTAssertEqual(origin.last, "/tmp/out.mp4")

    let hd = FFmpegCommand.record(
      inputURL: "https://pull.example.test/a.flv?sign=1",
      outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
      userAgent: "UA",
      referer: "https://live.douyin.com/",
      quality: .hd
    )
    XCTAssertFalse(hd.contains("hvc1"), "H.264 不能打 hvc1")
    XCTAssertTrue(FFmpegCommand.shouldTagHVC1(codecName: "hevc"))
    XCTAssertTrue(FFmpegCommand.shouldTagHVC1(codecName: "H265"))
    XCTAssertFalse(FFmpegCommand.shouldTagHVC1(codecName: "h264"))
    XCTAssertFalse(FFmpegCommand.shouldTagHVC1(codecName: nil))

    let segment = FFmpegCommand.record(
      inputURL: "https://pull.example.test/a.m3u8",
      outputURL: URL(fileURLWithPath: "/tmp/segment-0001.ts"),
      userAgent: "UA",
      referer: "https://live.douyin.com/",
      quality: .origin
    )
    XCTAssertFalse(segment.contains("+faststart"), "TS 中间段不加 faststart")
    XCTAssertEqual(segment.last, "/tmp/segment-0001.ts")
    XCTAssertTrue(
      LiveRecordingNaming.segmentURL(
        segmentsDirectory: URL(fileURLWithPath: "/tmp/parts"), index: 3
      ).lastPathComponent == "segment-0003.ts"
    )
  }

  func testConcatArgumentsAndListEscaping() {
    let list = URL(fileURLWithPath: "/tmp/it's/list.txt")
    let arguments = FFmpegCommand.concat(
      listFile: list,
      outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
      tagHVC1: true
    )
    XCTAssertTrue(arguments.contains("-f") && arguments.contains("concat"))
    XCTAssertTrue(arguments.contains("-safe") && arguments.contains("0"))
    XCTAssertTrue(arguments.contains("hvc1"))
    let line = FFmpegCommand.concatListLine(fileURL: URL(fileURLWithPath: "/tmp/it's/segment-0001.mp4"))
    XCTAssertEqual(line, "file '/tmp/it'\\''s/segment-0001.mp4'\n")
  }

  func testXiaohongshuArgumentsMapVideoAndOptionalAudio() {
    let arguments = FFmpegCommand.record(
      inputURL: "https://live-source-play.example.test/live/1.flv",
      outputURL: URL(fileURLWithPath: "/tmp/xhs.mp4"),
      userAgent: "UA",
      referer: "https://www.xiaohongshu.com/",
      quality: .origin,
      platform: .xiaohongshu
    )
    XCTAssertTrue(arguments.contains("-map"))
    XCTAssertTrue(arguments.contains("0:v:0"))
    XCTAssertTrue(arguments.contains("0:a:0?"))
    XCTAssertTrue(arguments.contains("copy"))
  }

  func testLocatorOrderAndFirstExecutableWins() {
    let bundle = URL(fileURLWithPath: "/Applications/汲作.app/Contents/Resources")
    let candidates = FFmpegLocator.candidateURLs(bundleResourceURL: bundle, executableURL: nil)
    XCTAssertEqual(candidates.first?.path, "/Applications/汲作.app/Contents/Resources/ffmpeg")
    XCTAssertEqual(candidates[1].path, "/opt/homebrew/bin/ffmpeg")
    XCTAssertEqual(candidates[2].path, "/usr/local/bin/ffmpeg")

    let chosen = FFmpegLocator.locate(candidates: candidates) { $0.path == "/usr/local/bin/ffmpeg" }
    XCTAssertEqual(chosen?.path, "/usr/local/bin/ffmpeg")
    XCTAssertNil(FFmpegLocator.locate(candidates: candidates) { _ in false })
  }

  // MARK: - 续录状态机

  func testReconnectsAfterSegmentExitAndResumesWhenRoomStillLive() {
    var machine = LiveRecordingStateMachine()
    XCTAssertEqual(machine.handle(.begin), .startSegment)
    XCTAssertEqual(machine.handle(.segmentStarted), .none)
    XCTAssertEqual(machine.segmentCount, 1)
    XCTAssertEqual(machine.handle(.segmentExited(status: 1)), .reconnect(after: 0.5))
    XCTAssertEqual(machine.handle(.streamRefreshFoundLive), .startSegment)
    XCTAssertEqual(machine.handle(.segmentStarted), .none)
    XCTAssertEqual(machine.segmentCount, 2)
  }

  func testGivesUpAfterConsecutiveRefreshFailuresAndKeepsRecordedSegments() {
    var machine = LiveRecordingStateMachine(policy: .init(maxConsecutiveFailures: 3, retryDelays: [1, 2, 4]))
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    XCTAssertEqual(machine.handle(.segmentExited(status: 255)), .reconnect(after: 0.5))
    XCTAssertEqual(machine.handle(.streamRefreshFailed), .reconnect(after: 1))
    XCTAssertEqual(machine.handle(.streamRefreshFailed), .reconnect(after: 2))
    XCTAssertEqual(machine.handle(.streamRefreshFailed), .merge(.gaveUp))
    XCTAssertEqual(machine.handle(.mergeSucceeded), .completed)
    XCTAssertEqual(machine.phase, .completed)
    XCTAssertEqual(machine.stopReason, .gaveUp)
  }

  func testEndedStreamMergesImmediately() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    _ = machine.handle(.segmentExited(status: 0))
    XCTAssertEqual(machine.handle(.streamRefreshEnded), .merge(.streamEnded))
  }

  func testUserStopDuringRecordingWaitsForProcessThenMerges() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    XCTAssertEqual(machine.handle(.userRequestedStop), .none)
    XCTAssertEqual(machine.handle(.segmentExited(status: 0)), .merge(.userStopped))
  }

  func testUserStopWhileReconnectingMergesWithoutWaiting() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    _ = machine.handle(.segmentExited(status: 1))
    XCTAssertEqual(machine.handle(.userRequestedStop), .merge(.userStopped))
  }

  func testVerificationStopsReconnectAndKeepsRecordedSegments() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    _ = machine.handle(.segmentExited(status: 255))
    XCTAssertEqual(machine.handle(.verificationRequired), .merge(.verificationRequired))
    XCTAssertEqual(machine.stopReason, .verificationRequired)
  }

  func testLowDiskStopsRecordingAndMerges() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    XCTAssertEqual(machine.handle(.diskSpaceLow), .merge(.diskSpaceLow))
    XCTAssertEqual(machine.stopReason, .diskSpaceLow)
  }

  func testMergeFailureIsReported() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    _ = machine.handle(.segmentExited(status: 1))
    XCTAssertEqual(machine.handle(.mergeFailed), .failed)
    guard case .failed = machine.phase else { return XCTFail("应为 failed") }
  }

  func testKeepsExistingSegmentsWhenRecordingKeepsFailing() {
    var machine = LiveRecordingStateMachine()
    _ = machine.handle(.begin)
    _ = machine.handle(.segmentStarted)
    XCTAssertEqual(machine.handle(.recordingKeptFailing), .merge(.gaveUp))
  }

  // MARK: - 页面解析

  private func escapedPageHTML() throws -> String {
    let stream: [String: Any] = [
      "flv_pull_url": [
        "FULL_HD1": "http://pull-flv.example.test/stream_or4.flv?sign=sanitized",
        "HD1": "http://pull-flv.example.test/stream_hd.flv?sign=sanitized",
        "SD1": "http://pull-flv.example.test/stream_ld.flv?sign=sanitized",
        "SD2": "http://pull-flv.example.test/stream_sd.flv?sign=sanitized",
      ],
      "hls_pull_url_map": [
        "FULL_HD1": "http://pull-hls.example.test/stream_or4.m3u8?sign=sanitized",
        "HD1": "http://pull-hls.example.test/stream_hd.m3u8?sign=sanitized",
        "SD2": "http://pull-hls.example.test/stream_sd.m3u8?sign=sanitized",
      ],
      "live_core_sdk_data": [
        "pull_data": [
          "options": [
            "qualities": [
              ["name": "标清", "sdk_key": "ld", "resolution": "540x960"],
              ["name": "高清", "sdk_key": "sd", "resolution": "720x1280"],
              ["name": "超清", "sdk_key": "hd", "resolution": "720x1280"],
              ["name": "蓝光", "sdk_key": "origin", "resolution": "1080x1920"],
            ],
          ],
        ],
      ],
    ]
    let room: [String: Any] = [
      "anchorStore": [
        "roomInfo": [
          "stream_url": stream,
          "owner": ["id_str": "10001", "sec_uid": "SEC_demo", "nickname": "示例主播"],
        ],
      ],
    ]
    let roomJSON = String(data: try JSONSerialization.data(withJSONObject: room), encoding: .utf8)!
    let chunks = ["d:[\"$\",\"$L12\",null,", roomJSON, "]"]
    return chunks.map { chunk in
      let literal = String(data: try! JSONEncoder().encode(chunk), encoding: .utf8)!
      return "<script>self.__pace_f.push([1,\(literal)])</script>"
    }.joined()
  }

  func testParsesSplitPaceChunksIntoRoomAndVariants() throws {
    let room = try XCTUnwrap(
      DouyinLivePageParser.parse(
        html: try escapedPageHTML(),
        pageURL: pageURL,
        title: "示例直播间"
      )
    )
    XCTAssertEqual(room.roomID, "427518068747")
    XCTAssertEqual(room.anchorName, "示例主播")
    XCTAssertEqual(room.title, "示例直播间")
    XCTAssertEqual(room.variants.map { "\($0.quality.rawValue):\($0.container.rawValue)" }, [
      "origin:hls", "origin:flv", "hd:flv", "hd:hls", "sd:flv", "sd:hls", "ld:flv",
    ])
    XCTAssertEqual(LiveRecordingRequest.select(variants: room.variants, requested: .origin)?.container, .hls)
  }

  func testParserFallsBackToObservedResourceURLsAndReturnsNilForShell() {
    let room = DouyinLivePageParser.parse(
      html: "<html>空壳</html>",
      pageURL: pageURL,
      resourceURLs: ["https://pull-hls.example.test/stream_sd.m3u8?sign=sanitized"]
    )
    XCTAssertEqual(room?.variants.first?.quality, .sd)
    XCTAssertNil(DouyinLivePageParser.parse(html: "", pageURL: "https://live.douyin.com/123456789"))
    XCTAssertNil(DouyinLivePageParser.roomID(fromPageURL: "https://www.douyin.com/root/live/1"))
  }

  // MARK: - 小红书

  func testXiaohongshuPullConfigKeepsOriginAndRanksOtherTiersByBitrate() throws {
    let config = """
    {"streams":[
      {"quality_type_name":"1080P 高帧率","protocol":"flv","max_bitrate":6000000,"master_url":"http://pull.example.test/live/570537012912716275_hcv5401.flv"},
      {"quality_type_name":"1080P 蓝光","protocol":"flv","max_bitrate":4000000,"master_url":"http://pull.example.test/live/570537012912716275_hcv5301.flv"},
      {"quality_type_name":"1080P 高清","protocol":"flv","max_bitrate":2000000,"master_url":"http://pull.example.test/live/570537012912716275_hcv5201.flv"},
      {"quality_type_name":"原画","quality_type":"FLV","protocol":"flv","max_bitrate":3500000,"master_url":"http://pull.example.test/live/570537012912716275.flv"}
    ]}
    """
    let variants = XiaohongshuLivePageParser.variants(pullConfig: config)
    XCTAssertEqual(variants.map(\.quality), [.origin, .hd, .sd, .ld])
    XCTAssertTrue(variants.allSatisfy { $0.url.hasPrefix("https://") })
    XCTAssertEqual(variants[1].label, "1080P 高帧率")
    let room = try XCTUnwrap(
      XiaohongshuLivePageParser.room(
        pullConfig: config,
        pageURL: "https://www.xiaohongshu.com/livestream/570537012912716275",
        anchorName: "示例主播",
        title: "示例直播"
      )
    )
    XCTAssertEqual(room.roomID, "570537012912716275")
    XCTAssertEqual(LiveRecordingRequest.select(variants: room.variants, requested: .origin, platform: .xiaohongshu)?.container, .flv)
  }

  func testXiaohongshuPageURLAndFallbackDeeplink() {
    XCTAssertEqual(
      XiaohongshuLivePageParser.roomID(fromPageURL: "https://www.xiaohongshu.com/livestream/570537012912716275?x=1"),
      "570537012912716275"
    )
    XCTAssertNil(XiaohongshuLivePageParser.roomID(fromPageURL: "https://www.xiaohongshu.com/explore/abc"))
    let variants = XiaohongshuLivePageParser.variants(
      pullConfig: "not json",
      fallbackFLVURL: "http://pull.example.test/live/1.flv"
    )
    XCTAssertEqual(variants.first?.url, "https://pull.example.test/live/1.flv")
  }

  func testDecodesXiaohongshuOriginFLVMessage() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "kind": "liveRecording",
      "version": 1,
      "requestId": "req-xhs",
      "createdAt": "2026-11-11T12:00:00Z",
      "platform": "xiaohongshu",
      "pageURL": "https://www.xiaohongshu.com/livestream/570537012912716275",
      "quality": "origin",
      "variants": [[
        "quality": "origin", "container": "flv",
        "url": "https://pull.example.test/live/1.flv",
      ]],
    ])
    let request = try XCTUnwrap(try LiveRecordingRequest.decode(data))
    XCTAssertEqual(request.platform, .xiaohongshu)
    XCTAssertEqual(request.selectedVariant()?.container, .flv)
  }

  // MARK: - 断线重取页面的错误分类

  private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body: String = ""
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: Self.status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  private func stubFetcher(body: String) -> DouyinLiveRoomFetcher {
    StubURLProtocol.body = body
    StubURLProtocol.status = 200
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return DouyinLiveRoomFetcher(session: URLSession(configuration: configuration))
  }

  func testFetcherDistinguishesEndedRetryableAndVerificationPages() async throws {
    let live = try await stubFetcher(body: escapedPageHTML()).fetchRoom(
      platform: .douyin,
      pageURL: pageURL,
      userAgent: "UA",
      referer: "https://live.douyin.com/"
    )
    XCTAssertEqual(live.roomID, "427518068747")

    do {
      _ = try await stubFetcher(body: "<html><body>验证码中间页 sec_sdk_build</body></html>")
        .fetchRoom(platform: .douyin, pageURL: pageURL, userAgent: "UA", referer: "https://live.douyin.com/")
      XCTFail("验证码页应报 verificationRequired")
    } catch let error as LiveRoomFetchError {
      XCTAssertEqual(error, .verificationRequired)
    }

    do {
      _ = try await stubFetcher(body: "<html><body>空壳</body></html>")
        .fetchRoom(platform: .douyin, pageURL: pageURL, userAgent: "UA", referer: "https://live.douyin.com/")
      XCTFail("空壳应报 unavailable")
    } catch let error as LiveRoomFetchError {
      XCTAssertEqual(error, .unavailable)
    }

    do {
      _ = try await stubFetcher(body: "<html>{\"web_stream_url\":null}</html>")
        .fetchRoom(platform: .douyin, pageURL: pageURL, userAgent: "UA", referer: "https://live.douyin.com/")
      XCTFail("房间数据还在但没有流，应报 ended")
    } catch let error as LiveRoomFetchError {
      XCTAssertEqual(error, .ended)
    }
  }

  // MARK: - 文件名与目录

  func testFileNameSanitizesAnchorAndKeepsLocalTimestamp() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    let date = Date(timeIntervalSince1970: 1_762_872_000)
    let name = LiveRecordingNaming.fileName(anchorName: " 亲爱的/安先生: ", startedAt: date)
    XCTAssertEqual(name, "亲爱的-安先生_\(LiveRecordingNaming.timestamp(date, calendar: calendar)).mp4")
    XCTAssertFalse(name.contains("/"))
    XCTAssertEqual(LiveRecordingNaming.sanitizedComponent(nil), "直播")
    XCTAssertTrue(
      LiveRecordingNaming.fileName(anchorName: nil, title: "cc 的直播", startedAt: date)
        .hasPrefix("cc 的直播_")
    )
  }

  func testPreferencesDefaultAndCustomDirectory() {
    let root = URL(fileURLWithPath: "/tmp/linkdigest-root")
    let preference = LiveRecordingPreferences(defaults: UserDefaults(suiteName: "live-recording-test")!, applicationSupportRoot: root)
    XCTAssertEqual(preference.recordingDirectory.lastPathComponent, "直播录制")
    XCTAssertTrue(preference.recordingDirectory.path.hasSuffix("LinkDigest/直播录制"))
    let custom = URL(fileURLWithPath: "/Volumes/SSD/live")
    XCTAssertEqual(
      LiveRecordingPreferences.liveRecordingDirectory(defaultDirectory: root, customPath: custom.path).path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      "Volumes/SSD/live"
    )
    XCTAssertEqual(
      LiveRecordingPreferences.liveRecordingDirectory(defaultDirectory: root, customPath: " "),
      root
    )
  }

  // MARK: - 入库字段

  func testIngestDocumentCarriesLiveSourceAnchorTitleAndDuration() throws {
    let payload = LiveRecordingIngestPayload(
      fileURL: URL(fileURLWithPath: "/tmp/亲爱的安先生_2026-11-11_20-53-10.mp4"),
      platform: .douyin,
      anchorName: "亲爱的安先生",
      anchorID: "SEC_demo",
      anchorAvatarURL: "https://p3-pc.douyinpic.com/aweme/100x100/test-avatar.jpg",
      anchorProfileURL: "https://www.douyin.com/user/SEC_demo",
      title: "今晚聊聊内容",
      pageURL: pageURL,
      roomID: "427518068747",
      startedAt: Date(timeIntervalSince1970: 1_762_872_000),
      durationSeconds: 3_725,
      quality: .hd
    )
    let document = try LocalImportController.liveRecordingDocument(
      payload,
      fileName: "亲爱的安先生_2026-11-11_20-53-10.mp4",
      now: Date(timeIntervalSince1970: 1_762_875_000)
    )
    XCTAssertEqual(document.origin, .localImport)
    XCTAssertEqual(document.platform, "douyinlive")
    XCTAssertEqual(document.method, "live_recording")
    XCTAssertEqual(document.sourceLabel, "抖音直播")
    XCTAssertTrue(document.url.hasPrefix("linkdigest-local://douyinlive/"))
    XCTAssertTrue(document.title?.contains("亲爱的安先生") == true)
    XCTAssertTrue(document.text.contains("主播：亲爱的安先生"))
    XCTAssertTrue(document.text.contains("标题：今晚聊聊内容"))
    XCTAssertTrue(document.text.contains("时长：1:02:05"))
    XCTAssertTrue(document.text.contains("清晰度：高清"))
    XCTAssertTrue(document.text.contains("直播间：\(pageURL)"))
    XCTAssertTrue(document.text.contains("author: \"亲爱的安先生\""))
    XCTAssertTrue(document.text.contains("source_page: \"\(pageURL)\""))
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(document.text).sourcePage, pageURL)
    XCTAssertEqual(MarkdownNoteFrontmatter.parse(document.text).author, "亲爱的安先生")
    XCTAssertFalse(document.text.contains("从本机导入的视频"))
    XCTAssertFalse(document.text.contains("点「转写」"))
    XCTAssertFalse(document.text.contains("sign="), "签名地址不能进正文")
  }

  func testPanelFormatsDurationAndBytes() {
    XCTAssertEqual(LiveRecordingPanelView.duration(0), "0:00:00")
    XCTAssertEqual(LiveRecordingPanelView.duration(3_725), "1:02:05")
    XCTAssertFalse(LiveRecordingPanelView.byteCount(0).isEmpty)
    XCTAssertEqual(
      LiveRecordingPanelView.stopReasonText(.verificationRequired, platform: .douyin),
      "抖音要你先在浏览器里完成验证。打开这个直播间完成验证后，再点一次「开始录制」。已录的部分保留了。"
    )
    XCTAssertTrue(
      LiveRecordingPanelView.stopReasonText(.verificationRequired, platform: .xiaohongshu)
        .hasPrefix("小红书要你先在浏览器里完成验证")
    )
  }

  func testXiaohongshuIngestDocumentUsesItsOwnHostAndLabel() throws {
    let payload = LiveRecordingIngestPayload(
      fileURL: URL(fileURLWithPath: "/tmp/cc_直播.mp4"),
      platform: .xiaohongshu,
      anchorName: "cc",
      anchorID: "5f0000000000000000000001",
      anchorAvatarURL: "https://sns-avatar-qc.xhscdn.com/avatar/test.jpg",
      anchorProfileURL: "https://www.xiaohongshu.com/user/profile/5f0000000000000000000001",
      title: "不许叫妈咪",
      pageURL: "https://www.xiaohongshu.com/livestream/570537012912716275?xsec_token=secret&xsec_source=pc",
      roomID: "570537012912716275",
      startedAt: Date(timeIntervalSince1970: 1_762_872_000),
      durationSeconds: 60,
      quality: .origin
    )
    let document = try LocalImportController.liveRecordingDocument(
      payload,
      fileName: "cc_直播.mp4"
    )
    XCTAssertEqual(document.platform, "xiaohongshulive")
    XCTAssertEqual(document.sourceLabel, "小红书直播")
    XCTAssertTrue(document.url.hasPrefix("linkdigest-local://xiaohongshulive/"))
    XCTAssertTrue(document.text.contains("直播间：https://www.xiaohongshu.com/livestream/570537012912716275"))
    XCTAssertFalse(document.text.contains("xsec_token"))
    XCTAssertFalse(document.text.contains("xsec_source"))
    let identity = try XCTUnwrap(LocalImportController.liveRecordingCreatorIdentity(payload))
    XCTAssertEqual(identity.platform, "xiaohongshu.com")
    XCTAssertEqual(identity.authorID, "5f0000000000000000000001")
    XCTAssertEqual(identity.profileURL, "https://www.xiaohongshu.com/user/profile/5f0000000000000000000001")
    var secondPart = payload
    secondPart.part = 2
    let secondDocument = try LocalImportController.liveRecordingDocument(
      secondPart,
      fileName: "cc_直播-2.mp4"
    )
    XCTAssertNotEqual(document.url, secondDocument.url)
    XCTAssertTrue(secondDocument.url.hasSuffix("-part2"))
  }

  func testLiveRecordingHostsAreRegisteredPlatformsUnderFiles() {
    for (host, name) in [("douyinlive", "抖音直播"), ("xiaohongshulive", "小红书直播")] {
      XCTAssertTrue(HistoryPlatformDisplay.isWellKnown(host: host))
      XCTAssertEqual(HistoryPlatformDisplay.name(forHost: host), name)
      XCTAssertTrue(OwnershipSourceNavigation.localHosts.contains(host))
    }
  }

  func testDiskEstimateUsesQualityBitrateAndFreeSpace() {
    let free = Int64(2 * 1024 * 1024 * 1024)
    let hours = LiveRecordingDiskSpace.estimatedHours(freeBytes: free, quality: .origin)
    XCTAssertEqual(hours, 0.79, accuracy: 0.05)
    XCTAssertTrue(LiveRecordingDiskSpace.estimatedHoursText(freeBytes: free, quality: .origin).contains("小时"))
    XCTAssertEqual(LiveRecordingDiskSpace.estimatedHours(freeBytes: 0, quality: .origin), 0)
    XCTAssertEqual(LiveRecordingDiskSpace.estimatedHoursText(freeBytes: 0, quality: .hd), "空间不足")
    XCTAssertGreaterThan(LiveRecordingDiskSpace.requiredFreeBytes, LiveRecordingDiskSpace.stopFreeBytes)
  }

  func testSegmentGroupingSeparatesDifferentCodecsAndResolutions() {
    let a = LiveRecordingController.SegmentSignature(codec: "h264", width: 1080, height: 1920)
    let b = LiveRecordingController.SegmentSignature(codec: "hevc", width: 1080, height: 1920)
    let c = LiveRecordingController.SegmentSignature(codec: "h264", width: 720, height: 1280)
    let groups = LiveRecordingController.groupedSegmentIndices([a, b, a, c, nil])
    XCTAssertEqual(groups, [[0, 2], [1], [3], [4]])
    XCTAssertEqual(
      LiveRecordingNaming.numberedURL(URL(fileURLWithPath: "/tmp/a.mp4"), number: 2).lastPathComponent,
      "a-2.mp4"
    )
    XCTAssertEqual(
      LiveRecordingNaming.numberedURL(URL(fileURLWithPath: "/tmp/a.mp4"), number: 1).lastPathComponent,
      "a.mp4"
    )
  }

  func testQualityNoteOnlyWhenActualTierDiffers() {
    XCTAssertNil(LiveRecordingController.qualityNote(requested: .origin, actual: .origin))
    XCTAssertEqual(
      LiveRecordingController.qualityNote(requested: .origin, actual: .hd),
      "原画不可用，已改录高清"
    )
  }

  func testDuplicateDetectionUsesPlatformAndRoomID() {
    var item = LiveRecordingController.Item(
      id: "one",
      requestID: "req",
      platform: .douyin,
      pageURL: pageURL,
      roomID: "427518068747",
      quality: .origin,
      requestedQuality: .origin,
      anchorName: nil,
      title: nil,
      startedAt: Date()
    )
    item.phase = .recording
    XCTAssertTrue(LiveRecordingController.hasActiveDuplicate(
      items: [item], platform: .douyin, roomID: "427518068747", pageURL: "https://live.douyin.com/other"
    ))
    XCTAssertFalse(LiveRecordingController.hasActiveDuplicate(
      items: [item], platform: .xiaohongshu, roomID: "427518068747", pageURL: pageURL
    ))
    item.phase = .completed
    XCTAssertFalse(LiveRecordingController.hasActiveDuplicate(
      items: [item], platform: .douyin, roomID: "427518068747", pageURL: pageURL
    ))
  }

  func testXiaohongshuTitleFallsBackToPageTitleWithoutDoubleTimestamp() {
    let payload = LiveRecordingIngestPayload(
      fileURL: URL(fileURLWithPath: "/tmp/Sezoel的小红书直播间_2026-11-11_23-44-17.mp4"),
      platform: .xiaohongshu,
      anchorName: nil,
      anchorID: nil,
      anchorAvatarURL: nil,
      anchorProfileURL: nil,
      title: "Sezoel的小红书直播间",
      pageURL: "https://www.xiaohongshu.com/livestream/570537125314843978",
      roomID: "570537125314843978",
      startedAt: Date(timeIntervalSince1970: 1_762_872_000),
      durationSeconds: 100
    )
    let title = LocalImportController.liveRecordingTitle(payload, fileName: "Sezoel的小红书直播间_2026-11-11_23-44-17.mp4")
    XCTAssertTrue(title.hasPrefix("Sezoel 直播 "), title)
    XCTAssertFalse(title.contains("23-44-17"), title)
    XCTAssertEqual(LocalImportController.liveRecordingNameFromPageTitle("某某的抖音直播间 - 抖音直播"), "某某")
    XCTAssertNil(LocalImportController.liveRecordingNameFromPageTitle("  "))
  }

  func testLiveRecordingPageTitleSkipsPlatformTemplates() {
    XCTAssertNil(LocalImportController.liveRecordingPageTitle(
      "某某的抖音直播间 - 抖音直播", platform: .douyin
    ))
    XCTAssertNil(LocalImportController.liveRecordingPageTitle(
      "某某的小红书直播间", platform: .xiaohongshu
    ))
    XCTAssertNil(LocalImportController.liveRecordingPageTitle(
      "抖音直播", platform: .douyin
    ))
    XCTAssertEqual(
      LocalImportController.liveRecordingPageTitle("今晚聊聊内容 - 抖音直播", platform: .douyin),
      "今晚聊聊内容"
    )
    XCTAssertEqual(
      LocalImportController.liveRecordingPageTitle("不许叫妈咪", platform: .xiaohongshu),
      "不许叫妈咪"
    )
  }

  func testLiveRecordingCreatorIdentityCanDeriveProfileFromAnchorID() throws {
    let payload = LiveRecordingIngestPayload(
      fileURL: URL(fileURLWithPath: "/tmp/live.mp4"),
      platform: .douyin,
      anchorName: "示例主播",
      anchorID: "SEC_demo",
      anchorAvatarURL: nil,
      anchorProfileURL: nil,
      title: nil,
      pageURL: pageURL,
      roomID: "427518068747",
      startedAt: Date(),
      durationSeconds: nil,
      quality: .origin
    )
    let identity = try XCTUnwrap(LocalImportController.liveRecordingCreatorIdentity(payload))
    XCTAssertEqual(identity.platform, "douyin.com")
    XCTAssertEqual(identity.authorID, "SEC_demo")
    XCTAssertEqual(identity.profileURL, "https://www.douyin.com/user/SEC_demo")
  }

  // MARK: - 第三轮修复：磁盘、下播判定、合并进程与面板状态

  func testDiskStopThresholdReservesRoomForMerge() {
    // 1 GB 是底线。分段变大后阈值必须跟着抬高：收尾后还要写一份同样大的成品。
    XCTAssertEqual(
      LiveRecordingDiskSpace.stopThresholdBytes(recordedBytes: 0),
      LiveRecordingDiskSpace.stopFreeBytes
    )
    let recorded = Int64(3 * 1024 * 1024 * 1024)
    XCTAssertEqual(
      LiveRecordingDiskSpace.stopThresholdBytes(recordedBytes: recorded),
      recorded + LiveRecordingDiskSpace.mergeHeadroomBytes
    )
    XCTAssertEqual(
      LiveRecordingDiskSpace.mergeRequiredBytes(recordedBytes: recorded),
      recorded + LiveRecordingDiskSpace.mergeHeadroomBytes
    )
    XCTAssertGreaterThan(LiveRecordingDiskSpace.mergeHeadroomBytes, 0)
  }

  func testFileSizeSeesGrowthWhenTheSameURLIsReadAgain() throws {
    // 录制进度和「文件不再增长」判定都靠反复读同一个 URL。`URL.resourceValues`
    // 会缓存，读第二次起就是旧值，所以必须走 attributesOfItem。
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: Data())
    XCTAssertEqual(LiveRecordingNaming.fileSize(url), 0)
    try Data(repeating: 7, count: 4096).write(to: url)
    XCTAssertEqual(LiveRecordingNaming.fileSize(url), 4096)
  }

  func testXiaohongshuRoomWithoutStreamURLKeepsRetryingInsteadOfEnding() {
    // 有 roomInfo、还没读到地址、status 仍是 2（直播中）：页面可能没加载完或撞了风控，
    // 必须退避重试，不能当已下播把还在播的直播掐断。
    XCTAssertEqual(
      WebViewLiveRoomFetcher.xiaohongshuVerdict(hasStreamURL: false, status: 2, endedText: false),
      .retry
    )
    XCTAssertEqual(
      WebViewLiveRoomFetcher.xiaohongshuVerdict(hasStreamURL: false, status: nil, endedText: false),
      .retry
    )
    // 只有明确下播证据才收尾。
    XCTAssertEqual(
      WebViewLiveRoomFetcher.xiaohongshuVerdict(hasStreamURL: false, status: nil, endedText: true),
      .ended
    )
    XCTAssertEqual(
      WebViewLiveRoomFetcher.xiaohongshuVerdict(hasStreamURL: false, status: 0, endedText: false),
      .ended
    )
    XCTAssertEqual(
      WebViewLiveRoomFetcher.xiaohongshuVerdict(hasStreamURL: true, status: 2, endedText: false),
      .live
    )
  }

  func testMergeWritesToPartsAndOnlyPromotesCompleteFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let parts = root.appendingPathComponent(".parts").appendingPathComponent("stem")
    try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let partial = LiveRecordingNaming.mergePartialURL(segmentsDirectory: parts, index: 1)
    XCTAssertTrue(partial.path.contains("/.parts/"), "合并临时文件必须留在 .parts 里")
    XCTAssertTrue(partial.lastPathComponent.hasSuffix(".partial.mp4"))

    // 0 字节的半截文件不能变成成品。
    FileManager.default.createFile(atPath: partial.path, contents: Data())
    let finalURL = root.appendingPathComponent("主播_2026-11-11_20-00-00.mp4")
    XCTAssertFalse(LiveRecordingNaming.finalizeMergeOutput(partial: partial, finalURL: finalURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

    // 完整写完才落成正式文件名。
    try Data("merged".utf8).write(to: partial)
    XCTAssertTrue(LiveRecordingNaming.finalizeMergeOutput(partial: partial, finalURL: finalURL))
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
  }

  func testProbeLookupAndMissingProbeWarning() {
    let resources = URL(fileURLWithPath: "/Applications/汲作.app/Contents/Resources")
    let ffmpeg = resources.appendingPathComponent("ffmpeg")
    XCTAssertEqual(
      FFmpegLocator.probeURL(near: ffmpeg) { $0.lastPathComponent == "ffprobe" }?.path,
      resources.appendingPathComponent("ffprobe").path
    )
    XCTAssertNil(FFmpegLocator.probeURL(near: ffmpeg) { _ in false })
    let warning = LiveRecordingController.probeWarning(isProbeAvailable: false, hasActiveRecording: true)
    XCTAssertTrue(warning?.contains("ffprobe") == true)
    XCTAssertNil(LiveRecordingController.probeWarning(isProbeAvailable: true, hasActiveRecording: true))
    XCTAssertNil(LiveRecordingController.probeWarning(isProbeAvailable: false, hasActiveRecording: false))
  }

  func testPanelHidesRemoveWhileIngesting() {
    XCTAssertFalse(LiveRecordingPanelView.showsRemoveButton(phase: .completed, isIngesting: true))
    XCTAssertTrue(LiveRecordingPanelView.showsRemoveButton(phase: .completed, isIngesting: false))
    XCTAssertTrue(LiveRecordingPanelView.showsRemoveButton(phase: .failed("x"), isIngesting: false))
    XCTAssertFalse(LiveRecordingPanelView.showsRemoveButton(phase: .merging, isIngesting: false))
    // 合并失败的记录要能打开分段文件夹；部分成功的也算。
    XCTAssertTrue(LiveRecordingPanelView.showsSegmentsButton(phase: .failed("x"), failureMessage: "x"))
    XCTAssertTrue(LiveRecordingPanelView.showsSegmentsButton(phase: .completed, failureMessage: "剩一组没合并"))
    XCTAssertFalse(LiveRecordingPanelView.showsSegmentsButton(phase: .completed, failureMessage: nil))
    XCTAssertFalse(LiveRecordingPanelView.showsSegmentsButton(phase: .recording, failureMessage: nil))
  }

  // MARK: - 子进程：退出路径与合并 runner 登记

  private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    func add(_ pid: Int32) { lock.withLock { pids.append(pid) } }
    var all: [Int32] { lock.withLock { pids } }
  }

  @MainActor
  private final class EndedFetcher: LiveRoomFetching {
    func fetchRoom(
      platform: LiveRecordingPlatform,
      pageURL: String,
      userAgent: String,
      referer: String
    ) async throws -> DouyinLiveRoom {
      throw LiveRoomFetchError.ended
    }
  }

  func testTerminateDoesNotEscalateToSIGKILLAfterProcessExited() async throws {
    let runner = FFmpegProcessRunner()
    let task = Task {
      try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    }
    let startDeadline = Date().addingTimeInterval(5)
    while !runner.isRunning, Date() < startDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(runner.isRunning, "sleep 应该已经启动")
    runner.terminate()
    let status = try await task.value
    // SIGTERM 让它自己退出（15）；真被 1.5 秒后的 SIGKILL 打到会是 9。
    XCTAssertEqual(status, SIGTERM)
    try await Task.sleep(for: .seconds(1.8))
    XCTAssertFalse(runner.isRunning)
  }

  func testShutdownKillsRegisteredMergeRunnerAndLeavesNoProduct() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 假 ffmpeg：录制参数写一点内容后以 1 退出（驱动重连）；concat 参数挂住等被杀。
    let script = root.appendingPathComponent("fake-ffmpeg")
    try """
    #!/bin/sh
    for last in "$@"; do :; done
    case "$*" in
      *concat*) sleep 60 ;;
      *) printf 'segment-bytes' > "$last"; exit 1 ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let pids = PIDBox()
    let preferences = LiveRecordingPreferences(
      defaults: UserDefaults(suiteName: "live-recording-shutdown-\(UUID().uuidString)")!,
      applicationSupportRoot: root
    )
    let controller = LiveRecordingController(
      preferences: preferences,
      ffmpegURL: script,
      fetcher: EndedFetcher(),
      makeRunner: {
        let runner = FFmpegProcessRunner()
        runner.onLaunch = { pids.add($0) }
        return runner
      }
    )
    let request = LiveRecordingRequest(
      requestId: "req-merge",
      createdAt: "2026-11-11T12:00:00Z",
      platform: .douyin,
      pageURL: pageURL,
      roomID: "427518068747",
      quality: .origin,
      variants: [
        LiveStreamVariant(
          quality: .origin,
          container: .hls,
          url: "https://pull.example.test/a.m3u8?sign=1"
        )
      ]
    )
    guard case .accepted = controller.start(request) else {
      return XCTFail("应受理录制")
    }
    // 第一个进程是录制，第二个是合并：等到合并起来再验证退出。
    let deadline = Date().addingTimeInterval(20)
    while pids.all.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(pids.all.count, 2, "合并用的 ffmpeg 没有启动")
    let mergePID = try XCTUnwrap(pids.all.last)
    XCTAssertEqual(kill(mergePID, 0), 0, "合并进程应该在运行")

    let started = Date()
    controller.shutdown()
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "退出必须在有界等待内返回")

    let killDeadline = Date().addingTimeInterval(2)
    for pid in pids.all {
      while kill(pid, 0) == 0, Date() < killDeadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(kill(pid, 0), -1, "退出后不该还留着 ffmpeg 进程 \(pid)")
    }
    // 合并被中途杀掉时，录制目录里不能出现半截 MP4 成品（临时文件只能待在 .parts）。
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.lowercased().hasSuffix(".mp4") }
    XCTAssertTrue(leftovers.isEmpty, "退出后留下了半截 MP4：\(leftovers)")
  }
}
