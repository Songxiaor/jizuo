import XCTest
@testable import LinkDigestCore

/// 常用标签表（第二批）：数据目录小 JSON、过滤规则、候选的采纳 / 忽略、空表即旧行为。
final class FrequentTagListTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("freq-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private func tag(_ name: String) -> HistoryTag { HistoryTag(rawValue: name)! }

  func testMissingOrCorruptFileIsEmptyList() throws {
    let store = FrequentTagStore(directoryURL: directory)
    XCTAssertTrue(store.allowedNames.isEmpty)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appendingPathComponent(FrequentTagStore.fileName))
    XCTAssertTrue(store.allowedNames.isEmpty, "损坏当空表：回到原来的行为")
  }

  func testCorruptFileIsRenamedAsKeepsakeAndNotOverwrittenBySave() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(FrequentTagStore.fileName)
    try Data("not json".utf8).write(to: file)
    let store = FrequentTagStore(directoryURL: directory, now: { 1_700_000_000_000 })
    XCTAssertTrue(store.allowedNames.isEmpty)
    let backup = try XCTUnwrap(store.corruptBackupName, "要给界面一个可提示的名字")
    XCTAssertTrue(backup.hasPrefix(FrequentTagStore.fileName + ".corrupt-"), backup)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8), "not json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "坏文件已被改名挪走")
    try store.replaceTags(["AI"])
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8), "not json", "保存不覆盖留底")
    XCTAssertEqual(store.allowedNames, ["AI"])
  }

  func testEmptyListAcceptsEverythingUnchanged() {
    let result = FrequentTagPolicy.filter([tag("AI"), tag("随便什么")], allowed: [])
    XCTAssertEqual(result.accepted.map(\.name), ["AI", "随便什么"])
    XCTAssertTrue(result.rejected.isEmpty)
  }

  func testModelForbiddenTagsAreStrippedIncludingLiveSpeaker() {
    let names = ["自有", "外部", "已使用", "已归档", "真人口播", "AI"]
    XCTAssertEqual(FrequentTagPolicy.strippingModelForbidden(names: names), ["AI"])
    XCTAssertEqual(FrequentTagPolicy.strippingModelForbidden(names.map(tag)).map(\.name), ["AI"])
  }

  func testNonEmptyListRejectsOffListTagsButLetsReservedPass() {
    let result = FrequentTagPolicy.filter(
      [tag("ai 工具"), tag("冷门词"), tag("灵感"), tag(MaterialCatalog.liveSpeakerTagName)],
      allowed: ["AI 工具"]
    )
    XCTAssertEqual(result.accepted.map(\.name), ["AI 工具", "灵感", "真人口播"], "表内用表里的写法；保留标签放行")
    XCTAssertEqual(result.rejected.map(\.name), ["冷门词"])
  }

  func testReplaceTagsStripsReservedDuplicatesAndPersists() throws {
    let store = FrequentTagStore(directoryURL: directory)
    try store.replaceTags(["AI", "ai", "灵感", "真人口播", "Swift"])
    XCTAssertEqual(store.allowedNames, ["AI", "Swift"])
    XCTAssertEqual(FrequentTagStore(directoryURL: directory).allowedNames, ["AI", "Swift"], "新实例也读得到：确实落了盘")
  }

  func testSuggestionsCountSkipReservedListedAndDismissed() throws {
    let store = FrequentTagStore(directoryURL: directory, now: { 1_000 })
    try store.replaceTags(["AI"])
    store.recordSuggestions([tag("Swift"), tag("Swift"), tag("AI"), tag("灵感"), tag("真人口播")])
    var doc = store.load()
    XCTAssertEqual(doc.suggestions.map(\.name), ["Swift"])
    XCTAssertEqual(doc.suggestions.first?.count, 2)

    try store.dismissSuggestion(normalizedName: tag("Swift").normalizedName)
    store.recordSuggestions([tag("Swift")])
    doc = store.load()
    XCTAssertTrue(doc.suggestions.isEmpty, "忽略过的不再提议")
  }

  func testAcceptSuggestionMovesItIntoTheList() throws {
    let store = FrequentTagStore(directoryURL: directory)
    try store.replaceTags(["AI"])
    store.recordSuggestions([tag("Rust")])
    try store.acceptSuggestion(normalizedName: tag("Rust").normalizedName)
    let doc = store.load()
    XCTAssertEqual(doc.tags, ["AI", "Rust"])
    XCTAssertTrue(doc.suggestions.isEmpty)
  }

  func testListIsCappedAtMaximum() throws {
    let store = FrequentTagStore(directoryURL: directory)
    try store.replaceTags((0 ..< 300).map { "标签\($0)" })
    XCTAssertEqual(store.allowedNames.count, FrequentTagPolicy.maximumTags)
  }

  func testRestrictedPromptNamesTheListAndForbidsNewTags() {
    let text = FrequentTagPolicy.restrictedInstruction(allowed: ["AI", "Swift"])
    XCTAssertTrue(text.contains("AI, Swift"))
    XCTAssertTrue(text.contains("ONLY"))
    XCTAssertEqual(FrequentTagPolicy.restrictedInstruction(allowed: []), "")
  }

  func testReservedNamesIncludeMaterialTypesSystemMarkersAndLiveSpeaker() {
    for name in ["灵感", "观点", "案例", "金句", "数据", "选题", "已使用", "已归档", "真人口播"] {
      XCTAssertTrue(
        FrequentTagPolicy.isReserved(normalizedName: tag(name).normalizedName), "\(name) 应是保留标签"
      )
    }
    XCTAssertFalse(FrequentTagPolicy.isReserved(normalizedName: tag("AI").normalizedName))
  }
}
