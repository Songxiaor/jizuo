import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Safari / 系统分享 → 暂存 → 主 App 导入。
///
/// 优先 App Group 文件；容器不可用时降级到专用 Pasteboard 类型
///（Personal Team 若编签失败无法挂 App Group 时仍可通）。
public enum ShareInbox {
  public static let appGroupID = "group.com.syc.linkdigest"
  public static let fileName = "share-inbox.json"
  public static let pasteboardType = "com.syc.linkdigest.share-inbox"
  public static let urlSchemeHost = "import"

  public struct Item: Codable, Sendable, Equatable {
    public var url: String?
    public var text: String?
    public var title: String?
    public var createdAtMilliseconds: Int64

    public init(
      url: String? = nil,
      text: String? = nil,
      title: String? = nil,
      createdAtMilliseconds: Int64 = ShareInbox.nowMilliseconds()
    ) {
      self.url = Self.normalizedOptional(url)
      self.text = Self.normalizedOptional(text)
      self.title = Self.normalizedOptional(title)
      self.createdAtMilliseconds = createdAtMilliseconds
    }

    public var isEmpty: Bool {
      (url?.isEmpty ?? true) && (text?.isEmpty ?? true)
    }

    /// 有 http(s) URL 则按链接笔记；否则按文字。
    public var resolvedURLString: String? {
      if let url, looksLikeHTTPURL(url) { return url }
      if let text, looksLikeHTTPURL(text) {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return nil
    }

    private static func normalizedOptional(_ value: String?) -> String? {
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  public struct Envelope: Codable, Sendable, Equatable {
    public var items: [Item]
    public init(items: [Item] = []) { self.items = items }
  }

  public static func nowMilliseconds(_ date: Date = Date()) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
  }

  public static func looksLikeHTTPURL(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }

  /// 写入一条分享（Extension 与测试共用）。
  @discardableResult
  public static func enqueue(_ item: Item) -> Bool {
    guard !item.isEmpty else { return false }
    var envelope = loadEnvelope()
    envelope.items.append(item)
    return saveEnvelope(envelope)
  }

  /// 取出并清空暂存。
  public static func consumePending() -> [Item] {
    let envelope = loadEnvelope()
    guard !envelope.items.isEmpty else { return [] }
    _ = saveEnvelope(Envelope(items: []))
    clearPasteboardFallback()
    return envelope.items.filter { !$0.isEmpty }
  }

  /// 仅窥视，不清空（测试用）。
  public static func peekPending() -> [Item] {
    loadEnvelope().items.filter { !$0.isEmpty }
  }

  // MARK: - Storage

  private static func containerDirectory() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
  }

  private static func temporaryInboxDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("LinkDigestShareInbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// App Group（可写）→ 临时目录（单测 / Group 虚路径）→ Pasteboard（仅 iOS）。
  private static func inboxFileURL() -> URL {
    if let group = containerDirectory(), isWritableDirectory(group) {
      return group.appendingPathComponent(fileName)
    }
    return temporaryInboxDirectory().appendingPathComponent(fileName)
  }

  private static func isWritableDirectory(_ directory: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let probe = directory.appendingPathComponent(".linkdigest-write-probe")
      try Data([0x4C, 0x44]).write(to: probe, options: [.atomic])
      try FileManager.default.removeItem(at: probe)
      return true
    } catch {
      return false
    }
  }

  private static func loadEnvelope() -> Envelope {
    // 同时看 Group 与临时目录，避免探测结果抖动导致读写落到不同路径。
    for url in inboxCandidateURLs() {
      if let data = try? Data(contentsOf: url),
         let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
         !decoded.items.isEmpty
      {
        return decoded
      }
    }
    if let pasteboard = loadPasteboardEnvelope(), !pasteboard.items.isEmpty {
      return pasteboard
    }
    for url in inboxCandidateURLs() {
      if let data = try? Data(contentsOf: url),
         let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
      {
        return decoded
      }
    }
    return Envelope()
  }

  private static func inboxCandidateURLs() -> [URL] {
    var urls: [URL] = []
    if let group = containerDirectory() {
      urls.append(group.appendingPathComponent(fileName))
    }
    urls.append(temporaryInboxDirectory().appendingPathComponent(fileName))
    return urls
  }

  private static func saveEnvelope(_ envelope: Envelope) -> Bool {
    let data: Data
    do {
      data = try JSONEncoder().encode(envelope)
    } catch {
      return savePasteboardEnvelope(envelope)
    }

    for url in inboxCandidateURLs() {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        _ = savePasteboardEnvelope(envelope)
        return true
      } catch {
        continue
      }
    }
    return savePasteboardEnvelope(envelope)
  }

  #if canImport(UIKit)
  private static func loadPasteboardEnvelope() -> Envelope? {
    let pb = UIPasteboard.general
    guard let data = pb.data(forPasteboardType: pasteboardType),
          let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
    else { return nil }
    return decoded
  }

  private static func savePasteboardEnvelope(_ envelope: Envelope) -> Bool {
    guard let data = try? JSONEncoder().encode(envelope) else { return false }
    if envelope.items.isEmpty {
      clearPasteboardFallback()
      return true
    }
    UIPasteboard.general.setData(data, forPasteboardType: pasteboardType)
    return true
  }

  private static func clearPasteboardFallback() {
    // 不能 clearContents（会清掉用户其它剪贴内容）；只覆盖我们的类型为空信封。
    if let data = try? JSONEncoder().encode(Envelope(items: [])) {
      UIPasteboard.general.setData(data, forPasteboardType: pasteboardType)
    }
  }
  #else
  private static func loadPasteboardEnvelope() -> Envelope? { nil }
  private static func savePasteboardEnvelope(_ envelope: Envelope) -> Bool {
    _ = envelope
    return false
  }
  private static func clearPasteboardFallback() {}
  #endif
}
