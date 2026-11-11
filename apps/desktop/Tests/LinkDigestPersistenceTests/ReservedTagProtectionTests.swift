import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 保留标签（素材类型、系统标记、「真人口播」）在库层不能被改名、合并、删除，
/// 也不能被别的标签并进去——整理标签就算误给出方案，也伤不到它们。
final class ReservedTagProtectionTests: XCTestCase {
  func testReservedTagsRefuseRenameMergeDeleteAndMergeInto() throws {
    let root = URL(fileURLWithPath: "/private/tmp/linkdigest-reserved-tags-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: directory))
    defer { try? repository.database.close() }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let document = try LocalImportDocument.voiceMemo(recordingID: "R1", title: "t", recordedAt: Date(), durationSeconds: 30)
    let taskID = try repository.acceptCapture(.init(document: document, receivedAtMilliseconds: now)).taskID
    _ = try repository.addTags([MaterialCatalog.liveSpeakerTagName, "灵感", "AI"], to: taskID)

    let live = MaterialCatalog.liveSpeakerTagNormalizedName
    XCTAssertThrowsError(try repository.deleteTagEverywhere(normalizedName: live))
    XCTAssertThrowsError(try repository.renameTag(normalizedName: live, to: "别的"))
    XCTAssertThrowsError(try repository.renameTag(normalizedName: "ai", to: MaterialCatalog.liveSpeakerTagName))
    XCTAssertThrowsError(try repository.mergeTags([live], into: "别的"))
    XCTAssertThrowsError(try repository.mergeTags(["ai"], into: MaterialCatalog.liveSpeakerTagName))
    XCTAssertThrowsError(try repository.mergeTags(["灵感"], into: "别的"))

    let names = Set(try repository.detail(taskID: taskID).tags.map(\.name))
    XCTAssertEqual(names, [MaterialCatalog.liveSpeakerTagName, "灵感", "AI"], "被拒绝的操作一个都没生效")
  }
}
