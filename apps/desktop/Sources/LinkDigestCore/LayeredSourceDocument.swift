import Foundation

/// 一条记录里可能同时有「抓来的配文」和「视频转写稿」。
///
/// 两者必须分开保存、分开显示，也必须都能进总结/翻译。转写完成后如果只看
/// `snapshots.last`，原文会被转写稿盖掉，翻译还可能继续用抓取时那份配文。
public enum LayeredSourceDocument {
  public static let captionHeading = "配文"
  public static let transcriptHeading = "视频转写"
  public static let subtitleHeading = "画面字幕"

  /// 本机加工出来的层，不是抓来的原始配文。
  ///
  /// `captionSnapshot` 靠「不是派生层」来认配文，所以**每加一种派生来源都必须
  /// 登记到这里**。漏登记不会报错，只会让新层被悄悄当成配文：原本的配文从此
  /// 取不到，作者、发布时间这些只有配文才有的字段也跟着消失。
  public static let derivedKinds: Set<String> = [
    CapturedDocument.Origin.localTranscription.rawValue,
    CapturedDocument.Origin.burnedInSubtitles.rawValue
  ]

  public static func captionSnapshot(in snapshots: [ContentSnapshot]) -> ContentSnapshot? {
    snapshots.reversed().first {
      !derivedKinds.contains($0.sourceKind)
    }
  }

  public static func transcriptSnapshot(in snapshots: [ContentSnapshot]) -> ContentSnapshot? {
    snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
        && !body(of: $0).isEmpty
    }
  }

  public static func subtitleSnapshot(in snapshots: [ContentSnapshot]) -> ContentSnapshot? {
    snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.burnedInSubtitles.rawValue
        && !body(of: $0).isEmpty
    }
  }

  public static func body(of snapshot: ContentSnapshot) -> String {
    let parsed = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !parsed.isEmpty { return parsed }
    return snapshot.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 发给总结/翻译/脑图的正文：有配文和转写就两层都带上，并标清楚各是什么。
  public static func modelInput(from snapshots: [ContentSnapshot]) -> String {
    // 顺序固定：配文 → 画面字幕 → 视频转写。前者是抓来的原文，后两者是同一段
    // 视频的两种转录；字幕排在听写前面，是因为它常常是人工翻译的成品。
    let layers = orderedLayers(from: snapshots)
    guard !layers.isEmpty else {
      return snapshots.last.map(body(of:)) ?? ""
    }
    // 只有一层时不加标题。给孤零零一段正文扣个「## 配文」的帽子，对模型和
    // 导出都是纯噪声。
    guard layers.count > 1 else { return layers[0].body }
    return layers.map { "## \($0.heading)\n\n\($0.body)" }.joined(separator: "\n\n")
  }

  /// 把 `modelInput` 拼出来的那份文档**拆回各层**。
  ///
  /// 为什么需要这个：翻译是整份文档一次翻完的，译文里同样带着
  /// `## 配文` / `## 画面字幕` / `## 视频转写` 这几个小标题。不拆的话，翻译页就
  /// 只能把各层纵向叠着显示——而这正是原文页当初改掉的形态：画面字幕和视频转写
  /// 是同一段话的两个版本，叠着意味着要滚过整份字幕才够得着转写稿。
  ///
  /// 只认这三个已知标题，而且必须是 `## ` 开头的整行。译文正文里出现同名的
  /// 普通句子不会被误当成分层点。
  ///
  /// 拆不出（只有一层、或模型没保留标题）时返回单个 heading 为 nil 的层，
  /// 调用方据此退回「不显示切换控件、整篇渲染」。
  public static func split(_ composed: String) -> [(heading: String?, body: String)] {
    let known = Set([captionHeading, subtitleHeading, transcriptHeading])
    var layers: [(heading: String?, body: String)] = []
    var currentHeading: String?
    var buffer: [String] = []

    func flush() {
      let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      // 标题下面空无一物时不产出层：那是个只会让切换控件多一个空档的死项。
      guard !body.isEmpty else { buffer = []; return }
      layers.append((heading: currentHeading, body: body))
      buffer = []
    }

    for line in composed.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("## ") {
        let title = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if known.contains(title) {
          flush()
          currentHeading = title
          continue
        }
      }
      buffer.append(line)
    }
    flush()
    return layers
  }

  /// 按固定顺序取出所有非空的层。
  static func orderedLayers(from snapshots: [ContentSnapshot]) -> [(heading: String, body: String)] {
    let candidates: [(String, ContentSnapshot?)] = [
      (captionHeading, captionSnapshot(in: snapshots)),
      (subtitleHeading, subtitleSnapshot(in: snapshots)),
      (transcriptHeading, transcriptSnapshot(in: snapshots))
    ]
    var layers: [(heading: String, body: String)] = []
    for (heading, snapshot) in candidates {
      guard let text = snapshot.map(body(of:)).flatMap(nonEmpty) else { continue }
      layers.append((heading: heading, body: text))
    }
    return layers
  }

  /// 任一层还不是目标语言，就仍提供翻译。转写常已是中文，不能因此把英文配文的翻译入口关掉。
  public static func needsTranslation(
    from snapshots: [ContentSnapshot],
    outputLanguage: String
  ) -> Bool {
    let layers = orderedLayers(from: snapshots).map(\.body)
    let parts = layers.isEmpty ? [modelInput(from: snapshots)].filter { !$0.isEmpty } : layers
    return parts.contains {
      !CapturedContentLanguage.isSameOutputLanguage(content: $0, outputLanguage: outputLanguage)
    }
  }

  private static func nonEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }
}
