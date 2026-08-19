import Foundation

/// 转写稿分段时间的存取。
///
/// 和 `MindMapStoring` 一样单独成协议，不并进 `HistoryRepository`：那个协议已有
/// 一批实现（含测试替身），每加一个方法都要全部跟着改。
///
/// 分段挂在 snapshot 上。只有识别器直接产出的那份正文与时间对齐，模型整理稿和
/// 用户手改稿都不对齐——详见 `Migration018` 的说明。
public protocol TranscriptParagraphStoring: Sendable {
  /// 覆盖式写入：同一个 snapshot 只保留最后一次识别的分段。
  func saveTranscriptParagraphs(_ paragraphs: [TranscriptParagraph], snapshotID: String) throws
  func loadTranscriptParagraphs(snapshotID: String) throws -> [TranscriptParagraph]
  /// 正文被编辑后调用：分段与文字不再对齐，留着只会跳错地方。
  func deleteTranscriptParagraphs(snapshotID: String) throws
}

/// 把分段时间迁到整理稿上。
///
/// 整理稿是**新的 snapshot**，原稿的分段挂在旧 snapshot 上。不迁移的话，「点一下
/// 跳到那一秒」在整理之后就没了——而整理恰恰是用户最常做的一步。
///
/// 整理会**重新划分段落**（这是它的核心价值之一：原始转写按说话停顿切段，一句话
/// 经常被切开）。所以段落数对不上，不能按序号一一对应。
///
/// 用**前缀锚定**：整理只改标点和错别字，段落开头那几个字大多是原样的，拿它去
/// 原文里找位置，就知道这个新段落是从原文哪一段开始的，时间取那一段的起点。
/// 提示词里那条「内容顺序绝对不许调整」是这件事能成立的前提——只要文字流的顺序
/// 没变，从上一次命中的位置往后找就一定不会错位。
///
/// **按比例插值是不行的**：改字会让字数漂移，一个 40 分钟的稿子误差能到十几秒，
/// 足够跳到上一段中间去。那是看着精确、点下去对不上的数字，比没有锚点更糟。
public enum TranscriptParagraphMigration {
  /// 命中率低于这个比例就整批不迁移。
  ///
  /// 一半以上的段落都定位不到，说明模型改写的幅度远超「修错别字」——这时候
  /// 任何一条锚点都不可信了。宁可退回没有锚点的整理稿。
  public static let minimumMatchRatio = 0.6

  /// 返回 nil 表示不该迁移。
  public static func migrated(
    _ original: [TranscriptParagraph],
    toTidiedBody body: String
  ) -> [TranscriptParagraph]? {
    guard !original.isEmpty else { return nil }
    let paragraphs = bodyParagraphs(body)
    guard !paragraphs.isEmpty else { return nil }

    // 原文按段落拼成一条字符流，同时记下每段的起点在流里的位置。
    var stream = ""
    var boundaries: [(offset: Int, paragraph: TranscriptParagraph)] = []
    for paragraph in original {
      boundaries.append((stream.count, paragraph))
      stream += comparable(paragraph.text)
    }
    let streamCharacters = Array(stream)

    var migrated: [TranscriptParagraph] = []
    var cursor = 0
    var matches = 0
    for text in paragraphs {
      let probe = Array(comparable(text).prefix(probeLength))
      var located: Int?
      if probe.count >= minimumProbeLength {
        located = firstIndex(of: probe, in: streamCharacters, from: cursor)
      }
      if let located {
        cursor = located
        matches += 1
      }
      // 定位不到就沿用上一次的位置：内容顺序没变，它一定在上一段之后。
      let source = paragraph(at: cursor, in: boundaries) ?? original[0]
      migrated.append(TranscriptParagraph(
        startMilliseconds: source.startMilliseconds,
        endMilliseconds: source.endMilliseconds,
        text: text
      ))
    }
    guard Double(matches) / Double(paragraphs.count) >= minimumMatchRatio else { return nil }
    return migrated
  }

  /// 正文里的段落，**不含小标题行**——标题是插进去的版面记号，不是内容。
  public static func bodyParagraphs(_ body: String) -> [String] {
    body
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !isHeading($0) }
  }

  private static let probeLength = 12
  private static let minimumProbeLength = 4

  /// 比较用的形态：去掉标点和空白。整理动的正是标点，留着它们等于自己制造不匹配。
  private static func comparable(_ text: String) -> String {
    String(text.unicodeScalars.filter { scalar in
      !CharacterSet.punctuationCharacters.contains(scalar)
        && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        && !CharacterSet(charactersIn: "，。！？；：、「」『』（）—…·").contains(scalar)
    })
  }

  private static func firstIndex(of probe: [Character], in stream: [Character], from start: Int) -> Int? {
    guard !probe.isEmpty, start < stream.count else { return nil }
    let limit = stream.count - probe.count
    guard limit >= start else { return nil }
    for index in start...limit where Array(stream[index..<(index + probe.count)]) == probe {
      return index
    }
    return nil
  }

  private static func paragraph(
    at offset: Int, in boundaries: [(offset: Int, paragraph: TranscriptParagraph)]
  ) -> TranscriptParagraph? {
    var found: TranscriptParagraph?
    for boundary in boundaries {
      if boundary.offset <= offset { found = boundary.paragraph } else { break }
    }
    return found ?? boundaries.first?.paragraph
  }

  private static func isHeading(_ paragraph: String) -> Bool {
    guard paragraph.hasPrefix("#") else { return false }
    return paragraph.drop(while: { $0 == "#" }).hasPrefix(" ")
  }
}

extension HistoryApplicationService {
  /// nil when the underlying repository predates transcript paragraph storage.
  public var transcriptParagraphStore: (any TranscriptParagraphStoring)? {
    repositoryAsTranscriptParagraphStore
  }
}
