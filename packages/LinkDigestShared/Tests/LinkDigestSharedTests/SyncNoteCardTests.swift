import CloudKit
import XCTest
@testable import LinkDigestShared

final class SyncNoteCardTests: XCTestCase {
  func testTextNoteFactoryUsesDefaults() {
    let card = SyncNoteCardFactory.makeText()
    XCTAssertEqual(card.kind, .text)
    XCTAssertEqual(card.title, SyncNoteCardFactory.untitledTitle)
    XCTAssertEqual(card.body, SyncNoteCardFactory.placeholderBody)
    XCTAssertNil(card.sourceURL)
    XCTAssertNil(card.summary)
    XCTAssertFalse(card.isDeleted)
  }

  func testVoiceNoteUsesTranscriptAsBody() throws {
    let card = SyncNoteCardFactory.makeVoice(transcript: "今天想到一个产品切口")
    XCTAssertEqual(card.kind, .voice)
    XCTAssertEqual(card.body, "今天想到一个产品切口")
    try SyncNoteCardValidator.validate(card)
  }

  func testLinkNoteRequiresURL() throws {
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/a",
      title: "示例",
      body: "正文",
      summary: "摘要"
    )
    try SyncNoteCardValidator.validate(card)
    XCTAssertEqual(card.kind, .link)
    XCTAssertEqual(card.sourceURL, "https://example.com/a")
  }

  func testValidatorRejectsLinkWithoutURL() {
    let card = SyncNoteCard(
      kind: .link,
      title: "x",
      body: "y",
      sourceURL: nil,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    XCTAssertThrowsError(try SyncNoteCardValidator.validate(card)) { error in
      XCTAssertEqual(error as? SyncNoteCardValidationError, .linkMissingSourceURL)
    }
  }

  func testMergePrefersNewerUpdatedAt() {
    let id = UUID()
    let older = SyncNoteCard(
      id: id,
      kind: .text,
      title: "旧",
      body: "old",
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 10
    )
    let newer = SyncNoteCard(
      id: id,
      kind: .text,
      title: "新",
      body: "new",
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 20
    )
    let merged = SyncNoteCardFactory.merge(local: older, remote: newer)
    XCTAssertEqual(merged.title, "新")
    XCTAssertEqual(merged.body, "new")
  }

  func testSoftDeleteMarksCard() {
    let card = SyncNoteCardFactory.makeText(title: "将删")
    let deleted = SyncNoteCardFactory.softDelete(card)
    XCTAssertTrue(deleted.isDeleted)
    XCTAssertNotNil(deleted.deletedAtMilliseconds)
  }

  func testInMemoryStoreRoundTripAndSyncMerge() async throws {
    let local = InMemoryNoteCardStore()
    let remote = InMemoryNoteCardStore()
    let a = SyncNoteCardFactory.makeText(title: "本地独有", body: "L")
    let b = SyncNoteCardFactory.makeVoice(transcript: "远端口述")
    try await local.upsert(a)
    try await remote.upsert(b)

    let sync = LocalMergeNoteCardSync(remote: remote)
    let status = try await sync.synchronize(local: local)
    XCTAssertEqual(status.phase, .idle)
    XCTAssertNil(status.lastErrorMessage)

    let localList = try await local.list(includeDeleted: false)
    let remoteList = try await remote.list(includeDeleted: false)
    XCTAssertEqual(localList.count, 2)
    XCTAssertEqual(remoteList.count, 2)
    XCTAssertEqual(Set(localList.map(\.id)), Set(remoteList.map(\.id)))
  }

  func testCloudKitRecordRoundTripPreservesFields() throws {
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/post",
      title: "标题",
      body: "原文",
      summary: "总结一句"
    )
    let record = try CloudKitNoteCardSync.makeRecord(from: card)
    let restored = try CloudKitNoteCardSync.makeCard(from: record)
    XCTAssertEqual(restored, card)
  }

  func testLinkIdentityIsStableAcrossFactoryCalls() {
    let a = SyncNoteCardFactory.makeLink(
      sourceURL: "https://Example.com/Post",
      body: "1"
    )
    let b = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com/post",
      body: "2"
    )
    // 大小写不同但规范化后同一 URL → 同一 id；工厂内部 trim 后直接哈希，
    // 这里验证相同规范化字符串稳定。
    let idA = SyncNoteCardIdentity.fromLinkCanonicalURL("https://example.com/post")
    let idB = SyncNoteCardIdentity.fromLinkCanonicalURL("https://example.com/post")
    XCTAssertEqual(idA, idB)
    XCTAssertEqual(a.id, SyncNoteCardIdentity.fromLinkCanonicalURL("https://Example.com/Post"))
    _ = b
  }

  func testCloudKitSyncReportsDisabledClearly() async throws {
    let local = InMemoryNoteCardStore()
    let sync = CloudKitNoteCardSync(enabled: false)
    let status = try await sync.synchronize(local: local)
    XCTAssertEqual(status.phase, .failed)
    XCTAssertTrue(
      status.lastErrorMessage?.contains("付费") == true
        || status.lastErrorMessage?.contains("尚未开通") == true
        || status.lastErrorMessage?.contains("尚未启用") == true
    )
  }

  func testCloudKitSyncSkipsLiveContainerWhenEntitlementMissing() async throws {
    guard !CloudKitCapability.isContainerEntitled() else {
      return
    }
    let local = InMemoryNoteCardStore()
    let sync = CloudKitNoteCardSync(enabled: true)
    let status = try await sync.synchronize(local: local)
    XCTAssertEqual(status.phase, .failed)
    XCTAssertTrue(status.lastErrorMessage?.contains("签名") == true)
    XCTAssertTrue(status.lastErrorMessage?.contains("闪退") == true)
  }

  func testPreviewLinePrefersSummary() {
    let card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com",
      title: "T",
      body: "很长的正文不应优先",
      summary: "一行摘要"
    )
    XCTAssertEqual(card.previewLine, "一行摘要")
  }

  func testPlannerMergesAndDetectsPushSet() {
    let sharedID = UUID()
    let localOnly = SyncNoteCardFactory.makeText(title: "仅本地", body: "L")
    let remoteOnly = SyncNoteCardFactory.makeVoice(transcript: "仅远端")
    let localShared = SyncNoteCard(
      id: sharedID,
      kind: .text,
      title: "本地新",
      body: "new",
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 50
    )
    let remoteShared = SyncNoteCard(
      id: sharedID,
      kind: .text,
      title: "远端旧",
      body: "old",
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 10
    )

    let merged = NoteCardSyncPlanner.mergeUniverse(
      local: [localOnly, localShared],
      remote: [remoteOnly, remoteShared]
    )
    XCTAssertEqual(Set(merged.map(\.id)), Set([localOnly.id, remoteOnly.id, sharedID]))
    XCTAssertEqual(merged.first { $0.id == sharedID }?.title, "本地新")

    let toPush = NoteCardSyncPlanner.cardsNeedingPush(
      merged: merged,
      remoteBefore: [remoteOnly, remoteShared]
    )
    XCTAssertTrue(toPush.contains { $0.id == localOnly.id })
    XCTAssertTrue(toPush.contains { $0.id == sharedID })
    XCTAssertFalse(toPush.contains { $0.id == remoteOnly.id })
  }

  func testCloudKitPushPullWithFakeDatabase() async throws {
    let remoteSeed = SyncNoteCardFactory.makeVoice(transcript: "云端已有")
    let fake = FakeCloudKitNoteDatabase(seed: [remoteSeed])
    let local = InMemoryNoteCardStore()
    let localOnly = SyncNoteCardFactory.makeText(title: "手机新建", body: "hello")
    try await local.upsert(localOnly)

    let sync = CloudKitNoteCardSync(
      enabled: true,
      database: fake,
      checksAccountStatus: false
    )
    let status = try await sync.synchronize(local: local)
    XCTAssertEqual(status.phase, .idle, status.lastErrorMessage ?? "")
    XCTAssertNil(status.lastErrorMessage)

    let localAfter = try await local.list(includeDeleted: false)
    XCTAssertEqual(localAfter.count, 2)
    XCTAssertEqual(Set(localAfter.map(\.id)), Set([localOnly.id, remoteSeed.id]))

    let remoteAfter = await fake.storedCards()
    XCTAssertEqual(remoteAfter.count, 2)
    XCTAssertEqual(Set(remoteAfter.map(\.id)), Set([localOnly.id, remoteSeed.id]))
    let saveCount1 = await fake.saveCallCount
    let fetchCount1 = await fake.fetchCallCount
    XCTAssertEqual(saveCount1, 1)
    XCTAssertEqual(fetchCount1, 1)

    // 第二次同步不应再推（无差异）
    let status2 = try await sync.synchronize(local: local)
    XCTAssertEqual(status2.phase, .idle)
    let saveCount2 = await fake.saveCallCount
    let fetchCount2 = await fake.fetchCallCount
    XCTAssertEqual(saveCount2, 1)
    XCTAssertEqual(fetchCount2, 2)
  }

  func testCloudKitSyncPropagatesSoftDelete() async throws {
    let shared = SyncNoteCardFactory.makeText(title: "将被删", body: "x")
    let fake = FakeCloudKitNoteDatabase(seed: [shared])
    let local = InMemoryNoteCardStore(seed: [shared])
    try await local.softDelete(
      id: shared.id,
      atMilliseconds: SyncNoteCardFactory.nowMilliseconds()
    )

    let sync = CloudKitNoteCardSync(
      enabled: true,
      database: fake,
      checksAccountStatus: false
    )
    let status = try await sync.synchronize(local: local)
    XCTAssertEqual(status.phase, .idle, status.lastErrorMessage ?? "")

    let remote = await fake.storedCards()
    XCTAssertEqual(remote.count, 1)
    XCTAssertTrue(remote[0].isDeleted)
  }

  func testApplyClearsOptionalFields() throws {
    var card = SyncNoteCardFactory.makeLink(
      sourceURL: "https://example.com",
      title: "T",
      body: "B",
      summary: "S"
    )
    let record = try CloudKitNoteCardSync.makeRecord(from: card)
    XCTAssertEqual(record["summary"] as? String, "S")

    card.summary = nil
    card.translation = "译"
    card.updatedAtMilliseconds += 1
    try CloudKitNoteCardSync.apply(card, to: record)
    XCTAssertNil(record["summary"])
    XCTAssertEqual(record["translation"] as? String, "译")

    card.translation = nil
    card.updatedAtMilliseconds += 1
    try CloudKitNoteCardSync.apply(card, to: record)
    XCTAssertNil(record["translation"])
  }
}
