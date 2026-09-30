import LinkDigestCore
import SwiftUI

/// 逐字稿按书来排（2026-09-28 自有风格）：时间码挂左侧页边，正文居中，
/// 朱批时改动挂右侧页边、正文里只留一道淡朱下划线。原稿、校对稿、朱批三种看法共用这一套。
enum TranscriptManuscript {
  enum Mode: String, CaseIterable, Identifiable {
    case revised
    case marked
    case original

    var id: String { rawValue }
    var title: String {
      switch self {
      case .revised: "校对稿"
      case .marked: "朱批"
      case .original: "原稿"
      }
    }
  }

  struct Note: Equatable {
    let original: String
    let revised: String?
  }

  struct Paragraph: Identifiable, Equatable {
    let id: Int
    /// 段首在整篇里的 Character 偏移（折叠预览按它截）。
    let offset: Int
    let stamp: String?
    let seconds: Double?
    /// 校对时插入的小标题（`## …`）：`text` 是去掉井号的标题文字。
    var isHeading = false
    /// 时间码是按字数比例估出来的：校对把一个 40 秒的大段拆成几段，后面几段原本没有时间戳。
    var isEstimated = false
    let text: String
    /// 段内要加下划线的范围（按 Character 偏移，已扣掉段首时间码）。
    let marks: [Range<Int>]
    let notes: [Note]
  }

  /// 抓到的评论写在转写稿末尾（`## 评论…` 起）。它不是转写：不挂时间码、不进朱批比对，
  /// 交回评论组件单独排（2026-09-28 修：原来被当成转写段落，符号、ISO 时间全露出来）。
  static func splittingComments(_ text: String) -> (transcript: String, comments: String?) {
    guard let range = text.range(of: #"(?m)^## 评论"#, options: .regularExpression) else { return (text, nil) }
    let transcript = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    let comments = String(text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (transcript, comments.isEmpty ? nil : comments)
  }

  /// 正文里至少有一段以时间码开头，才按逐字稿排；否则交回普通阅读区。
  static func looksLikeTranscript(_ text: String) -> Bool {
    paragraphTexts(of: text).contains { TranscriptRevision.stampAt(Array($0.text), 0) != nil }
  }

  static func paragraphs(of text: String, revision: TranscriptRevision.Result? = nil) -> [Paragraph] {
    withSectionsAndEstimatedStamps(rawParagraphs(of: text, revision: revision))
  }

  /// 小标题段认成标题；没有时间戳的正文段按前后两个时间戳之间的字数比例估一个时间，
  /// 这样「每段都挂时间码」，点哪段都能跳到附近（2026-09-28 Syc 选定）。
  /// 小标题挂的是紧跟它的那一段的时间。
  static func withSectionsAndEstimatedStamps(_ raw: [Paragraph]) -> [Paragraph] {
    var result = raw.map { paragraph -> Paragraph in
      guard paragraph.stamp == nil,
            let range = paragraph.text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return paragraph }
      var heading = Paragraph(
        id: paragraph.id, offset: paragraph.offset, stamp: nil, seconds: nil,
        text: String(paragraph.text[range.upperBound...]), marks: [], notes: paragraph.notes
      )
      heading.isHeading = true
      return heading
    }
    // 全篇平均语速（秒 / 字），最后一段之后没有下一个时间戳时用它外推。
    let anchors = result.enumerated().filter { !$0.element.isHeading && $0.element.seconds != nil }
    var totalChars = 0
    var totalSeconds = 0.0
    for (position, anchor) in anchors.enumerated() where position + 1 < anchors.count {
      let next = anchors[position + 1]
      let chars = result[anchor.offset..<next.offset].filter { !$0.isHeading }.reduce(0) { $0 + $1.text.count }
      totalChars += chars
      totalSeconds += (next.element.seconds ?? 0) - (anchor.element.seconds ?? 0)
    }
    let secondsPerChar = totalChars > 0 ? totalSeconds / Double(totalChars) : 0.2
    var index = 0
    while index < result.count {
      guard !result[index].isHeading, let start = result[index].seconds else { index += 1; continue }
      // 找到下一个有真实时间戳的正文段。
      var end = index + 1
      while end < result.count, result[end].isHeading || result[end].seconds == nil { end += 1 }
      let body = (index..<end).filter { !result[$0].isHeading }
      let chars = body.reduce(0) { $0 + result[$1].text.count }
      let span = end < result.count ? (result[end].seconds ?? start) - start : Double(chars) * secondsPerChar
      var consumed = 0
      for position in body {
        if position != index, chars > 0 {
          let seconds = (start + span * Double(consumed) / Double(chars)).rounded(.down)
          var estimated = Paragraph(
            id: result[position].id, offset: result[position].offset,
            stamp: TranscriptManuscript.label(seconds: seconds), seconds: seconds,
            text: result[position].text, marks: result[position].marks, notes: result[position].notes
          )
          estimated.isEstimated = true
          result[position] = estimated
        }
        consumed += result[position].text.count
      }
      index = end
    }
    // 小标题挂下一段正文的时间。
    for position in result.indices where result[position].isHeading {
      if let next = result[(position + 1)...].first(where: { !$0.isHeading && $0.seconds != nil }) {
        var heading = result[position]
        heading = Paragraph(
          id: heading.id, offset: heading.offset, stamp: next.stamp, seconds: next.seconds,
          text: heading.text, marks: [], notes: heading.notes
        )
        heading.isHeading = true
        heading.isEstimated = next.isEstimated
        result[position] = heading
      }
    }
    return result
  }

  static func label(seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%02d:%02d", minutes, secs)
  }

  static func rawParagraphs(of text: String, revision: TranscriptRevision.Result? = nil) -> [Paragraph] {
    paragraphTexts(of: text).enumerated().map { index, piece in
      let characters = Array(piece.text)
      var bodyStart = 0
      var stamp: String?
      if let found = TranscriptRevision.stampAt(characters, 0) {
        stamp = found
        bodyStart = found.count
        while bodyStart < characters.count, characters[bodyStart].isWhitespace { bodyStart += 1 }
      }
      let absoluteStart = piece.offset + bodyStart
      let absoluteEnd = piece.offset + characters.count
      var marks: [Range<Int>] = []
      var notes: [Note] = []
      for change in revision?.changes ?? [] {
        let lower = max(change.offset, absoluteStart)
        let upper = min(change.offset + change.length, absoluteEnd)
        guard lower < upper else { continue }
        marks.append((lower - absoluteStart)..<(upper - absoluteStart))
        if change.offset >= piece.offset { notes.append(Note(original: change.original, revised: change.revised)) }
      }
      for deletion in revision?.deletions ?? [] where deletion.offsetBefore >= piece.offset && deletion.offsetBefore <= absoluteEnd {
        notes.append(Note(original: deletion.original, revised: nil))
      }
      return Paragraph(
        id: index,
        offset: piece.offset,
        stamp: stamp,
        seconds: stamp.flatMap(seconds(ofStamp:)),
        text: String(characters[bodyStart...]),
        marks: marks,
        notes: notes
      )
    }
  }

  /// 按空行切段，同时记下每段在整篇里的 Character 偏移——朱批的位置是按整篇算的。
  static func paragraphTexts(of text: String) -> [(offset: Int, text: String)] {
    let characters = Array(text)
    var result: [(Int, String)] = []
    var start = 0
    var index = 0
    func flush(_ end: Int) {
      var lower = start
      var upper = end
      while lower < upper, characters[lower].isWhitespace { lower += 1 }
      while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
      if lower < upper { result.append((lower, String(characters[lower..<upper]))) }
    }
    while index < characters.count {
      if characters[index] == "\n" {
        var probe = index + 1
        while probe < characters.count, characters[probe] == " " || characters[probe] == "\t" { probe += 1 }
        if probe < characters.count, characters[probe] == "\n" {
          flush(index)
          start = probe + 1
          index = probe + 1
          continue
        }
      }
      index += 1
    }
    flush(characters.count)
    return result
  }

  static func seconds(ofStamp stamp: String) -> Double? {
    let parts = stamp.split(separator: ":").compactMap { Double($0) }
    guard parts.count >= 2 else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  // MARK: - 比对缓存

  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cache: [String: TranscriptRevision.Result] = [:]

  /// 同一对快照只算一次：阅读区每次重画都会走到这里。
  static func revision(originalKey: String, original: String, revisedKey: String, revised: String) -> TranscriptRevision.Result {
    let key = "\(originalKey)|\(revisedKey)|\(original.count)|\(revised.count)"
    cacheLock.lock()
    if let hit = cache[key] { cacheLock.unlock(); return hit }
    cacheLock.unlock()
    let result = TranscriptRevision.compare(original: original, revised: revised)
    cacheLock.lock()
    if cache.count > 32 { cache.removeAll() }
    cache[key] = result
    cacheLock.unlock()
    return result
  }
}

struct TranscriptManuscriptView: View {
  let paragraphs: [TranscriptManuscript.Paragraph]
  let showsTimecodes: Bool
  let showsNotes: Bool
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let sealColor: Color
  let onSeek: ((Double) -> Void)?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(paragraphs) { paragraph in
        if paragraph.isHeading {
          sectionHeading(paragraph)
        } else {
          bodyRow(paragraph)
        }
      }
    }
    .accessibilityIdentifier("transcript-manuscript")
  }

  /// 校对时加的小标题：宋体半粗、上方多留一截空白。页边不挂时间码——紧跟的第一段
  /// 已经挂着同一个时间，重复一遍只是噪音；页边留空让标题和正文对齐。
  private func sectionHeading(_ paragraph: TranscriptManuscript.Paragraph) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      if showsTimecodes {
        Color.clear.frame(width: 44, height: 1)
      }
      Text(paragraph.text)
        .font(readingFont.font(size: readingFont.scaledSize(19), weight: .semibold))
        .foregroundStyle(primaryTextColor)
        .textSelection(.enabled)
        .frame(maxWidth: readingFont.bodySize * DesignTokens.Layout.readingTextMeasureEm, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
    .padding(.top, paragraph.id == paragraphs.first?.id ? 0 : 18)
  }

  private func bodyRow(_ paragraph: TranscriptManuscript.Paragraph) -> some View {
    HStack(alignment: .top, spacing: 14) {
      if showsTimecodes {
        gutter(paragraph)
          .frame(width: 44, alignment: .trailing)
      }
      Text(attributed(paragraph))
        .font(readingFont.body())
        .lineSpacing(MarkdownPresentation.bodyLineSpacing)
        .foregroundStyle(primaryTextColor)
        .textSelection(.enabled)
        .frame(maxWidth: readingFont.bodySize * DesignTokens.Layout.readingTextMeasureEm, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      if showsNotes {
        notes(paragraph)
          .frame(width: 176, alignment: .leading)
      }
    }
  }

  @ViewBuilder private func gutter(_ paragraph: TranscriptManuscript.Paragraph) -> some View {
    if let stamp = paragraph.stamp {
      Button {
        if let seconds = paragraph.seconds { onSeek?(seconds) }
      } label: {
        Text(stamp)
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(secondaryTextColor.opacity(0.8))
      }
      .buttonStyle(.plain)
      .disabled(onSeek == nil || paragraph.seconds == nil)
      .help(paragraph.isEstimated ? "跳到约 \(stamp)（按字数估算）" : (onSeek == nil ? stamp : "跳到 \(stamp)"))
      .accessibilityLabel(onSeek == nil ? stamp : "跳到 \(stamp)")
      // 和正文第一行的字面对齐；小标题按基线对齐，不另加。
      .padding(.top, paragraph.isHeading ? 0 : max(0, readingFont.bodySize - 11) * 0.55 + 2)
    } else {
      Color.clear.frame(height: 1)
    }
  }

  @ViewBuilder private func notes(_ paragraph: TranscriptManuscript.Paragraph) -> some View {
    let fixes = paragraph.notes.filter { $0.revised != nil }
    // 删掉的多是「呃」「那个」这类口头禅，一条一行会把改字挤出页边；合成一行。
    let dropped = paragraph.notes.filter { $0.revised == nil }.map(\.original)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(fixes.prefix(6).enumerated()), id: \.offset) { _, note in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if note.original.isEmpty {
            // 原稿里没有、校对补上的字：写「补」，不画一个前面空着的箭头。
            Text("补").foregroundStyle(secondaryTextColor.opacity(0.8))
          } else {
            Text(note.original)
              .strikethrough(true, color: secondaryTextColor.opacity(0.6))
              .foregroundStyle(secondaryTextColor)
            Text("→").foregroundStyle(secondaryTextColor.opacity(0.6))
          }
          Text(note.revised ?? "").foregroundStyle(sealColor)
        }
        .font(readingFont.font(size: max(12, readingFont.bodySize - 3)))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      }
      if fixes.count > 6 {
        Text("还有 \(fixes.count - 6) 处改字")
          .font(.system(size: 11))
          .foregroundStyle(secondaryTextColor)
      }
      if !dropped.isEmpty {
        (Text("删去 ").foregroundStyle(secondaryTextColor.opacity(0.8))
          + Text(dropped.joined(separator: "、"))
            .strikethrough(true, color: secondaryTextColor.opacity(0.6))
            .foregroundStyle(secondaryTextColor))
          .font(.system(size: 12))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(paragraph.notes.isEmpty ? "" : "本段改动 \(paragraph.notes.count) 处")
  }

  private func attributed(_ paragraph: TranscriptManuscript.Paragraph) -> AttributedString {
    guard showsNotes, !paragraph.marks.isEmpty else { return AttributedString(paragraph.text) }
    let characters = Array(paragraph.text)
    var result = AttributedString()
    var cursor = 0
    for mark in paragraph.marks.sorted(by: { $0.lowerBound < $1.lowerBound }) where mark.lowerBound >= cursor {
      if mark.lowerBound > cursor { result += AttributedString(String(characters[cursor..<mark.lowerBound])) }
      var marked = AttributedString(String(characters[mark]))
      marked.underlineStyle = Text.LineStyle(pattern: .solid, color: sealColor.opacity(0.65))
      result += marked
      cursor = mark.upperBound
    }
    if cursor < characters.count { result += AttributedString(String(characters[cursor...])) }
    return result
  }
}

/// 题跋：详情末尾一行小号宋体，记下何时从哪里汲来；后面按先后钤上做过的工序章，
/// 最后是收藏主印「汲 / 作」（2026-09-28 工序印样稿）。
/// 每枚章悬停看来历，点一下跳到那份内容。
struct ColophonView: View {
  let text: String
  let glyph: SealMark.Glyph
  /// 下载来的本地文件记着来源网址时，题跋文字可以点开它（2026-09-29）。
  var link: URL? = nil
  var records: [ProcessStepRecord] = []
  let readingFont: ResolvedReadingFont
  let secondaryTextColor: Color
  let sealColor: Color
  let hairline: Color
  var onSelect: ((ProcessStep) -> Void)? = nil

  var body: some View {
    VStack(spacing: 14) {
      Rectangle().fill(hairline).frame(height: 1)
      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Group {
          if let link {
            Link(destination: link) {
              Text(text).underline(true, color: secondaryTextColor.opacity(0.4))
            }
            .help(link.absoluteString)
          } else {
            Text(text)
          }
        }
          .font(readingFont.font(size: max(12, readingFont.bodySize - 3)))
          .tracking(1)
          .foregroundStyle(secondaryTextColor)
          .accessibilityIdentifier("history-colophon-text")
        if !records.isEmpty {
          HStack(spacing: 7) {
            ForEach(records) { record in
              Button { onSelect?(record.step) } label: {
                SealMark(glyph: record.step.glyph, size: 26, color: sealColor, style: .stamped, rotation: record.step.rotation)
              }
              .buttonStyle(.plain)
              .help(record.provenance + (onSelect == nil ? "" : " · 点一下跳过去"))
              .accessibilityLabel(record.provenance)
              .accessibilityIdentifier("history-colophon-seal-\(record.step.rawValue)")
            }
          }
        }
        SealMark(glyph: glyph, size: 36, color: sealColor, style: .stamped, rotation: -0.8)
          .padding(.leading, 4)
          .help(glyph == .external ? "汲 · 外部内容" : "作 · 自有内容")
      }
    }
    .padding(.top, 32)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history-colophon")
  }

  /// 「九月二十八日」这样的中文日期。
  static func chineseDate(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(chineseNumber(parts.month ?? 1))月\(chineseNumber(parts.day ?? 1))日"
  }

  static func chineseNumber(_ value: Int) -> String {
    let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    switch value {
    case 0..<10: return digits[value]
    case 10: return "十"
    case 11..<20: return "十" + digits[value - 10]
    case 20..<100:
      return digits[value / 10] + "十" + (value % 10 == 0 ? "" : digits[value % 10])
    default: return String(value)
    }
  }
}
