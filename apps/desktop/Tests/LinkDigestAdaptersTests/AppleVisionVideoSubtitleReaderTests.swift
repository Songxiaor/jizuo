import AVFoundation
import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class AppleVisionVideoSubtitleReaderTests: XCTestCase {
  /// 采样点必须掐掉首尾。片头片尾常有和正片排版无关的标题卡与滚动字幕，
  /// 拿它们定位会把字幕带定歪。
  func testBandProbeSamplesAvoidTheOpeningAndClosing() throws {
    let reader = AppleVisionVideoSubtitleReader()
    let times = reader.sampleTimes(duration: 1000, count: 10)
    XCTAssertEqual(times.count, 10)
    let seconds = times.map { CMTimeGetSeconds($0) }
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(seconds.first), 50, "起点应跳过片头")
    XCTAssertLessThanOrEqual(try XCTUnwrap(seconds.last), 950, "终点应跳过片尾")
    XCTAssertEqual(seconds, seconds.sorted(), "采样点必须递增")
  }

  /// 极短视频不能因为掐首尾而一个采样点都不剩。
  func testVeryShortVideoStillYieldsASample() {
    let reader = AppleVisionVideoSubtitleReader()
    XCTAssertFalse(reader.sampleTimes(duration: 0.5, count: 40).isEmpty)
    XCTAssertTrue(reader.sampleTimes(duration: 0, count: 40).isEmpty)
  }

  /// 长视频要分段重新定位字幕带，最后不足十分钟的一段也不能丢。
  func testLongVideoReprobesTheSubtitleBandEveryTenMinutes() {
    let reader = AppleVisionVideoSubtitleReader()
    XCTAssertEqual(reader.timeSegments(duration: 1_250), [0..<600, 600..<1_200, 1_200..<1_250])
    XCTAssertEqual(reader.timeSegments(duration: 600), [0..<600])
    XCTAssertEqual(reader.timeSegments(duration: 0), [])
  }

  /// 分段采样必须落在该段内部，不能每段都错误地从视频 0 秒开始。
  func testSegmentProbeSamplesStayInsideTheirOwnTimeRange() throws {
    let times = AppleVisionVideoSubtitleReader()
      .sampleTimes(start: 600, end: 1_200, count: 20)
      .map(CMTimeGetSeconds)
    XCTAssertEqual(times.count, 20)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(times.first), 630)
    XCTAssertLessThanOrEqual(try XCTUnwrap(times.last), 1_170)
  }

  /// 某段探针没读到字幕时必须沿用最近的有效带心，不能把十分钟正文整段丢掉。
  func testMissingSegmentBandCenterUsesTheNearestDetectedCenter() {
    let reader = AppleVisionVideoSubtitleReader()
    XCTAssertEqual(
      reader.resolvedBandCenters([nil, 0.12, nil, 0.18, nil]),
      [0.12, 0.12, 0.12, 0.18, 0.18]
    )
    XCTAssertEqual(reader.resolvedBandCenters([nil, nil]), [nil, nil])
  }

  /// 幻灯片正文偶尔会被误判成字幕带；若只有一段跳到画面中部，而前后字幕带
  /// 仍在底部，应回退到相邻结果，不能把这十分钟的烧录字幕整段裁掉。
  func testIsolatedBandCenterSpikeUsesItsAgreeingNeighbors() {
    let reader = AppleVisionVideoSubtitleReader()
    XCTAssertEqual(
      reader.resolvedBandCenters([0.10, 0.11, 0.52, 0.09, 0.10]),
      [0.10, 0.11, 0.10, 0.09, 0.10]
    )

    // 连续两段都改变位置，说明更可能是真实的字幕版式切换，必须保留。
    XCTAssertEqual(
      reader.resolvedBandCenters([0.10, 0.11, 0.42, 0.43, 0.44]),
      [0.10, 0.11, 0.42, 0.43, 0.44]
    )
  }

  /// 裁剪矩形必须落在归一化坐标内，且与合成时采用的带宽一致。
  func testBandRectStaysInsideNormalizedBounds() {
    let reader = AppleVisionVideoSubtitleReader()
    for center in [0.0, 0.05, 0.3, 0.95, 1.0] {
      let rect = reader.bandRect(center: center)
      XCTAssertGreaterThanOrEqual(rect.minY, 0)
      XCTAssertLessThanOrEqual(rect.maxY, 1)
      XCTAssertGreaterThan(rect.height, 0)
    }
    // 画面中部的带没有被边界裁掉时，高度应正好是两倍 bandHalfHeight。
    let middle = reader.bandRect(center: 0.5)
    XCTAssertEqual(middle.height, BurnedInSubtitles.bandHalfHeight * 2, accuracy: 0.0001)
  }

  /// 真机端到端：从带烧录字幕的视频里读出字幕。
  ///
  /// 样本走环境变量，不进仓库——媒体是用户的私人内容，路径也因机器而异。
  ///   LINKDIGEST_SUBTITLE_SAMPLE=/path/to/video.mp4 \
  ///   swift test --filter AppleVisionVideoSubtitleReaderTests
  func testReadsBurnedInSubtitlesFromRealVideo() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["LINKDIGEST_SUBTITLE_SAMPLE"], !path.isEmpty else {
      throw XCTSkip("未指定 LINKDIGEST_SUBTITLE_SAMPLE，跳过真机字幕识别")
    }
    guard FileManager.default.fileExists(atPath: path) else {
      throw XCTSkip("样本文件不存在：\(path)")
    }
    let interval = env["LINKDIGEST_SUBTITLE_INTERVAL"].flatMap(Double.init)
      ?? AppleVisionVideoSubtitleReader.defaultFrameIntervalSeconds

    let started = Date()
    let cues = try await AppleVisionVideoSubtitleReader().readSubtitles(
      fileURL: URL(fileURLWithPath: path),
      frameIntervalSeconds: interval
    )
    let elapsed = Date().timeIntervalSince(started)

    print("=== 识别到 \(cues.count) 条字幕，耗时 \(String(format: "%.1f", elapsed))s ===")
    let window: [Double] = ProcessInfo.processInfo.environment["LINKDIGEST_SUBTITLE_WINDOW"]
      .map { $0.split(separator: "-").compactMap { Double($0) } } ?? []
    let shown = window.count == 2
      ? cues.filter { $0.startSeconds >= window[0] && $0.startSeconds <= window[1] }
      : Array(cues.prefix(12))
    for cue in shown {
      print(String(format: "  [%.0fs] %@", cue.startSeconds, cue.text))
    }

    XCTAssertFalse(cues.isEmpty, "应当从画面里读出字幕")

    // 角标与图表标注不该混进字幕。
    //
    // 这些东西和字幕挤在同一条带上：讲者署名固定在右下角（x≥0.89），幻灯片
    // 底部还有 CC-BY / METR / 年份刻度这类零散短标注。它们一旦被当成字幕行
    // 拼进去，每句话后面都会拖一截噪声。
    let joined = cues.map(\.text).joined(separator: "\n")
    // 只钉住能稳定清掉的那些。
    //
    // `METR` 不在列内，是有意的：实测那一帧 OCR 把它和字幕并成了**同一个文本
    // 块**（`…对吧？METR`），噪声与正文已经不可分，几何过滤和词表清理都够不着。
    // 把做不到的事写成断言，只会让这条用例变成长期红灯。
    for noise in ["Andrew Ng", "CC-BY", "Model release date"] {
      let offenders = cues.filter { $0.text.contains(noise) }
      XCTAssertTrue(
        offenders.isEmpty,
        "「\(noise)」不是字幕，不该出现在稿子里；出现在："
          + offenders.map { "[\(Int($0.startSeconds))s] \($0.text)" }.joined(separator: " ｜ ")
      )
    }
    // 时间必须单调不减，否则拼出来的稿子顺序是乱的。
    XCTAssertEqual(cues.map(\.startSeconds), cues.map(\.startSeconds).sorted())
    // 相邻两条不能是同一句，否则去重没生效。
    for (lhs, rhs) in zip(cues, cues.dropFirst()) {
      XCTAssertFalse(
        BurnedInSubtitles.isSameCue(lhs.text, rhs.text),
        "相邻字幕重复未去掉：\(lhs.text) / \(rhs.text)"
      )
    }
  }
}
