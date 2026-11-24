import Foundation

/// 录制文件名与目录。文件名要让人在 Finder 里一眼认出来：
/// 「主播名_开播日期_时间.mp4」，同一场同一秒不会重名。
enum LiveRecordingNaming {
  static let folderName = "直播录制"

  static func defaultDirectory(applicationSupportRoot: URL) -> URL {
    applicationSupportRoot
      .appendingPathComponent("LinkDigest", isDirectory: true)
      .appendingPathComponent(folderName, isDirectory: true)
  }

  static func sanitizedComponent(_ raw: String?, maxLength: Int = 40, fallback: String = "直播") -> String {
    guard let raw else { return fallback }
    let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
      .union(.controlCharacters)
      .union(.newlines)
    let replaced = raw
      .components(separatedBy: forbidden)
      .joined(separator: "-")
    let collapsed = replaced
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
    guard !collapsed.isEmpty else { return fallback }
    return String(collapsed.prefix(maxLength))
  }

  static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: date)
  }

  /// 主播名优先；读不到时用直播标题兜底，避免所有文件都叫「直播_…」。
  static func fileName(anchorName: String?, title: String? = nil, startedAt: Date) -> String {
    let preferred = anchorName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let who = sanitizedComponent(
      (preferred?.isEmpty == false) ? anchorName : title
    )
    return "\(who)_\(timestamp(startedAt)).mp4"
  }

  /// 分段文件放在隐藏的 `.parts` 目录里，合并成功后删掉；中途失败也留着可手动救回。
  static func segmentsDirectory(recordingDirectory: URL, stem: String) -> URL {
    recordingDirectory
      .appendingPathComponent(".parts", isDirectory: true)
      .appendingPathComponent(stem, isDirectory: true)
  }

  static func segmentURL(segmentsDirectory: URL, index: Int) -> URL {
    // 中间段是 MPEG-TS：断线重启后 PTS 往往从头开始，TS 能直接拼，MP4 会被截短。
    segmentsDirectory.appendingPathComponent(String(format: "segment-%04d.ts", index))
  }

  /// 合并先写到 `.parts` 里的临时文件，成功后才改名成正式 MP4。
  /// App 在合并中途退出时只会留下这个临时文件，不会被当成成品。
  static func mergePartialURL(segmentsDirectory: URL, index: Int) -> URL {
    segmentsDirectory.appendingPathComponent(String(format: "merged-%04d.partial.mp4", index))
  }

  /// 合并产物落成正式文件。0 字节或空文件一律不动，避免把半截文件当成品。
  static func finalizeMergeOutput(partial: URL, finalURL: URL) -> Bool {
    let size = fileSize(partial)
    guard size > 0 else {
      try? FileManager.default.removeItem(at: partial)
      return false
    }
    try? FileManager.default.removeItem(at: finalURL)
    do {
      try FileManager.default.moveItem(at: partial, to: finalURL)
      return true
    } catch {
      return false
    }
  }

  /// 文件大小。走 attributesOfItem，不用 `URL.resourceValues`：后者按 URL 实例缓存，
  /// 同一个 URL 读第二次拿到的是旧值（正在写入的文件会一直显示第一次的大小）。
  static func fileSize(_ url: URL) -> Int64 {
    Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
  }

  /// 合并产物编号：1 = 原名，2 起在扩展名前加 `-2`、`-3`（编码不同时各存一个）。
  static func numberedURL(_ url: URL, number: Int) -> URL {
    guard number > 1 else { return url }
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    let name = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
    return url.deletingLastPathComponent().appendingPathComponent(name)
  }
}
