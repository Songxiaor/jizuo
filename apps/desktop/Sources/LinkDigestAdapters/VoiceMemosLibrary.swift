import Foundation
import SQLite3

/// 系统「语音备忘录」里的一条录音。只读描述，不含音频内容。
public struct VoiceMemoRecording: Sendable, Equatable {
  /// 系统给的稳定 ID；读不到时退回文件名。它决定汲作里的条目身份。
  public let id: String
  public let title: String?
  public let recordedAt: Date?
  public let durationSeconds: Double?
  /// 音频文件位置。录音只在 iCloud、还没下载到本机时，这个文件不存在。
  public let fileURL: URL

  public init(id: String, title: String?, recordedAt: Date?, durationSeconds: Double?, fileURL: URL) {
    self.id = id
    self.title = title
    self.recordedAt = recordedAt
    self.durationSeconds = durationSeconds
    self.fileURL = fileURL
  }

  /// 录音本体在不在这台 Mac 上。
  ///
  /// 只看文件存不存在不够：iCloud 录音没下载时，本机留的是几百字节的占位文件
  /// （2026-09-23 实测：347 秒的录音只有 726 字节），读出来会被误报成「没有声音」。
  /// 任何真实编码每秒都远超 1 KB，所以文件小于「时长 × 1 KB」就当作还在云端。
  public var isDownloaded: Bool {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    return Self.looksDownloaded(fileSize: size, durationSeconds: durationSeconds)
  }

  static func looksDownloaded(fileSize: Int?, durationSeconds: Double?) -> Bool {
    guard let fileSize, let durationSeconds, durationSeconds > 2 else { return true }
    return Double(fileSize) >= durationSeconds * 1_000
  }
}

public enum VoiceMemosLibraryError: Error, Sendable, Equatable {
  /// 目录在，但系统不让读——没有给汲作「完全磁盘访问」。
  case permissionDenied
  /// 这台 Mac 上从没用过语音备忘录，或系统换了存储位置。
  case libraryNotFound
  /// 录音目录能读，但既没有录音库也没有音频文件。
  case unreadable

  public var userMessage: String {
    switch self {
    case .permissionDenied:
      return "汲作还没有读取语音备忘录的权限。请在「系统设置 → 隐私与安全性 → 完全磁盘访问」里打开汲作，然后回来再同步一次。"
    case .libraryNotFound:
      return "这台 Mac 上没有找到语音备忘录的录音库。请先在「语音备忘录」App 里录一条或等 iCloud 同步完成。"
    case .unreadable:
      return "语音备忘录的录音库暂时读不出来，可能系统正在同步。请稍后再试。"
    }
  }
}

/// 只读访问系统语音备忘录。
///
/// 录音在 `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`，
/// 标题、时长和录制时间在同目录的 Core Data 库 `CloudRecordings.db`。这是 Apple 的
/// 私有存储而不是公开接口，列名随系统版本有变化，所以这里按「有什么列用什么列」
/// 读取，读不到库时退回直接列音频文件——标题差一点，录音不会丢。
///
/// 从不写入这个目录：库文件先复制到临时目录再打开，避免和语音备忘录 App 抢锁，
/// 也保证哪怕我们的读取出错，也碰不到用户的原始录音库。
public struct VoiceMemosLibrary: Sendable {
  public static let audioExtensions: Set<String> = ["m4a", "qta", "mp4", "caf", "wav", "aac"]

  public let recordingsDirectory: URL

  public init(recordingsDirectory: URL) {
    self.recordingsDirectory = recordingsDirectory
  }

  public static func system(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> VoiceMemosLibrary {
    VoiceMemosLibrary(
      recordingsDirectory: homeDirectory
        .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    )
  }

  /// 按录制时间从新到旧列出录音。「最近删除」里的录音不列。
  public func recordings() throws -> [VoiceMemoRecording] {
    let fileManager = FileManager.default
    let fileNames: [String]
    do {
      fileNames = try fileManager.contentsOfDirectory(atPath: recordingsDirectory.path)
    } catch let error as NSError {
      if Self.isPermissionError(error) { throw VoiceMemosLibraryError.permissionDenied }
      // 目录本身不存在时，父目录存在但读不了同样意味着没授权。
      let container = recordingsDirectory.deletingLastPathComponent()
      if fileManager.fileExists(atPath: container.path),
         (try? fileManager.contentsOfDirectory(atPath: container.path)) == nil {
        throw VoiceMemosLibraryError.permissionDenied
      }
      throw VoiceMemosLibraryError.libraryNotFound
    }

    let audioFiles = fileNames.filter { Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    let fromDatabase = (try? databaseRecordings()) ?? nil
    let result: [VoiceMemoRecording]
    if let fromDatabase {
      result = fromDatabase
    } else {
      guard !audioFiles.isEmpty || fileNames.contains("CloudRecordings.db") else {
        if fileNames.isEmpty { return [] }
        throw VoiceMemosLibraryError.unreadable
      }
      result = audioFiles.map { name in
        let url = recordingsDirectory.appendingPathComponent(name, isDirectory: false)
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return VoiceMemoRecording(
          id: (name as NSString).deletingPathExtension,
          title: nil,
          recordedAt: date,
          durationSeconds: nil,
          fileURL: url
        )
      }
    }
    return result.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
  }

  /// 读不到或结构不认识时返回 nil，由调用方退回文件列表。
  func databaseRecordings() throws -> [VoiceMemoRecording]? {
    let database = recordingsDirectory.appendingPathComponent("CloudRecordings.db", isDirectory: false)
    guard FileManager.default.fileExists(atPath: database.path) else { return nil }

    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-voicememos-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    // 连同 -wal/-shm 一起复制：最新的几条录音常常还在 WAL 里没合并进主库。
    for suffix in ["", "-wal", "-shm"] {
      let source = URL(fileURLWithPath: database.path + suffix)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      let target = workspace.appendingPathComponent("CloudRecordings.db" + suffix, isDirectory: false)
      do {
        try FileManager.default.copyItem(at: source, to: target)
      } catch let error as NSError {
        if Self.isPermissionError(error) { throw VoiceMemosLibraryError.permissionDenied }
        if suffix.isEmpty { return nil }
      }
    }

    var handle: OpaquePointer?
    let path = workspace.appendingPathComponent("CloudRecordings.db", isDirectory: false).path
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
      sqlite3_close(handle)
      return nil
    }
    defer { sqlite3_close(db) }

    let columns = Self.columns(in: "ZCLOUDRECORDING", db: db)
    guard columns.contains("ZPATH") else { return nil }
    // 真正的标题在 ZENCRYPTEDTITLE（「录音 3」「滨文路」）。新系统的 ZCUSTOMLABEL 存的是
    // 录制时间的 ISO 串（2026-09-23 实测），排在前面会让每条录音都叫「2021-06-22T14:37:55Z」。
    let titleColumns = ["ZENCRYPTEDTITLE", "ZCUSTOMLABELFORSORTING", "ZCUSTOMLABEL"].filter(columns.contains)
    let select = [
      columns.contains("ZUNIQUEID") ? "ZUNIQUEID" : "NULL",
      "ZPATH",
      Self.titleExpression(titleColumns),
      columns.contains("ZDATE") ? "ZDATE" : "NULL",
      columns.contains("ZDURATION") ? "ZDURATION" : "NULL",
    ].joined(separator: ", ")
    // 「最近删除」里的录音带驱逐时间，用户已经丢掉的东西不该被收进素材库。
    let filter = columns.contains("ZEVICTIONDATE") ? "WHERE ZEVICTIONDATE IS NULL" : ""
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(select) FROM ZCLOUDRECORDING \(filter)", -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }

    var result: [VoiceMemoRecording] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let rawPath = Self.text(statement, 1), !rawPath.isEmpty else { continue }
      // 老版本存的是完整路径，新版本只存文件名；都只取最后一段，拼回录音目录。
      let fileName = (rawPath as NSString).lastPathComponent
      let fileURL = recordingsDirectory.appendingPathComponent(fileName, isDirectory: false)
      let id = Self.text(statement, 0).flatMap { $0.isEmpty ? nil : $0 }
        ?? (fileName as NSString).deletingPathExtension
      let recordedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
        ? nil
        : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
      let duration = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4)
      result.append(VoiceMemoRecording(
        id: id,
        title: Self.text(statement, 2),
        recordedAt: recordedAt,
        durationSeconds: duration,
        fileURL: fileURL
      ))
    }
    return result
  }

  /// SQLite 的 COALESCE 至少要两个参数；新旧系统上标题列可能只剩一个。
  static func titleExpression(_ columns: [String]) -> String {
    let parts = columns.map { "NULLIF(\($0), '')" }
    switch parts.count {
    case 0: return "NULL"
    case 1: return parts[0]
    default: return "COALESCE(\(parts.joined(separator: ", ")))"
    }
  }

  private static func columns(in table: String, db: OpaquePointer) -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return []
    }
    defer { sqlite3_finalize(statement) }
    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = text(statement, 1) { names.insert(name.uppercased()) }
    }
    return names
  }

  private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let raw = sqlite3_column_text(statement, index) else { return nil }
    let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  static func isPermissionError(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
    if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
    return false
  }
}
