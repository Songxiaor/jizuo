import Foundation
import CoreMedia

/// 转写稿的一个段落，连同它在媒体里的位置。
///
/// 毫秒而不是秒：数据库里存整数，排序和相等判断都不用担心浮点漂移；跳转时再
/// 换算回 `CMTime`。
public struct TranscriptParagraph: Sendable, Equatable, Hashable {
  public let startMilliseconds: Int
  public let endMilliseconds: Int
  public let text: String

  public init(startMilliseconds: Int, endMilliseconds: Int, text: String) {
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = text
  }

  /// `03:12` / `1:04:09`。超过一小时才显示小时位——绝大多数条目是几分钟的短片，
  /// 一律补 `00:` 只是让每一行都变长。
  public var startLabel: String {
    let total = max(0, startMilliseconds / 1000)
    let seconds = total % 60, minutes = (total / 60) % 60, hours = total / 3600
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%02d:%02d", minutes, seconds)
  }
}

/// Reconciles Apple's finalized and volatile timed results. Volatile segments
/// may be replaced or revoked; only finalized segments are eligible to persist.
public struct TimedTranscriptionAccumulator: Sendable, Equatable {
  private struct Segment: Sendable, Equatable {
    let range: CMTimeRange
    let text: String
  }
  private var finalized: [Segment] = []
  private var volatile: [Segment] = []

  public init() {}

  @discardableResult
  public mutating func apply(range: CMTimeRange, text: String, isFinal: Bool) -> String {
    merge(range: range, text: text, isFinal: isFinal)
    return displayText
  }

  /// 与 `apply` 同一套合并逻辑，但不重算全文。流式识别每秒推送几十条
  /// volatile 结果，逐条全量重排是 UI 卡顿源；调用方节流后再取 `displayText`。
  public mutating func merge(range: CMTimeRange, text: String, isFinal: Bool) {
    let segment = Segment(range: range, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    volatile.removeAll { Self.overlaps($0.range, range) }
    if isFinal {
      finalized.removeAll { Self.overlaps($0.range, range) }
      if !segment.text.isEmpty { finalized.append(segment) }
    } else if !segment.text.isEmpty {
      volatile.append(segment)
    }
  }

  public var displayText: String { Self.text(from: finalized + volatile) }
  public var finalText: String { Self.text(from: finalized) }

  /// A silence at least this long reads as the speaker starting a new thought.
  public static let paragraphPauseSeconds: Double = 0.65
  /// Continuous speech without a qualifying pause still has to break somewhere,
  /// or a fast talker produces one unreadable wall of text.
  public static let softParagraphCharacterCount = 170

  /// 已定稿的段落，连同它在媒体里的时间位置。
  ///
  /// 时间一直都在——识别结果每条都带 `CMTimeRange`——只是过去在 `text(from:)`
  /// 的出口被丢掉了，落库的只有纯文本。阅读区因此没法把一段话和它在视频里的
  /// 位置对应起来，长转写稿只能靠滚。
  public var finalParagraphs: [TranscriptParagraph] { Self.paragraphs(from: finalized) }

  private static func text(from segments: [Segment]) -> String {
    paragraphs(from: segments).map(\.text).joined(separator: "\n\n")
  }

  private static func paragraphs(from segments: [Segment]) -> [TranscriptParagraph] {
    let ordered = segments.sorted {
      let left = CMTimeGetSeconds($0.range.start), right = CMTimeGetSeconds($1.range.start)
      if left == right { return CMTimeGetSeconds($0.range.duration) < CMTimeGetSeconds($1.range.duration) }
      return left < right
    }

    var paragraphs: [TranscriptParagraph] = []
    var current = ""
    var currentStart: Double?
    var currentEnd: Double?
    var previousEnd: Double?
    /// 一个段落收尾：把文本按长度切开，切出来的子段共享父段的时间。
    ///
    /// 子段没有自己的时间是**事实**，不是偷懒——它们是同一段连续语音按字数
    /// 硬切出来的，按字符比例插值只会造出一个看着精确、实际对不上的时间。
    /// 点子段跳到该段落开头，是这里唯一诚实的行为。
    func flush() {
      guard !current.isEmpty else { return }
      let start = milliseconds(currentStart)
      let end = milliseconds(currentEnd)
      for piece in splitLongParagraph(current) {
        paragraphs.append(TranscriptParagraph(startMilliseconds: start, endMilliseconds: end, text: piece))
      }
      current = ""
      currentStart = nil
      currentEnd = nil
    }
    for segment in ordered {
      let start = CMTimeGetSeconds(segment.range.start)
      let end = CMTimeGetSeconds(CMTimeRangeGetEnd(segment.range))
      if let previousEnd, start.isFinite, previousEnd.isFinite,
         start - previousEnd >= paragraphPauseSeconds, !current.isEmpty,
         !isNumberSeam(current.last, segment.text.first) {
        flush()
      }
      if current.isEmpty, start.isFinite { currentStart = start }
      if end.isFinite { currentEnd = end }
      current = joined(current, segment.text)
      previousEnd = end.isFinite ? end : previousEnd
    }
    flush()
    return paragraphs
  }

  /// 秒转毫秒。非有限值（识别结果偶尔给 NaN/∞）落到 0，而不是把 NaN 一路带进
  /// 数据库——那会让排序和跳转都变成未定义行为。
  private static func milliseconds(_ seconds: Double?) -> Int {
    guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
    return Int((seconds * 1000).rounded())
  }

  /// CJK runs together; Latin needs the space that the segment boundary ate.
  private static func joined(_ left: String, _ right: String) -> String {
    guard !left.isEmpty else { return right }
    guard !right.isEmpty else { return left }
    let needsSpace = !isCJK(left.last!) && !isCJK(right.first!)
      && !isNumberSeam(left.last, right.first)
    return left + (needsSpace ? " " : "") + right
  }

  /// “9.7” read aloud often arrives split across results as “9” + “.7” (or with
  /// the decimal mis-punctuated as “。”). A pause break, length split, or joiner
  /// space at that seam rips the number apart, so paragraphing must never
  /// separate a digit from an adjacent digit or decimal point.
  private static func isNumberSeam(_ left: Character?, _ right: Character?) -> Bool {
    guard let left, let right else { return false }
    let decimalPoints: Set<Character> = [".", "。"]
    if left.isNumber { return right.isNumber || decimalPoints.contains(right) }
    if decimalPoints.contains(left) { return right.isNumber }
    return false
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (0x3000...0x303F).contains(scalar.value)      // CJK punctuation
        || (0x4E00...0x9FFF).contains(scalar.value) // unified ideographs
        || (0xFF00...0xFFEF).contains(scalar.value) // fullwidth forms
    }
  }

  /// Breaks an over-long paragraph at sentence terminators. If it has none, it
  /// is left intact rather than cut mid-sentence at an arbitrary offset.
  private static func splitLongParagraph(_ paragraph: String) -> [String] {
    guard paragraph.count > softParagraphCharacterCount else { return [paragraph] }
    let terminators: Set<Character> = ["。", "！", "？", "…", ".", "!", "?"]
    // 中文 ASR 经常整段只有逗号；没有句末标点时也必须能断段，
    // 否则快语速口播会产出一面无法阅读的文字墙。
    let softTerminators: Set<Character> = ["，", "、", "；", "：", ",", ";"]
    var result: [String] = []
    var buffer = ""
    let characters = Array(paragraph)
    for (index, character) in characters.enumerated() {
      buffer.append(character)
      // “9.7”/“9。7”: the dot is a decimal seam, not a sentence end.
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      if isNumberSeam(character, next) { continue }
      if terminators.contains(character), buffer.count >= softParagraphCharacterCount {
        result.append(buffer)
        buffer = ""
      } else if softTerminators.contains(character), buffer.count >= softParagraphCharacterCount * 2 {
        result.append(buffer)
        buffer = ""
      }
    }
    if !buffer.isEmpty { result.append(buffer) }
    return result
  }

  private static func overlaps(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
    let lhsStart = CMTimeGetSeconds(lhs.start), rhsStart = CMTimeGetSeconds(rhs.start)
    let lhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(lhs)), rhsEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(rhs))
    guard lhsStart.isFinite, rhsStart.isFinite, lhsEnd.isFinite, rhsEnd.isFinite else { return false }
    if lhsStart == lhsEnd || rhsStart == rhsEnd { return lhsStart == rhsStart }
    return max(lhsStart, rhsStart) < min(lhsEnd, rhsEnd)
  }
}

/// Readiness of the on-device speech model for one locale. Checking this value
/// never downloads model assets; installation is a separate, user-confirmed action.
public enum LocalSpeechModelState: Sendable, Equatable {
  case ready
  case requiresDownload
  case unavailable(LocalVideoTranscriptionError)
}

/// Observable handoffs from local video processing. The adapter reports phases
/// before recognition so UI can distinguish model, media, and speech failures.
public enum LocalVideoTranscriptionEvent: Sendable, Equatable {
  case extractingAudio
  case transcribing
  case partial(String)
  case final(String)
  /// 定稿文本的分段时间，紧跟在 `.final` 之后发出。
  ///
  /// 单独一个事件而不是塞进 `.final`：只有本机识别拿得到逐段时间，在线转写
  /// 现在要的是整段 JSON（`response_format: "json"`），没有分段。让它成为可选的
  /// 一步，两条来源就都不用假装自己有时间。
  case finalParagraphs([TranscriptParagraph])
}

public enum LocalVideoTranscriptionError: Error, Sendable, Equatable {
  case unsupportedOS
  case speechUnavailable
  case chineseLocaleUnavailable
  case modelDownloadFailed
  case invalidLocalFile
  case noAudioTrack
  case audioExtractionFailed
  case recognitionFailed
  case emptyTranscript
  case mediaTooLong
  case cancelled

  public var userMessage: String {
    switch self {
    case .unsupportedOS: "本机系统版本不支持 Apple 本机转写；需要 macOS 26 或更高版本。"
    case .speechUnavailable: "这台 Mac 当前无法使用 Apple 本机语音识别。"
    case .chineseLocaleUnavailable: "Apple 本机语音识别当前不支持简体中文（zh_CN）。"
    case .modelDownloadFailed: "无法准备 Apple 中文离线模型。请检查网络和磁盘空间后重试。"
    case .invalidLocalFile: "找不到可读取的本机 MP4 或 MOV 视频。"
    case .noAudioTrack: "这个视频没有可转写的音轨。"
    case .audioExtractionFailed: "无法从视频中提取音频；原视频没有被改动。"
    case .recognitionFailed: "本机语音识别未完成，请重试。音频没有上传。"
    case .emptyTranscript: "没有识别到可保存的中文内容，请确认视频中有人声后重试。"
    case .mediaTooLong: "视频超过 120 分钟上限，当前不能进行本机转写。"
    case .cancelled: "已取消本机转写。"
    }
  }
}

/// SQLite-owned attempt for transcription that starts from a transient V2
/// direct-file descriptor rather than a durable `media_assets` row.
public struct TaskTranscriptionAttemptToken: Codable, Sendable, Equatable, Hashable {
  public let id: String
  public let taskID: TaskID
  public let generation: Int64

  public init(
    id: String = UUID().uuidString.lowercased(),
    taskID: TaskID,
    generation: Int64
  ) {
    self.id = id
    self.taskID = taskID
    self.generation = generation
  }
}

public enum TaskTranscriptionStatusMutation: String, Sendable, Equatable {
  case running
  case cancelled
  case failed
}

public enum CompleteTaskTranscriptionResult: Sendable, Equatable {
  case accepted(AcceptCaptureResult)
  case replay(AcceptCaptureResult)
  case stale
}

public protocol LocalVideoTranscribing: Sendable {
  /// Pure readiness probe. Must not install or download assets.
  func modelState(localeIdentifier: String) async -> LocalSpeechModelState
  /// Called only after an explicit user confirmation.
  func downloadModel(localeIdentifier: String) async throws
  /// Audio extraction and recognition remain local and are cancellation-aware.
  func transcribe(
    fileURL: URL,
    workspaceURL: URL,
    localeIdentifier: String
  ) -> AsyncThrowingStream<LocalVideoTranscriptionEvent, Error>
}
