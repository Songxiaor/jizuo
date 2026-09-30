import Foundation

/// 一条内容「是谁说的」：自有，还是外部（2026-09-24）。
///
/// 汲作是一个记录平台：一边是用户觉得不错的外部内容，一边是用户自己的东西。
/// 这一刀按**说话主体**切，不按渠道切——本机导入的 PDF 可能是别人的研报，
/// 从 X 抓来的帖子也可能是自己发的。
///
/// 默认按规则判断，不需要 AI：笔记、稿件、作品、备忘录、语音备忘录、本地文件算自有，
/// 其余（抓来的网页、帖子、视频）算外部。规则判错时用户手动改，
/// 改动落在两个保留标签上，和素材类型一样不另建表。
public enum ContentOwnership: String, Sendable, CaseIterable {
  case own = "自有"
  case external = "外部"

  /// 手动改成「自有」的条目带这个标签。
  public static let ownTagName = "自有"
  /// 手动改成「外部」的条目带这个标签。
  public static let externalTagName = "外部"

  public static var ownTagNormalizedName: String {
    HistoryTagNormalizer.normalized(ownTagName)?.normalizedName ?? ownTagName
  }

  public static var externalTagNormalizedName: String {
    HistoryTagNormalizer.normalized(externalTagName)?.normalizedName ?? externalTagName
  }

  /// 默认算自有的本机来源：备忘录、语音备忘录是用户自己写的、自己录的。
  ///
  /// 本地文件也默认算自有（2026-09-29 Syc 的新规则）：拖进汲作的多是自己的录音、课件、
  /// 稿子。从外部下载来的文件由导入时的来源标记判为外部——macOS 给下载文件打的
  /// `com.apple.quarantine`（见 `LocalFileProvenance`）——导入那一刻贴上保留标签「外部」，
  /// 不靠这里的默认规则。没有下载标记的，按这里算自有。
  public static let ownLocalHosts: [String] = [
    LocalImportSource.appleNotes.rawValue,
    LocalImportSource.voiceMemos.rawValue,
    LocalImportSource.files.rawValue,
  ]

  /// 不看手动标签时，按内容本身判断出的归属。
  public static func defaultOwnership(canonicalURL: String, host: String) -> ContentOwnership {
    if canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix)
      || canonicalURL.hasPrefix(HistoryPlatformDisplay.draftURLPrefix)
      || canonicalURL.hasPrefix(HistoryPlatformDisplay.workURLPrefix) {
      return .own
    }
    return ownLocalHosts.contains(host) ? .own : .external
  }

  /// 最终归属：手动标签优先，其次是默认规则。
  public static func resolve(canonicalURL: String, host: String, tagNames: [String]) -> ContentOwnership {
    let normalized = Set(tagNames.compactMap { HistoryTagNormalizer.normalized($0)?.normalizedName })
    if normalized.contains(ownTagNormalizedName) { return .own }
    if normalized.contains(externalTagNormalizedName) { return .external }
    return defaultOwnership(canonicalURL: canonicalURL, host: host)
  }

  /// 把条目改成 `target` 时，标签要怎么动：和默认规则一致就两个都摘掉（不留多余标签），
  /// 否则贴上目标标签、摘掉另一个。
  public static func tagChanges(
    to target: ContentOwnership,
    canonicalURL: String,
    host: String
  ) -> (add: [String], remove: [String]) {
    if defaultOwnership(canonicalURL: canonicalURL, host: host) == target {
      return ([], [ownTagName, externalTagName])
    }
    return target == .own ? ([ownTagName], [externalTagName]) : ([externalTagName], [ownTagName])
  }
}

/// 一条内容「是什么」：按抓取时已有的信息用规则判定，不需要 AI（2026-09-24）。
///
/// 顺序即优先级：作品 → 笔记 → 录音 → 视频 → 图片 → 文档 → 图文。
public enum ContentForm: String, Sendable, CaseIterable {
  case article = "图文"
  case video = "视频"
  case audio = "录音"
  case image = "图片"
  case document = "文档"
  case note = "笔记"
  case work = "作品"

  public var systemImage: String {
    switch self {
    case .article: "doc.richtext"
    case .video: "play.rectangle"
    case .audio: "waveform"
    case .image: "photo"
    case .document: "doc"
    case .note: "square.and.pencil"
    case .work: "checkmark.seal"
    }
  }
}
