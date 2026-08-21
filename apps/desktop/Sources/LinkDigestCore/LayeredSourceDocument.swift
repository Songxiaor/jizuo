import Foundation

/// 一条记录里可能同时有「抓来的配文」和「视频转写稿」。
///
/// 两者必须分开保存、分开显示，也必须都能进总结/翻译。转写完成后如果只看
/// `snapshots.last`，原文会被转写稿盖掉，翻译还可能继续用抓取时那份配文。
public enum LayeredSourceDocument {
  public static let captionHeading = "配文"
  public static let transcriptHeading = "视频转写"

  public static func captionSnapshot(in snapshots: [ContentSnapshot]) -> ContentSnapshot? {
    snapshots.reversed().first {
      $0.sourceKind != CapturedDocument.Origin.localTranscription.rawValue
    }
  }

  public static func transcriptSnapshot(in snapshots: [ContentSnapshot]) -> ContentSnapshot? {
    snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
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
    let caption = captionSnapshot(in: snapshots).map(body(of:)).flatMap(nonEmpty)
    let transcript = transcriptSnapshot(in: snapshots).map(body(of:)).flatMap(nonEmpty)
    switch (caption, transcript) {
    case let (caption?, transcript?):
      return """
      ## \(captionHeading)

      \(caption)

      ## \(transcriptHeading)

      \(transcript)
      """
    case let (caption?, nil):
      return caption
    case let (nil, transcript?):
      return transcript
    case (nil, nil):
      return snapshots.last.map(body(of:)) ?? ""
    }
  }

  /// 任一层还不是目标语言，就仍提供翻译。转写常已是中文，不能因此把英文配文的翻译入口关掉。
  public static func needsTranslation(
    from snapshots: [ContentSnapshot],
    outputLanguage: String
  ) -> Bool {
    let layers = [
      captionSnapshot(in: snapshots).map(body(of:)),
      transcriptSnapshot(in: snapshots).map(body(of:)),
    ]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    let parts = layers.isEmpty ? [modelInput(from: snapshots)].filter { !$0.isEmpty } : layers
    return parts.contains {
      !CapturedContentLanguage.isSameOutputLanguage(content: $0, outputLanguage: outputLanguage)
    }
  }

  private static func nonEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }
}
