import Foundation
import LinkDigestPersistence

struct DiagnosticExportReport: Sendable, Equatable {
  let archiveURL: URL
  let crashReportCount: Int
}

/// Builds an opt-in, local-only diagnostics archive. It never reads SQLite,
/// UserDefaults provider profiles, Keychain, browser data or network state.
struct DiagnosticExportService: @unchecked Sendable {
  private let fileManager: FileManager
  private let archiveTool: ZipArchiveTool
  private let now: @Sendable () -> Date
  private let bundle: Bundle
  private let processInfo: ProcessInfo
  private let crashReportsRoot: URL?

  init(
    fileManager: FileManager = .default,
    archiveTool: ZipArchiveTool = .init(),
    now: @escaping @Sendable () -> Date = Date.init,
    bundle: Bundle = .main,
    processInfo: ProcessInfo = .processInfo,
    crashReportsRoot: URL? = nil
  ) {
    self.fileManager = fileManager
    self.archiveTool = archiveTool
    self.now = now
    self.bundle = bundle
    self.processInfo = processInfo
    self.crashReportsRoot = crashReportsRoot
  }

  func export(to archiveURL: URL) throws -> DiagnosticExportReport {
    guard !fileManager.fileExists(atPath: archiveURL.path) else {
      throw LibraryBackupError.destinationExists
    }
    let workspace = fileManager.temporaryDirectory.appendingPathComponent(
      "linkdigest-diagnostics-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let root = workspace.appendingPathComponent("LinkDigestDiagnostics", isDirectory: true)
    defer { try? fileManager.removeItem(at: workspace) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let info = runtimeInformation()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(info).write(
      to: root.appendingPathComponent("runtime.json"),
      options: .withoutOverwriting
    )
    let readme = """
    这份诊断包由用户主动导出，包含汲作版本/build、macOS 版本、基础运行环境和近期崩溃报告。
    不包含 API Key、Cookie、Token、历史正文、摘要或完整 URL 列表，也不会自动上传。
    """
    try Data((readme + "\n").utf8).write(
      to: root.appendingPathComponent("README.txt"),
      options: .withoutOverwriting
    )

    let reports = try copyRecentCrashReports(into: root)
    try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try archiveTool.createArchive(from: root, at: archiveURL)
    } catch {
      try? fileManager.removeItem(at: archiveURL)
      throw error
    }
    return .init(archiveURL: archiveURL, crashReportCount: reports)
  }

  struct RuntimeInformation: Codable, Sendable, Equatable {
    let generatedAt: String
    let appVersion: String
    let appBuild: String
    let bundleIdentifier: String
    let macOS: String
    let architecture: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let localeIdentifier: String
  }

  private func runtimeInformation() -> RuntimeInformation {
    let info = bundle.infoDictionary
    return .init(
      generatedAt: Self.iso8601(now()),
      appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
      appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
      bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
      macOS: processInfo.operatingSystemVersionString,
      architecture: Self.architecture,
      processorCount: processInfo.processorCount,
      physicalMemoryBytes: processInfo.physicalMemory,
      localeIdentifier: Locale.current.identifier
    )
  }

  private func copyRecentCrashReports(into root: URL) throws -> Int {
    let reportsRoot = crashReportsRoot ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    guard fileManager.fileExists(atPath: reportsRoot.path) else { return 0 }
    let names = crashReportProcessNames().map { $0.lowercased() }
    let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
    let candidates = try fileManager.contentsOfDirectory(
      at: reportsRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url -> (url: URL, date: Date, size: Int)? in
      let lower = url.deletingPathExtension().lastPathComponent.lowercased()
      guard names.contains(where: {
        lower == $0 || lower.hasPrefix($0 + "_") || lower.hasPrefix($0 + "-")
      }) else { return nil }
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
      )
      guard values?.isRegularFile == true,
            values?.isSymbolicLink != true,
            let date = values?.contentModificationDate,
            date >= cutoff,
            let size = values?.fileSize,
            size > 0,
            size <= 10 * 1024 * 1024
      else { return nil }
      return (url, date, size)
    }.sorted { $0.date > $1.date }

    let destination = root.appendingPathComponent("CrashReports", isDirectory: true)
    var copied = 0
    var totalBytes = 0
    for candidate in candidates.prefix(10) {
      guard totalBytes + candidate.size <= 25 * 1024 * 1024 else { continue }
      guard let raw = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
      if copied == 0 {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
      }
      let sanitized = Self.redacted(raw, homeDirectory: fileManager.homeDirectoryForCurrentUser.path)
      try Data(sanitized.utf8).write(
        to: destination.appendingPathComponent(candidate.url.lastPathComponent),
        options: .withoutOverwriting
      )
      copied += 1
      totalBytes += candidate.size
    }
    return copied
  }

  private func crashReportProcessNames() -> Set<String> {
    var result: Set<String> = ["LinkDigestApp", "LinkDigest", "汲作"]
    if let executable = bundle.infoDictionary?["CFBundleExecutable"] as? String, !executable.isEmpty {
      result.insert(executable)
    }
    if let displayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !displayName.isEmpty {
      result.insert(displayName)
    }
    return result
  }

  static func redacted(_ value: String, homeDirectory: String) -> String {
    var result = value.replacingOccurrences(of: homeDirectory, with: "~")
    let patterns: [(String, String)] = [
      (#"(?i)https?://[^\s\"'<>\)]+"#, "<redacted-url>"),
      (#"(?i)bearer\s+[A-Za-z0-9._~+\-/]+=*"#, "Bearer <redacted-secret>"),
      (#"(?i)(authorization|api[_ -]?key|token|cookie)(\s*[\"':=]+\s*)[^\s\",}\]]+"#, "$1$2<redacted-secret>"),
      (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "<redacted-secret>"),
    ]
    for (pattern, replacement) in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }
    return result
  }

  private static var architecture: String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unknown"
    #endif
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
