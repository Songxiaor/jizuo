import Foundation
import XCTest
@testable import LinkDigestApp

final class BrowserExtensionFolderDeliveryTests: XCTestCase {
  private let fileManager = FileManager.default

  func testDeliverCopiesBundledExtensionToStableUserSelectableFolder() throws {
    let root = temporaryRoot()
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("BrowserExtension", isDirectory: true)
    let nested = source.appendingPathComponent("chunks", isDirectory: true)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"name":"汲作","version":"0.2.0"}"#.utf8)
      .write(to: source.appendingPathComponent("manifest.json"))
    try Data("first".utf8).write(to: nested.appendingPathComponent("background.js"))

    let destinationParent = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    let delivered = try BrowserExtensionFolderDelivery(fileManager: fileManager).deliver(
      source: source,
      destinationParent: destinationParent
    )

    XCTAssertEqual(delivered.lastPathComponent, "汲作浏览器扩展")
    XCTAssertTrue(fileManager.fileExists(atPath: delivered.appendingPathComponent("manifest.json").path))
    XCTAssertEqual(
      try String(contentsOf: delivered.appendingPathComponent("chunks/background.js"), encoding: .utf8),
      "first"
    )
  }

  func testDeliverAtomicallyReplacesAnOlderDeliveredCopy() throws {
    let root = temporaryRoot()
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("BrowserExtension", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"version":"0.2.0"}"#.utf8)
      .write(to: source.appendingPathComponent("manifest.json"))
    try Data("new".utf8).write(to: source.appendingPathComponent("background.js"))

    let destinationParent = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    let old = destinationParent.appendingPathComponent("汲作浏览器扩展", isDirectory: true)
    try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: old.appendingPathComponent("manifest.json"))
    try Data("stale".utf8).write(to: old.appendingPathComponent("obsolete.js"))

    let delivered = try BrowserExtensionFolderDelivery(fileManager: fileManager).deliver(
      source: source,
      destinationParent: destinationParent
    )

    XCTAssertEqual(
      try String(contentsOf: delivered.appendingPathComponent("background.js"), encoding: .utf8),
      "new"
    )
    XCTAssertFalse(fileManager.fileExists(atPath: delivered.appendingPathComponent("obsolete.js").path))
    let leftovers = try fileManager.contentsOfDirectory(atPath: destinationParent.path)
      .filter { $0.hasPrefix(".汲作浏览器扩展.") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testDeliverRejectsSymbolicLinksBeforeWritingDestination() throws {
    let root = temporaryRoot()
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("BrowserExtension", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
    try fileManager.createSymbolicLink(
      at: source.appendingPathComponent("unsafe"),
      withDestinationURL: source.appendingPathComponent("manifest.json")
    )
    let destinationParent = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)

    XCTAssertThrowsError(
      try BrowserExtensionFolderDelivery(fileManager: fileManager).deliver(
        source: source,
        destinationParent: destinationParent
      )
    )
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: destinationParent.appendingPathComponent("汲作浏览器扩展").path
      )
    )
  }

  private func temporaryRoot() -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(
      "linkdigest-browser-extension-delivery-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}
