import CryptoKit
import Foundation

public enum LibraryBackupError: Error, LocalizedError, Sendable, Equatable {
  case destinationExists
  case invalidArchive
  case unsupportedFormat
  case checksumMismatch
  case unsafeArchiveEntry
  case archiveToolFailed
  case restoreAlreadyPending
  case noDatabase
  case restoreFailed

  public var errorDescription: String? {
    switch self {
    case .destinationExists: "目标位置已有同名文件，请换一个位置。"
    case .invalidArchive: "这不是有效的汲作备份文件。"
    case .unsupportedFormat: "这份备份由不兼容的版本创建，当前无法恢复。"
    case .checksumMismatch: "备份内容校验失败，文件可能不完整或已被修改。"
    case .unsafeArchiveEntry: "备份里包含不安全的文件路径，已停止恢复。"
    case .archiveToolFailed: "系统压缩工具未能完成操作。"
    case .restoreAlreadyPending: "已有一次恢复等待重启，请先退出并重新打开汲作。"
    case .noDatabase: "没有找到可备份的本地历史库。"
    case .restoreFailed: "恢复未完成，当前资料已保留。"
    }
  }
}

public struct LibraryBackupManifest: Codable, Sendable, Equatable {
  public static let currentFormatVersion = 1

  public struct DatabaseEntry: Codable, Sendable, Equatable {
    public let path: String
    public let byteCount: Int64
    public let sha256: String
    public let schemaVersion: Int
  }

  public struct MediaEntry: Codable, Sendable, Equatable {
    public let path: String
    public let byteCount: Int64
    public let sha256: String
  }

  public let formatVersion: Int
  public let createdAt: String
  public let appVersion: String
  public let appBuild: String
  public let database: DatabaseEntry
  public let media: [MediaEntry]

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    createdAt: String,
    appVersion: String,
    appBuild: String,
    database: DatabaseEntry,
    media: [MediaEntry]
  ) {
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.database = database
    self.media = media
  }
}

public struct LibraryBackupInspection: Sendable, Equatable {
  public let manifest: LibraryBackupManifest
  public let database: DatabaseBackupValidation

  public init(manifest: LibraryBackupManifest, database: DatabaseBackupValidation) {
    self.manifest = manifest
    self.database = database
  }
}

public struct ScheduledLibraryRestore: Sendable, Equatable {
  public let automaticBackupURL: URL
  public let itemCount: Int

  public init(automaticBackupURL: URL, itemCount: Int) {
    self.automaticBackupURL = automaticBackupURL
    self.itemCount = itemCount
  }
}

public struct AppliedLibraryRestore: Sendable, Equatable {
  public let automaticBackupURL: URL
  public let itemCount: Int

  public init(automaticBackupURL: URL, itemCount: Int) {
    self.automaticBackupURL = automaticBackupURL
    self.itemCount = itemCount
  }
}

public struct ZipArchiveTool: Sendable {
  public init() {}

  public func createArchive(from directoryURL: URL, at archiveURL: URL) throws {
    try run([
      "-c", "-k", "--norsrc", "--keepParent", directoryURL.path, archiveURL.path,
    ])
  }

  public func extractArchive(at archiveURL: URL, to directoryURL: URL) throws {
    try run(["-x", "-k", archiveURL.path, directoryURL.path])
  }

  private func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw LibraryBackupError.archiveToolFailed
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw LibraryBackupError.archiveToolFailed
    }
  }
}

/// Creates WAL-consistent library archives and stages restores for the next App
/// launch. A running process never replaces the SQLite files it currently owns.
public struct LibraryBackupManager: @unchecked Sendable {
  public static let archiveExtension = "linkdigestbackup"
  private static let bundleDirectoryName = "LinkDigestBackup"
  private static let databaseRelativePath = "database/history.sqlite"
  private static let pendingDirectoryName = ".pending-library-restore"
  private static let markerName = "restore.json"

  private struct PendingMarker: Codable, Sendable {
    let automaticBackupPath: String
    let scheduledAt: String
  }

  private let applicationSupportRoot: URL
  private let fileManager: FileManager
  private let archiveTool: ZipArchiveTool
  private let now: @Sendable () -> Date
  private let appVersion: @Sendable () -> (version: String, build: String)

  public init(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default,
    archiveTool: ZipArchiveTool = .init(),
    now: @escaping @Sendable () -> Date = Date.init,
    appVersion: @escaping @Sendable () -> (version: String, build: String) = {
      let info = Bundle.main.infoDictionary
      return (
        info?["CFBundleShortVersionString"] as? String ?? "unknown",
        info?["CFBundleVersion"] as? String ?? "unknown"
      )
    }
  ) {
    self.applicationSupportRoot = applicationSupportRoot
    self.fileManager = fileManager
    self.archiveTool = archiveTool
    self.now = now
    self.appVersion = appVersion
  }

  public var libraryDirectoryURL: URL {
    applicationSupportRoot.appendingPathComponent("LinkDigest", isDirectory: true)
  }

  public var automaticBackupsDirectoryURL: URL {
    applicationSupportRoot.appendingPathComponent("LinkDigest Backups", isDirectory: true)
  }

  public func suggestedBackupFilename(prefix: String = "汲作备份") -> String {
    "\(prefix)-\(Self.filenameTimestamp(now())).\(Self.archiveExtension)"
  }

  @discardableResult
  public func createBackup(at archiveURL: URL) throws -> LibraryBackupInspection {
    guard !fileManager.fileExists(atPath: archiveURL.path) else {
      throw LibraryBackupError.destinationExists
    }
    let location = LocalDatabaseLocation(applicationSupportRoot: applicationSupportRoot)
    guard fileManager.fileExists(atPath: location.databaseURL.path) else {
      throw LibraryBackupError.noDatabase
    }

    let workspace = try makeWorkspace(prefix: "linkdigest-backup")
    defer { try? fileManager.removeItem(at: workspace) }
    let bundle = workspace.appendingPathComponent(Self.bundleDirectoryName, isDirectory: true)
    let databaseDirectory = bundle.appendingPathComponent("database", isDirectory: true)
    try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    let snapshotURL = bundle.appendingPathComponent(Self.databaseRelativePath)

    let source = try LocalDatabase.open(at: location)
    defer { try? source.close() }
    let maintenance = DatabaseMaintenance(database: source)
    // PASSIVE never blocks writers. Even if an active reader keeps frames in the
    // WAL, GRDB's online backup below reads one consistent committed snapshot.
    _ = try? maintenance.passiveCheckpoint()
    _ = try maintenance.backup(to: snapshotURL)
    let databaseValidation = try DatabaseMaintenance.validateBackup(at: snapshotURL)
    // Opening a WAL-mode SQLite snapshot read-only may materialize a sibling
    // `-shm`. It is runtime coordination state, not backup content; the verified
    // base file already contains the complete online-backup snapshot.
    try? fileManager.removeItem(at: URL(fileURLWithPath: snapshotURL.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: snapshotURL.path + "-shm"))

    let media = try copyInternalMedia(into: bundle)
    let databaseValues = try regularFileValues(snapshotURL)
    let version = appVersion()
    let manifest = LibraryBackupManifest(
      createdAt: Self.iso8601(now()),
      appVersion: version.version,
      appBuild: version.build,
      database: .init(
        path: Self.databaseRelativePath,
        byteCount: databaseValues.byteCount,
        sha256: try sha256(snapshotURL),
        schemaVersion: databaseValidation.schemaVersion
      ),
      media: media
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(
      to: bundle.appendingPathComponent("manifest.json"),
      options: .withoutOverwriting
    )
    try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try archiveTool.createArchive(from: bundle, at: archiveURL)
      return try inspectBackup(at: archiveURL)
    } catch {
      try? fileManager.removeItem(at: archiveURL)
      throw error
    }
  }

  public func inspectBackup(at archiveURL: URL) throws -> LibraryBackupInspection {
    let archiveValues = try regularFileValues(archiveURL)
    guard archiveValues.byteCount > 0 else { throw LibraryBackupError.invalidArchive }
    let workspace = try makeWorkspace(prefix: "linkdigest-inspect")
    defer { try? fileManager.removeItem(at: workspace) }
    do {
      try archiveTool.extractArchive(at: archiveURL, to: workspace)
      return try validateExtractedBundle(
        workspace.appendingPathComponent(Self.bundleDirectoryName, isDirectory: true)
      )
    } catch let error as LibraryBackupError {
      throw error
    } catch {
      throw LibraryBackupError.invalidArchive
    }
  }

  /// Validates the chosen archive, creates a separate automatic backup of the
  /// current library, then atomically publishes a pending restore directory.
  public func scheduleRestore(from archiveURL: URL) throws -> ScheduledLibraryRestore {
    let pending = libraryDirectoryURL.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
    guard !fileManager.fileExists(atPath: pending.path) else {
      throw LibraryBackupError.restoreAlreadyPending
    }
    let inspection = try inspectBackup(at: archiveURL)
    try fileManager.createDirectory(at: automaticBackupsDirectoryURL, withIntermediateDirectories: true)
    let automaticBackupURL = automaticBackupsDirectoryURL.appendingPathComponent(
      suggestedBackupFilename(prefix: "汲作恢复前自动备份")
    )
    _ = try createBackup(at: automaticBackupURL)

    let extraction = try makeWorkspace(prefix: "linkdigest-restore-source")
    defer { try? fileManager.removeItem(at: extraction) }
    try archiveTool.extractArchive(at: archiveURL, to: extraction)
    let bundle = extraction.appendingPathComponent(Self.bundleDirectoryName, isDirectory: true)
    _ = try validateExtractedBundle(bundle)

    let staging = libraryDirectoryURL.appendingPathComponent(
      ".pending-library-restore-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    try fileManager.copyItem(at: bundle, to: staging.appendingPathComponent(Self.bundleDirectoryName))
    let marker = PendingMarker(
      automaticBackupPath: automaticBackupURL.path,
      scheduledAt: Self.iso8601(now())
    )
    try JSONEncoder().encode(marker).write(
      to: staging.appendingPathComponent(Self.markerName),
      options: .withoutOverwriting
    )
    try fileManager.moveItem(at: staging, to: pending)
    return .init(
      automaticBackupURL: automaticBackupURL,
      itemCount: inspection.database.counts.tasks
    )
  }

  /// Runs before AppComposition opens SQLite. Existing data is first moved to a
  /// rollback directory; any installation or verification failure moves it back.
  public func applyPendingRestoreIfNeeded() throws -> AppliedLibraryRestore? {
    let pending = libraryDirectoryURL.appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
    guard fileManager.fileExists(atPath: pending.path) else { return nil }
    let markerURL = pending.appendingPathComponent(Self.markerName)
    let marker: PendingMarker
    do {
      marker = try JSONDecoder().decode(PendingMarker.self, from: Data(contentsOf: markerURL))
    } catch {
      throw LibraryBackupError.restoreFailed
    }
    let bundle = pending.appendingPathComponent(Self.bundleDirectoryName, isDirectory: true)
    let inspection = try validateExtractedBundle(bundle)

    let rollback = libraryDirectoryURL.appendingPathComponent(
      ".restore-rollback-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try fileManager.createDirectory(at: rollback, withIntermediateDirectories: false)
    let liveDatabase = libraryDirectoryURL.appendingPathComponent("history.sqlite")
    let liveWAL = libraryDirectoryURL.appendingPathComponent("history.sqlite-wal")
    let liveSHM = libraryDirectoryURL.appendingPathComponent("history.sqlite-shm")
    let liveMedia = libraryDirectoryURL.appendingPathComponent("Media", isDirectory: true)
    let liveItems = [liveDatabase, liveWAL, liveSHM, liveMedia]

    do {
      for item in liveItems where fileManager.fileExists(atPath: item.path) {
        try fileManager.moveItem(at: item, to: rollback.appendingPathComponent(item.lastPathComponent))
      }
      try fileManager.copyItem(
        at: bundle.appendingPathComponent(Self.databaseRelativePath),
        to: liveDatabase
      )
      let archivedMedia = bundle.appendingPathComponent("Media", isDirectory: true)
      if fileManager.fileExists(atPath: archivedMedia.path) {
        try fileManager.copyItem(at: archivedMedia, to: liveMedia)
      } else {
        try fileManager.createDirectory(at: liveMedia, withIntermediateDirectories: false)
      }
      _ = try DatabaseMaintenance.validateBackup(at: liveDatabase)
    } catch {
      for item in liveItems where fileManager.fileExists(atPath: item.path) {
        try? fileManager.removeItem(at: item)
      }
      for item in liveItems {
        let saved = rollback.appendingPathComponent(item.lastPathComponent)
        if fileManager.fileExists(atPath: saved.path) {
          try? fileManager.moveItem(at: saved, to: item)
        }
      }
      try? fileManager.removeItem(at: rollback)
      throw LibraryBackupError.restoreFailed
    }

    try? fileManager.removeItem(at: rollback)
    try? fileManager.removeItem(at: pending)
    return .init(
      automaticBackupURL: URL(fileURLWithPath: marker.automaticBackupPath),
      itemCount: inspection.database.counts.tasks
    )
  }

  private func validateExtractedBundle(_ bundle: URL) throws -> LibraryBackupInspection {
    let values = try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isDirectory == true, values?.isSymbolicLink != true else {
      throw LibraryBackupError.invalidArchive
    }
    let manifestURL = bundle.appendingPathComponent("manifest.json")
    let manifest: LibraryBackupManifest
    do {
      manifest = try JSONDecoder().decode(
        LibraryBackupManifest.self,
        from: Data(contentsOf: manifestURL)
      )
    } catch {
      throw LibraryBackupError.invalidArchive
    }
    guard manifest.formatVersion == LibraryBackupManifest.currentFormatVersion,
          manifest.database.path == Self.databaseRelativePath
    else { throw LibraryBackupError.unsupportedFormat }

    var expectedFiles: Set<String> = ["manifest.json", Self.databaseRelativePath]
    var seenMediaPaths = Set<String>()
    for entry in manifest.media {
      guard Self.isSafeMediaPath(entry.path), seenMediaPaths.insert(entry.path).inserted else {
        throw LibraryBackupError.unsafeArchiveEntry
      }
      expectedFiles.insert(entry.path)
    }
    let actualFiles = try regularFilesRecursively(in: bundle)
    guard actualFiles == expectedFiles else { throw LibraryBackupError.unsafeArchiveEntry }

    let databaseURL = bundle.appendingPathComponent(manifest.database.path)
    try verify(
      databaseURL,
      expectedByteCount: manifest.database.byteCount,
      expectedSHA256: manifest.database.sha256
    )
    let database = try DatabaseMaintenance.validateBackup(at: databaseURL)
    guard database.schemaVersion == manifest.database.schemaVersion else {
      throw LibraryBackupError.checksumMismatch
    }
    for entry in manifest.media {
      try verify(
        bundle.appendingPathComponent(entry.path),
        expectedByteCount: entry.byteCount,
        expectedSHA256: entry.sha256
      )
    }
    return .init(manifest: manifest, database: database)
  }

  private func copyInternalMedia(into bundle: URL) throws -> [LibraryBackupManifest.MediaEntry] {
    let source = libraryDirectoryURL.appendingPathComponent("Media", isDirectory: true)
    guard fileManager.fileExists(atPath: source.path) else { return [] }
    let destination = bundle.appendingPathComponent("Media", isDirectory: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
    var entries: [LibraryBackupManifest.MediaEntry] = []
    for sourceURL in try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      // LocalMediaStore writes an in-progress `.linkdigest-*.tmp` before its
      // atomic move. Hidden temporary files are never durable media assets.
      options: [.skipsHiddenFiles]
    ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
        throw LibraryBackupError.unsafeArchiveEntry
      }
      let relativePath = "Media/\(sourceURL.lastPathComponent)"
      guard Self.isSafeMediaPath(relativePath) else { throw LibraryBackupError.unsafeArchiveEntry }
      let target = destination.appendingPathComponent(sourceURL.lastPathComponent)
      try fileManager.copyItem(at: sourceURL, to: target)
      let fileValues = try regularFileValues(target)
      entries.append(.init(
        path: relativePath,
        byteCount: fileValues.byteCount,
        sha256: try sha256(target)
      ))
    }
    return entries
  }

  private func regularFilesRecursively(in root: URL) throws -> Set<String> {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [],
      errorHandler: { _, _ in false }
    ) else { throw LibraryBackupError.invalidArchive }
    var files = Set<String>()
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isSymbolicLink != true else { throw LibraryBackupError.unsafeArchiveEntry }
      if values?.isRegularFile == true {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(rootPrefix) else { throw LibraryBackupError.unsafeArchiveEntry }
        files.insert(String(resolvedURL.path.dropFirst(rootPrefix.count)))
      } else if values?.isDirectory != true {
        throw LibraryBackupError.unsafeArchiveEntry
      }
    }
    return files
  }

  private func verify(_ url: URL, expectedByteCount: Int64, expectedSHA256: String) throws {
    let values = try regularFileValues(url)
    guard values.byteCount == expectedByteCount,
          try sha256(url) == expectedSHA256.lowercased()
    else { throw LibraryBackupError.checksumMismatch }
  }

  private func regularFileValues(_ url: URL) throws -> (byteCount: Int64, isRegular: Bool) {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw LibraryBackupError.invalidArchive
    }
    return (Int64(values?.fileSize ?? -1), true)
  }

  private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func makeWorkspace(prefix: String) throws -> URL {
    let url = fileManager.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private static func isSafeMediaPath(_ value: String) -> Bool {
    guard value.hasPrefix("Media/"), !value.hasPrefix("/"), !value.contains("\\") else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return components.count == 2
      && components[0] == "Media"
      && !components[1].isEmpty
      && components[1] != "."
      && components[1] != ".."
  }

  private static func filenameTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
