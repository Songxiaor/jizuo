import XCTest
import LinkDigestCore

final class KnownNameStoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("known-names-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: dir) }

  func testAddRemoveAndPersist() {
    let store = KnownNameStore(directoryURL: dir)
    XCTAssertEqual(store.add("张总", source: .manual), .added)
    XCTAssertEqual(store.add(" 张总 ", source: .speakerRename), .alreadyListed)
    XCTAssertEqual(store.add("   ", source: .manual), .invalid)
    XCTAssertEqual(KnownNameStore(directoryURL: dir).names, ["张总"])
    XCTAssertTrue(store.contains("张总"))
    XCTAssertTrue(store.remove("张总"))
    XCTAssertFalse(store.remove("张总"))
    XCTAssertEqual(KnownNameStore(directoryURL: dir).names, [])
  }

  func testCapsAtTwoHundred() {
    let store = KnownNameStore(directoryURL: dir)
    for index in 0..<KnownNamePolicy.maximumNames {
      XCTAssertEqual(store.add("名字\(index)", source: .manual), .added)
    }
    XCTAssertEqual(store.add("多出来的", source: .manual), .full)
    XCTAssertEqual(store.names.count, 200)
  }

  func testCorruptFileIsRenamedAndKept() throws {
    let file = dir.appendingPathComponent(KnownNameStore.fileName)
    try Data("{不是 json".utf8).write(to: file)
    let store = KnownNameStore(directoryURL: dir)
    XCTAssertEqual(store.names, [])
    let backup = try XCTUnwrap(store.corruptBackupName)
    XCTAssertTrue(backup.hasPrefix("known-names.json.corrupt-"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(backup).path))
    XCTAssertEqual(store.add("李老师", source: .manual), .added)
    XCTAssertEqual(KnownNameStore(directoryURL: dir).names, ["李老师"])
  }

  func testWriteFailureIsItsOwnResultAndNothingIsRemembered() throws {
    let blocker = dir.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: blocker)
    let store = KnownNameStore(directoryURL: blocker)
    XCTAssertEqual(store.add("张总", source: .manual), .writeFailed)
    XCTAssertEqual(store.add("   ", source: .manual), .invalid, "空名字仍是 invalid，两种说法不混")
    XCTAssertFalse(store.contains("张总"))
  }

  func testNamesAreServedFromMemoryAfterFirstRead() throws {
    let store = KnownNameStore(directoryURL: dir)
    XCTAssertEqual(store.add("张总", source: .manual), .added)
    try Data("garbage".utf8).write(to: dir.appendingPathComponent(KnownNameStore.fileName))
    XCTAssertTrue(store.contains("张总"))
    XCTAssertNil(store.corruptBackupName)
  }
}
