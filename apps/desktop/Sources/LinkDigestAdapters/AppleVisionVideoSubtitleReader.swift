import AVFoundation
import Foundation
import LinkDigestCore
import Vision

/// 从视频画面里读出**烧录字幕**（压进画面、没有独立字幕轨的那种）。
///
/// 为什么这条路值得走：中文博主搬运英文视频时几乎必带烧录字幕，而那份字幕
/// 通常是**人工翻译**的——比 ASR 加机翻准得多，还省掉翻译这一步。实测一段
/// 斯坦福讲座，画面里的中文字幕干净完整，而同一段音频用错 locale 的听写是
/// 一堆音节碎片。
///
/// 全程本机：AVFoundation 抽帧、Vision 识别，没有任何网络调用。
public struct AppleVisionVideoSubtitleReader: VideoSubtitleReading {
  /// 抽帧间隔。
  ///
  /// 3 秒是实测出来的拐点，不是拍的：同一段 10 分钟片段，2 秒抽出 106 条用
  /// 32.1s，3 秒同样 106 条只要 24.6s，4 秒就掉到 99 条——开始整句漏。
  /// 一句字幕实际平均停留约 5.6 秒（600 秒出 106 条），2 秒的密度纯属浪费。
  public static let defaultFrameIntervalSeconds: Double = 3

  /// 每个时间段定位字幕带用的采样帧数。
  ///
  /// 不能再拿 40 帧覆盖整部长视频：105 分钟实测里，后半程的版式把全局带心
  /// 拉偏，开头双行字幕被裁掉上沿，原本清楚的句子变成三条乱码。每 10 分钟
  /// 重新定位一次，20 帧足够覆盖这个时间段，又不会把探测成本放大太多。
  static let bandProbeFrameCount = 20

  /// 字幕版式最多沿用这么久，之后重新定位。
  static let bandReprobeIntervalSeconds: Double = 10 * 60

  /// 单个时间段的带心若比前后两段都跳开这么多，就把它视为误判。
  ///
  /// 字幕从单行变双行时，带心通常只移动约 0.04；而幻灯片正文抢到候选时，
  /// 带心会从画面底部直接跳到中部。0.12 既容得下正常排版变化，也足以识别
  /// 这种会让 ±0.08 裁剪框完全离开字幕的孤立尖峰。
  static let maximumIsolatedBandCenterJump = BurnedInSubtitles.bandHalfHeight * 1.5

  public init() {}

  /// 协议要求的入口。抽帧间隔不进协议——那是这个实现的调参，换个引擎未必有
  /// 「帧」这个概念。
  public func readSubtitles(
    fileURL: URL,
    languages: [String],
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [BurnedInSubtitleCue] {
    try await readSubtitles(
      fileURL: fileURL,
      languages: languages,
      frameIntervalSeconds: Self.defaultFrameIntervalSeconds,
      progress: progress
    )
  }

  public func readSubtitles(
    fileURL: URL,
    languages: [String] = ["zh-Hans", "en-US"],
    frameIntervalSeconds: Double = defaultFrameIntervalSeconds,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> [BurnedInSubtitleCue] {
    guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
      throw LocalVideoTranscriptionError.invalidLocalFile
    }
    let asset = AVURLAsset(url: fileURL)
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    guard duration.isFinite, duration > 0 else {
      throw LocalVideoTranscriptionError.invalidLocalFile
    }
    guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
      throw LocalVideoTranscriptionError.invalidLocalFile
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // 容差放宽到半个抽帧间隔：要求精确到帧会让 generator 为每个时间点做一次
    // 精确 seek，慢上一个数量级，而字幕停留好几秒，差半秒完全不影响判读。
    let tolerance = CMTime(seconds: frameIntervalSeconds / 2, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    // 每个时间段先稀疏定位，再密集抽帧。
    //
    // 裁剪不是为了省时间，是为了**准**：字幕只占画面 16%，整帧送进 Vision 时
    // 满屏图表会把小字的识别精度带下去。实测同一帧，裁剪后得到「衡量的标准是
    // 完成该任务人类需要多长时间」，整帧却是「復量的标准…盘要多长时何」。
    //
    // 之前一度以为问题出在裁剪，其实是带心算偏了——带宽只有 ±0.08，双行字幕
    // 的上行被切掉半截，喂进去的字本身就是残的。带宽因此放宽到能容下双行。
    var allTimes: [CMTime] = []
    var t = 0.0
    while t < duration {
      allTimes.append(CMTime(seconds: t, preferredTimescale: 600))
      t += frameIntervalSeconds
    }
    let segments = timeSegments(duration: duration)
    var detectedCenters: [Double?] = []
    for segment in segments {
      try Task.checkCancellation()
      let probeTimes = sampleTimes(
        start: segment.lowerBound,
        end: segment.upperBound,
        count: Self.bandProbeFrameCount
      )
      let probeFrames = try await recognize(
        times: probeTimes,
        generator: generator,
        languages: languages,
        cropToBand: nil,
        progress: nil
      )
      detectedCenters.append(BurnedInSubtitles.subtitleBandCenter(in: probeFrames))
    }
    let centers = resolvedBandCenters(detectedCenters)
    guard centers.contains(where: { $0 != nil }) else { return [] }

    var frames: [VideoFrameText] = []
    var completedDenseFrames = 0
    for (segment, center) in zip(segments, centers) {
      let segmentTimes = allTimes.filter {
        let seconds = CMTimeGetSeconds($0)
        return seconds >= segment.lowerBound && seconds < segment.upperBound
      }
      guard let center else {
        // 上面的 guard 已排除「整片都没有中心」，这里只保留防御分支，避免未来
        // 中心解析规则变化后进度永远到不了终点。
        completedDenseFrames += segmentTimes.count
        progress?(completedDenseFrames, allTimes.count)
        continue
      }
      let segmentFrames = try await recognize(
        times: segmentTimes,
        generator: generator,
        languages: languages,
        cropToBand: bandRect(center: center),
        progress: progress,
        progressOffset: completedDenseFrames,
        progressTotal: allTimes.count
      )
      frames.append(contentsOf: segmentFrames)
      completedDenseFrames += segmentTimes.count
    }
    // 所有时间段都没有字幕才返回空；调用方据此正常回落到听写。
    return BurnedInSubtitles.compose(frames: frames)
  }

  /// 某个十分钟段的探针恰好全落在转场或无字幕画面时，不能把整段正文跳过。
  /// 优先沿用前一段的有效带心；片头没有中心时再从后面的第一段向前补。
  func resolvedBandCenters(_ detected: [Double?]) -> [Double?] {
    var resolved = detected
    var carried: Double?
    for index in resolved.indices {
      if let center = resolved[index] {
        carried = center
      } else if let carried {
        resolved[index] = carried
      }
    }
    carried = nil
    for index in resolved.indices.reversed() {
      if let center = resolved[index] {
        carried = center
      } else if let carried {
        resolved[index] = carried
      }
    }

    // 幻灯片上的大段文字也可能横跨画面，而且每页都在变化；只看当前十分钟
    // 的变化频率时，它偶尔会赢过底部字幕。真实字幕版式不会只在一个时间段
    // 跳到画面中部、下一段又立刻跳回来，所以用前后段的一致性消掉这种孤立
    // 尖峰。连续变化则保留，避免误伤视频中真正的字幕位置切换。
    let filled = resolved
    guard filled.count >= 3 else { return resolved }
    for index in 1..<(filled.count - 1) {
      guard
        let previous = filled[index - 1],
        let current = filled[index],
        let next = filled[index + 1]
      else { continue }
      let threshold = Self.maximumIsolatedBandCenterJump
      let neighborsAgree = abs(previous - next) <= threshold
      let currentJumpsAway = abs(current - previous) > threshold
        && abs(current - next) > threshold
      if neighborsAgree && currentJumpsAway {
        resolved[index] = (previous + next) / 2
      }
    }
    return resolved
  }

  /// 均匀取 `count` 个时间点，用于定位字幕带。
  ///
  /// 掐掉首尾各 5%：片头片尾常有和正片排版无关的标题卡与字幕滚动，拿它们
  /// 定位会把字幕带定歪。
  func sampleTimes(duration: Double, count: Int) -> [CMTime] {
    sampleTimes(start: 0, end: duration, count: count)
  }

  /// 在一个时间段里均匀采样，仍掐掉该段首尾各 5%。
  func sampleTimes(start: Double, end: Double, count: Int) -> [CMTime] {
    let duration = end - start
    guard count > 0, duration > 0 else { return [] }
    let probeStart = start + duration * 0.05
    let probeEnd = start + duration * 0.95
    guard probeEnd > probeStart else {
      return [CMTime(seconds: start + duration / 2, preferredTimescale: 600)]
    }
    let step = (probeEnd - probeStart) / Double(max(1, count - 1))
    return (0..<count).map {
      CMTime(seconds: probeStart + Double($0) * step, preferredTimescale: 600)
    }
  }

  /// 把长视频切成需要各自重新定位字幕带的时间段。
  func timeSegments(duration: Double) -> [Range<Double>] {
    guard duration > 0 else { return [] }
    var segments: [Range<Double>] = []
    var start = 0.0
    while start < duration {
      let end = min(duration, start + Self.bandReprobeIntervalSeconds)
      segments.append(start..<end)
      start = end
    }
    return segments
  }

  /// 字幕带在归一化坐标里的矩形。Vision 的 y 轴 0 在底边。
  func bandRect(center: Double) -> CGRect {
    let half = BurnedInSubtitles.bandHalfHeight
    let minY = max(0, center - half)
    let maxY = min(1, center + half)
    return CGRect(x: 0, y: minY, width: 1, height: max(0.01, maxY - minY))
  }

  /// 一帧解码结果。CGImage 本身不可变、跨线程读是安全的，但它没有标注
  /// Sendable，要送进 TaskGroup 就得在这里显式担保。
  private struct DecodedFrame: @unchecked Sendable {
    let time: CMTime
    let image: CGImage
  }

  /// 同时跑多少个识别。OCR 是纯 CPU 活，并发数贴着性能核数走；再高只会让
  /// 各路互相抢核，还把内存里同时存在的解码帧数量翻上去。
  static let recognitionConcurrency = 6

  /// 进度最多回调这么多次。
  ///
  /// **这是卡顿的正解，不是省事**：`@Published` 每换一次值，整个窗口树都要
  /// 重求值。3151 帧逐帧回调，等于往主线程扔三千个小任务，列表滚动立刻开始
  /// 顿——项目里实时转写那条早就踩过同一个坑，注释写着「照 favicon 的合批
  /// 手法」。这里在**源头**限流：调用方再怎么写也不会收到三千次回调。
  static let progressReportCap = 50

  /// 识别精度只能用 `.accurate`。
  ///
  /// 实测 `.fast` 快 5.7 倍（同一段 10 分钟片段 6.4s vs 36.5s），但中文烧录字幕
  /// 一条都读不对——出来的是 `i*TYy trtanford`、`2020 72 24` 这种垃圾。
  /// 快而全错没有任何价值，这条路是死的，别再试。
  static let recognitionLevel: VNRequestTextRecognitionLevel = .accurate

  private func recognize(
    times: [CMTime],
    generator: AVAssetImageGenerator,
    languages: [String],
    cropToBand band: CGRect?,
    progress: (@Sendable (Int, Int) -> Void)?,
    progressOffset: Int = 0,
    progressTotal: Int? = nil
  ) async throws -> [VideoFrameText] {
    let total = times.count
    guard total > 0 else { return [] }
    let displayedTotal = progressTotal ?? total
    let reportEvery = max(1, displayedTotal / Self.progressReportCap)
    var frames: [VideoFrameText] = []
    var done = 0
    var lastReported = 0
    var index = 0

    while index < total {
      try Task.checkCancellation()
      // 解码串行：AVAssetImageGenerator 不保证线程安全，而且顺序 seek 比乱序
      // 快得多。真正吃 CPU 的是后面的识别，那一段才并发。
      var batch: [DecodedFrame] = []
      let end = min(index + Self.recognitionConcurrency, total)
      for position in index..<end {
        // 单帧取不出来（seek 落在损坏区、或恰好是片尾）不该中断整片。
        guard let image = try? generator.copyCGImage(at: times[position], actualTime: nil) else { continue }
        batch.append(DecodedFrame(time: times[position], image: image))
      }
      done += end - index
      index = end

      let recognized = await withTaskGroup(of: VideoFrameText?.self) { group in
        for frame in batch {
          group.addTask {
            Self.recognizeFrame(frame, languages: languages, band: band)
          }
        }
        var collected: [VideoFrameText] = []
        for await result in group {
          if let result { collected.append(result) }
        }
        return collected
      }
      frames.append(contentsOf: recognized)

      if done - lastReported >= reportEvery || done == total {
        lastReported = done
        progress?(progressOffset + done, displayedTotal)
      }
    }
    // 并发回来的顺序不保证，而合成依赖时间顺序。
    return frames.sorted { $0.timeSeconds < $1.timeSeconds }
  }

  /// 按归一化的字幕带裁出那一条。
  ///
  /// Vision 的 y 轴 0 在底边，CGImage 的 0 在顶边，换算时要翻过来。
  static func cropped(_ image: CGImage, to band: CGRect) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let rect = CGRect(
      x: 0, y: (1 - band.maxY) * height, width: width, height: band.height * height
    ).integral
    guard let piece = image.cropping(to: rect), piece.height > 0 else { return nil }
    return piece
  }

  private static func recognizeFrame(
    _ frame: DecodedFrame,
    languages: [String],
    band: CGRect?
  ) -> VideoFrameText? {
    // 先把字幕带裁出来，再送去识别。
    //
    // 用 `regionOfInterest` 也能限定识别范围，但整帧仍要走一遍 Vision 的预处理；
    // 字幕带只占画面 16% 的高度，先裁掉其余部分能少喂它八成像素。
    // `cropping(to:)` 只是换个视窗，不复制像素数据，本身几乎不花时间。
    var image = frame.image
    var cropped: CGRect?
    if let band, let piece = Self.cropped(frame.image, to: band) {
      image = piece
      cropped = .zero
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = Self.recognitionLevel
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    // 已经裁过就不再设 regionOfInterest：那会在裁剪图上再裁一次。
    if cropped == nil, let band {
      request.regionOfInterest = band
    }
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return nil
    }
    let lines: [RecognizedTextLine] = (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      // regionOfInterest 会把 boundingBox 表达成**相对裁剪区**的坐标；换算回
      // 整帧坐标，否则第二阶段算出的 y 和第一阶段不是一个尺度，合成时排序全乱。
      let box = observation.boundingBox
      let midY: Double
      let minX: Double
      if let band {
        // 无论走裁剪还是 regionOfInterest，boundingBox 都是**相对那一小块**的，
        // 必须换算回整帧坐标；否则两个阶段算出的 y 不在一个尺度上，合成时排序全乱。
        midY = Double(band.minY + box.midY * band.height)
        minX = Double(box.minX)
      } else {
        midY = Double(box.midY)
        minX = Double(box.minX)
      }
      // 宽度不用换算：裁剪只切 y 方向，x 始终是整幅宽度。
      return RecognizedTextLine(text: text, midY: midY, minX: minX, width: Double(box.width))
    }
    guard !lines.isEmpty else { return nil }
    return VideoFrameText(timeSeconds: CMTimeGetSeconds(frame.time), lines: lines)
  }
}
