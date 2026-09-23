import Foundation

/// 一段「谁在说」：说话人分离的输出。本机分离只有时间和说话人，在线分离还带文字。
public struct SpeakerSegment: Sendable, Equatable {
  public let startSeconds: Double
  public let endSeconds: Double
  /// 引擎给的原始编号（"S1"、"A"、"speaker_0"……），展示前会统一换成「说话人 N」。
  public let speaker: String
  public let text: String?

  public init(startSeconds: Double, endSeconds: Double, speaker: String, text: String? = nil) {
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.speaker = speaker
    self.text = text
  }
}

/// 带说话人的转写稿（2026-09-23）。
///
/// 正文格式沿用转写稿的「行首时间码」，说话人跟在时间码后面、只在换人时出现：
///
///     00:12 **说话人 1**：先说一下这次的安排……
///
///     00:31 **说话人 2**：好的，我这边……
///
///     00:45 补充一点……            ← 还是说话人 2，不重复标
///
/// 时间码仍在行首，点击跳转照常可用（`MediaSeekLink`）；导出的 Markdown 也是人能读的样子。
public enum SpeakerTranscript {
  public static func defaultName(_ index: Int) -> String { "说话人 \(index)" }

  /// 引擎的原始编号 → 「说话人 1、2……」，按首次出现的先后编号。
  public static func displayNames(for segments: [SpeakerSegment]) -> [String: String] {
    var names: [String: String] = [:]
    for segment in segments.sorted(by: { $0.startSeconds < $1.startSeconds }) where names[segment.speaker] == nil {
      names[segment.speaker] = defaultName(names.count + 1)
    }
    return names
  }

  /// 本机分离：给已有的转写分段各配一个说话人，取与该段时间重叠最多的那位；
  /// 一点都不重叠（识别和分离的边界略有出入）时取时间上最近的那位。
  public static func assignSpeakers(
    to paragraphs: [TranscriptParagraph],
    segments: [SpeakerSegment]
  ) -> [(paragraph: TranscriptParagraph, speaker: String)] {
    guard !segments.isEmpty else { return paragraphs.map { ($0, defaultName(1)) } }
    let names = displayNames(for: segments)
    return paragraphs.map { paragraph in
      let start = Double(paragraph.startMilliseconds) / 1000
      let end = max(start, Double(paragraph.endMilliseconds) / 1000)
      var overlapBySpeaker: [String: Double] = [:]
      for segment in segments {
        let overlap = min(end, segment.endSeconds) - max(start, segment.startSeconds)
        if overlap > 0 { overlapBySpeaker[segment.speaker, default: 0] += overlap }
      }
      let raw = overlapBySpeaker.max { $0.value < $1.value }?.key
        ?? segments.min { distance($0, to: start, end) < distance($1, to: start, end) }!.speaker
      return (paragraph, names[raw] ?? defaultName(1))
    }
  }

  private static func distance(_ segment: SpeakerSegment, to start: Double, _ end: Double) -> Double {
    if segment.endSeconds < start { return start - segment.endSeconds }
    if segment.startSeconds > end { return segment.startSeconds - end }
    return 0
  }

  /// 本机分离的主路径：给带时间的短语各配一个说话人（重叠最多、否则最近），
  /// 再交给 `paragraphs(fromDiarizedSegments:)` 按说话人连成段。
  public static func labelPhrases(_ phrases: [SpeakerSegment], with segments: [SpeakerSegment]) -> [SpeakerSegment] {
    guard !segments.isEmpty else { return phrases }
    return phrases.map { phrase in
      var overlapBySpeaker: [String: Double] = [:]
      for segment in segments {
        let overlap = min(phrase.endSeconds, segment.endSeconds) - max(phrase.startSeconds, segment.startSeconds)
        if overlap > 0 { overlapBySpeaker[segment.speaker, default: 0] += overlap }
      }
      let speaker = overlapBySpeaker.max { $0.value < $1.value }?.key
        ?? segments.min {
          distance($0, to: phrase.startSeconds, phrase.endSeconds) < distance($1, to: phrase.startSeconds, phrase.endSeconds)
        }!.speaker
      return SpeakerSegment(startSeconds: phrase.startSeconds, endSeconds: phrase.endSeconds, speaker: speaker, text: phrase.text)
    }
  }

  /// 在线分离：服务端直接给出「谁、何时、说了什么」。同一人连续、间隔不到 2 秒、
  /// 合起来不太长的片段并成一段，读起来是一句一句的对话，而不是碎成几十行。
  public static func paragraphs(fromDiarizedSegments segments: [SpeakerSegment])
    -> [(paragraph: TranscriptParagraph, speaker: String)]
  {
    let names = displayNames(for: segments)
    var output: [(paragraph: TranscriptParagraph, speaker: String)] = []
    for segment in segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
      let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let speaker = names[segment.speaker] ?? defaultName(1)
      let startMs = Int((max(0, segment.startSeconds) * 1000).rounded())
      let endMs = Int((max(segment.startSeconds, segment.endSeconds) * 1000).rounded())
      if let last = output.last, last.speaker == speaker,
         startMs - last.paragraph.endMilliseconds < 2_000,
         Self.keepsGrowing(last.paragraph.text, adding: text) {
        output[output.count - 1] = (
          TranscriptParagraph(
            startMilliseconds: last.paragraph.startMilliseconds,
            endMilliseconds: endMs,
            text: joined(last.paragraph.text, text)
          ),
          speaker
        )
      } else {
        output.append((TranscriptParagraph(startMilliseconds: startMs, endMilliseconds: endMs, text: text), speaker))
      }
    }
    return reattachingSplitWords(output)
  }

  /// 同一人连续说话时，段落到约 220 字就另起一段；但只在一句话说完处断开。
  /// 原来按字数硬切，实测「…重点是要能做 / 出来适合你的…」断在词中间。
  /// 一直没有句号的长串（口语常见）到 400 字仍强制断开，免得整屏一段。
  static func keepsGrowing(_ current: String, adding next: String) -> Bool {
    let total = current.count + next.count
    if total < 220 { return true }
    let enders: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    let endsSentence = current.trimmingCharacters(in: .whitespaces).last.map(enders.contains) ?? false
    return !endsSentence && total < 400
  }

  /// 换人边界落在一个词中间时（实测「…时间安排。好」/「的，我建议…」），
  /// 上一段句号之后只剩 1–3 个字，基本是下一个人的开头，挪过去。
  static func reattachingSplitWords(
    _ labeled: [(paragraph: TranscriptParagraph, speaker: String)]
  ) -> [(paragraph: TranscriptParagraph, speaker: String)] {
    var output = labeled
    let enders: Set<Character> = ["。", "！", "？", "!", "?", "…"]
    // 句末标点落到了下一个人的开头（实测 15 分钟录音里 3 处「说话人 2：。那但是…」）：
    // 标点属于上一句的结尾，挪回去。先做这一步，下面按句号找尾巴时才找得到。
    let leading: Set<Character> = enders.union(["，", "、", "；", ",", ";"])
    for index in output.indices.dropLast() where output[index].speaker != output[index + 1].speaker {
      let next = output[index + 1].paragraph
      let marks = next.text.prefix(while: { leading.contains($0) || $0 == " " })
      guard !marks.isEmpty else { continue }
      let rest = String(next.text.dropFirst(marks.count))
      guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let current = output[index].paragraph
      output[index].paragraph = TranscriptParagraph(
        startMilliseconds: current.startMilliseconds, endMilliseconds: current.endMilliseconds,
        text: current.text.trimmingCharacters(in: .whitespaces) + marks.trimmingCharacters(in: .whitespaces)
      )
      output[index + 1].paragraph = TranscriptParagraph(
        startMilliseconds: next.startMilliseconds, endMilliseconds: next.endMilliseconds,
        text: rest
      )
    }
    for index in output.indices.dropLast() where output[index].speaker != output[index + 1].speaker {
      let text = output[index].paragraph.text
      guard let cut = text.lastIndex(where: { enders.contains($0) }) else { continue }
      let tail = text[text.index(after: cut)...].trimmingCharacters(in: .whitespaces)
      guard (1...3).contains(tail.count) else { continue }
      let current = output[index].paragraph, next = output[index + 1].paragraph
      output[index].paragraph = TranscriptParagraph(
        startMilliseconds: current.startMilliseconds, endMilliseconds: current.endMilliseconds,
        text: String(text[...cut])
      )
      output[index + 1].paragraph = TranscriptParagraph(
        startMilliseconds: next.startMilliseconds, endMilliseconds: next.endMilliseconds,
        text: tail + next.text
      )
    }
    return output
  }

  /// 落库用：正文（Markdown）和带说话人前缀的分段。
  public static func render(
    _ labeled: [(paragraph: TranscriptParagraph, speaker: String)]
  ) -> (body: String, paragraphs: [TranscriptParagraph]) {
    var lines: [String] = []
    var stored: [TranscriptParagraph] = []
    var previous: String?
    for (paragraph, speaker) in labeled {
      let clock = TimedTranscriptionAccumulator.clock(Double(paragraph.startMilliseconds) / 1000)
      let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if speaker != previous {
        lines.append("\(clock) **\(speaker)**：\(text)")
      } else {
        lines.append("\(clock) \(text)")
      }
      stored.append(TranscriptParagraph(
        startMilliseconds: paragraph.startMilliseconds,
        endMilliseconds: paragraph.endMilliseconds,
        text: "\(speaker)：\(text)"
      ))
      previous = speaker
    }
    return (lines.joined(separator: "\n\n"), stored)
  }

  /// 正文里出现过的说话人名，按首次出现的顺序。
  public static func speakers(in body: String) -> [String] {
    var seen: [String] = []
    for line in body.components(separatedBy: "\n") {
      guard let name = speakerLabel(in: line), !seen.contains(name) else { continue }
      seen.append(name)
    }
    return seen
  }

  /// 这份转写稿是不是已经分过说话人。
  public static func isDiarized(_ body: String) -> Bool { !speakers(in: body).isEmpty }

  /// 改名：正文里的 `**旧名**：` 和分段里的 `旧名：` 一起换掉。
  public static func renaming(_ old: String, to new: String, in body: String) -> String {
    let cleaned = new.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "")
    guard !cleaned.isEmpty, cleaned != old else { return body }
    return body.replacingOccurrences(of: "**\(old)**：", with: "**\(cleaned)**：")
  }

  public static func renaming(_ old: String, to new: String, in paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
    let cleaned = new.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "")
    guard !cleaned.isEmpty, cleaned != old else { return paragraphs }
    return paragraphs.map { paragraph in
      guard paragraph.text.hasPrefix("\(old)：") else { return paragraph }
      return TranscriptParagraph(
        startMilliseconds: paragraph.startMilliseconds,
        endMilliseconds: paragraph.endMilliseconds,
        text: "\(cleaned)：" + paragraph.text.dropFirst(old.count + 1)
      )
    }
  }

  /// 已经分过说话人的分段，去掉说话人前缀，恢复成普通转写分段（重新分离时用）。
  public static func strippingSpeakers(_ paragraphs: [TranscriptParagraph], knownSpeakers: [String]) -> [TranscriptParagraph] {
    paragraphs.map { paragraph in
      for name in knownSpeakers where paragraph.text.hasPrefix("\(name)：") {
        return TranscriptParagraph(
          startMilliseconds: paragraph.startMilliseconds,
          endMilliseconds: paragraph.endMilliseconds,
          text: String(paragraph.text.dropFirst(name.count + 1))
        )
      }
      return paragraph
    }
  }

  /// 没有分段表时（老数据），从正文「00:12 文字」行还原出分段；结束时间取下一段开头。
  public static func paragraphs(fromTimestampedBody body: String) -> [TranscriptParagraph] {
    var starts: [(Int, String)] = []
    for raw in body.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard let match = line.range(of: #"^(\d{1,2}:)?\d{1,2}:\d{2}\s+"#, options: .regularExpression) else { continue }
      let clock = line[match].trimmingCharacters(in: .whitespaces)
      let parts = clock.split(separator: ":").compactMap { Int($0) }
      let seconds = parts.reduce(0) { $0 * 60 + $1 }
      var text = String(line[match.upperBound...])
      if let label = speakerLabel(in: line) { text = String(text.dropFirst(label.count + 5)) }
      starts.append((seconds * 1000, text))
    }
    return starts.enumerated().map { index, item in
      let end = index + 1 < starts.count ? starts[index + 1].0 : item.0 + 5_000
      return TranscriptParagraph(startMilliseconds: item.0, endMilliseconds: max(item.0, end), text: item.1)
    }
  }

  static func speakerLabel(in line: String) -> String? {
    guard let range = line.range(of: #"^(\d{1,2}:)?\d{1,2}:\d{2}\s+\*\*([^*\n]{1,30})\*\*："#, options: .regularExpression)
    else { return nil }
    let matched = String(line[range])
    guard let open = matched.range(of: "**"), let close = matched.range(of: "**：", options: .backwards) else { return nil }
    return String(matched[open.upperBound..<close.lowerBound])
  }

  private static func joined(_ left: String, _ right: String) -> String {
    guard let last = left.last, let first = right.first else { return left + right }
    return last.isASCII && last.isLetter && first.isASCII && first.isLetter ? left + " " + right : left + right
  }
}
