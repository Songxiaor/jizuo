import Foundation
import LinkDigestCore

/// 翻译进行中，翻译页按翻完后的样子排（2026-10-04 Syc：「每翻译一句它就变一句」）。
///
/// 原来进行中只有一整块没排版的纯文字：配文和转写混成一串、时间码夹在正文里，翻完才
/// 整页换成逐字稿版式，看起来像「要等全部翻完才能看」。这里把正在流入的译文切成
/// 已写完的行、按层拆开；转写层再把还没译到的原文段接在后面，译文到一段替换一段。
enum LiveTranslationPreview {
  /// 已经写完的部分：截到最后一个换行。正在写的半行不放出来——它每 250ms 长一截，
  /// 跟着重排整页逐字稿既晃眼又费电；等它写完一行再一起出现。
  static func completedText(of live: String) -> String {
    guard let newline = live.lastIndex(of: "\n") else { return "" }
    return String(live[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 已写完的译文里出现过的层，按出现顺序；最后一个就是正在翻的那层。
  static func translatedLayerHeadings(in completed: String) -> [String] {
    LayeredSourceDocument.split(completed).compactMap(\.heading)
  }

  /// 某一层已经译好的正文；这一层还没开始时为 nil。
  static func translatedBody(of heading: String, in completed: String) -> String? {
    LayeredSourceDocument.split(completed).first { $0.heading == heading }?.body
  }

  /// 没分层的译文（普通文章）：整段就是正文，开头的译文标题行由调用方决定要不要显示。
  static func unlayeredBody(in completed: String) -> String? {
    let layers = LayeredSourceDocument.split(completed)
    guard layers.count == 1, layers[0].heading == nil else { return nil }
    return layers[0].body
  }

  /// 转写原文里还没译到的部分：从第一段时间码晚于「已译最后一个时间码」的段落开始，
  /// 连同紧挨在它前面的小标题一起返回。
  ///
  /// 按时间码对齐而不是按段数：校对稿会插小标题、模型偶尔合并两行，数段数会错位；
  /// 时间码在译文里原样保留，是两边唯一可靠的对照。
  /// - 译文里还没有任何时间码：整篇原文都还没译到。
  /// - 原文本身没有时间码：对不上，返回 nil（调用方只显示已译部分，不拼可能重复的原文）。
  static func untranslatedSource(_ source: String, afterTranslated translated: String?) -> String? {
    let paragraphs = sourceParagraphs(source)
    guard paragraphs.contains(where: { $0.seconds != nil }) else { return nil }
    guard let translated, let last = lastStampSeconds(in: translated) else { return source }
    guard let firstPending = paragraphs.firstIndex(where: { ($0.seconds ?? -1) > last }) else { return "" }
    // 小标题挂的是紧跟它的那一段：一起留在「待译」里，免得标题先于自己那段消失。
    var start = firstPending
    while start > 0, paragraphs[start - 1].isHeading { start -= 1 }
    return paragraphs[start...].map(\.text).joined(separator: "\n\n")
  }

  // MARK: - 内部

  private struct SourceParagraph {
    let text: String
    let seconds: Double?
    let isHeading: Bool
  }

  /// 原文按空行切段；译文常一行一个时间码，原文同样按行兜底，保证每段至多一个时间码。
  private static func sourceParagraphs(_ source: String) -> [SourceParagraph] {
    let normalized = source.replacingOccurrences(
      of: #"\n[ \t]*(?=(?:\d{1,2}:)?\d{1,2}:\d{2}\s)"#, with: "\n\n", options: .regularExpression
    )
    return normalized.components(separatedBy: "\n\n").compactMap { raw in
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return SourceParagraph(text: text, seconds: leadingStampSeconds(text), isHeading: text.hasPrefix("#"))
    }
  }

  private static let stampPattern = try! NSRegularExpression(
    pattern: #"(?m)^[ \t]*((?:\d{1,2}:)?\d{1,2}:\d{2})(?=\s)"#
  )

  static func lastStampSeconds(in text: String) -> Double? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = stampPattern.matches(in: text, range: range).last,
          let stampRange = Range(match.range(at: 1), in: text)
    else { return nil }
    return seconds(of: String(text[stampRange]))
  }

  private static func leadingStampSeconds(_ paragraph: String) -> Double? {
    let range = NSRange(paragraph.startIndex..., in: paragraph)
    guard let match = stampPattern.firstMatch(in: paragraph, range: range),
          match.range.location == 0,
          let stampRange = Range(match.range(at: 1), in: paragraph)
    else { return nil }
    return seconds(of: String(paragraph[stampRange]))
  }

  private static func seconds(of stamp: String) -> Double? {
    let parts = stamp.split(separator: ":").compactMap { Double($0) }
    guard parts.count == stamp.split(separator: ":").count else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
  }
}
