import XCTest
import LinkDigestPersistence
@testable import LinkDigestApp

final class DiagnosticExportServiceTests: XCTestCase {
  func testCrashReportRedactionRemovesHomeURLsAndCommonSecrets() {
    let raw = """
    path=/Users/example/Library/Application Support/LinkDigest
    page=https://example.test/private/article?id=42
    Authorization: Bearer abc.def.ghi
    api_key=sk-1234567890abcdefghijkl
    cookie: session-secret-value
    """
    let redacted = DiagnosticExportService.redacted(raw, homeDirectory: "/Users/example")
    XCTAssertFalse(redacted.contains("/Users/example"))
    XCTAssertFalse(redacted.contains("https://example.test"))
    XCTAssertFalse(redacted.contains("abc.def.ghi"))
    XCTAssertFalse(redacted.contains("sk-1234567890abcdefghijkl"))
    XCTAssertFalse(redacted.contains("session-secret-value"))
    XCTAssertTrue(redacted.contains("<redacted-url>"))
    XCTAssertTrue(redacted.contains("<redacted-secret>"))
  }

  func testDiagnosticArchiveContainsOnlyDeclaredFilesAndSanitizedCrashReport() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "linkdigest-diagnostic-tests-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let reports = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
    try fileManager.createDirectory(at: reports, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let crash = reports.appendingPathComponent("LinkDigestApp-2026-08-14-120000.ips")
    try Data("page=https://private.example/item\napi_key=sk-1234567890abcdefghijkl\n".utf8)
      .write(to: crash)
    try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: crash.path)

    let archive = root.appendingPathComponent("diagnostics.zip")
    let service = DiagnosticExportService(
      now: { now },
      crashReportsRoot: reports
    )
    let report = try service.export(to: archive)
    XCTAssertEqual(report.crashReportCount, 1)

    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
    try ZipArchiveTool().extractArchive(at: archive, to: extracted)
    let bundle = extracted.appendingPathComponent("LinkDigestDiagnostics", isDirectory: true)
    XCTAssertEqual(
      Set(try fileManager.contentsOfDirectory(atPath: bundle.path)),
      Set(["CrashReports", "README.txt", "runtime.json"])
    )
    let sanitized = try String(
      contentsOf: bundle.appendingPathComponent("CrashReports/\(crash.lastPathComponent)"),
      encoding: .utf8
    )
    XCTAssertFalse(sanitized.contains("private.example"))
    XCTAssertFalse(sanitized.contains("sk-1234567890abcdefghijkl"))
  }
}
