import XCTest
import LinkDigestCore

final class TranscriptDoubtStoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("doubts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: dir) }

  func testDoubtsSurviveReloadAndStatusChanges() {
    let store = TranscriptDoubtStore(directoryURL: dir)
    let a = TranscriptDoubt(id: "a", original: "奥利克", suggestion: "欧立克", reason: "")
    let b = TranscriptDoubt(id: "b", original: "张葱", suggestion: "张聪", reason: "")
    store.replace(taskID: "t1", doubts: [a, b], changeCount: 5)
    store.setStatus(taskID: "t1", doubtID: "a", status: .adopted)
    let reloaded = TranscriptDoubtStore(directoryURL: dir).entry(taskID: "t1")
    XCTAssertEqual(reloaded?.changeCount, 5)
    XCTAssertEqual(reloaded?.doubts.map(\.status), [.adopted, .pending])
    XCTAssertEqual(reloaded?.pending.map(\.id), ["b"])
    store.setStatus(taskID: "t1", doubtIDs: ["b"], status: .kept)
    XCTAssertEqual(store.entry(taskID: "t1")?.pending.count, 0)
    store.remove(taskID: "t1")
    XCTAssertNil(store.entry(taskID: "t1"))
  }

  func testCorruptFileIsRenamed() throws {
    try Data("坏的".utf8).write(to: dir.appendingPathComponent(TranscriptDoubtStore.fileName))
    let store = TranscriptDoubtStore(directoryURL: dir)
    XCTAssertNil(store.entry(taskID: "x"))
    XCTAssertNotNil(store.corruptBackupName)
  }

  func testPruneKeepsOnlyExistingTasks() {
    let store = TranscriptDoubtStore(directoryURL: dir)
    let doubt = TranscriptDoubt(id: "a", original: "奥利克", suggestion: "欧立克", reason: "")
    for id in ["t1", "t2", "t3"] { store.replace(taskID: id, doubts: [doubt], changeCount: 1) }
    XCTAssertEqual(store.prune(keeping: ["t2"]), 2)
    XCTAssertEqual(store.taskIDs, ["t2"])
    XCTAssertEqual(TranscriptDoubtStore(directoryURL: dir).taskIDs, ["t2"], "写进了文件")
    XCTAssertEqual(store.prune(keeping: ["t2"]), 0)
  }

  func testOverflowEvictsMissingTasksThenFinishedThenOldest() {
    let clock = Clock()
    let store = TranscriptDoubtStore(directoryURL: dir, now: { clock.tick() })
    let pending = TranscriptDoubt(id: "p", original: "奥利克", suggestion: "欧立克", reason: "")
    var done = pending
    done.status = .kept
    // 填满 500 条：t0 最旧（有待处理），t1 已处理完，t2 记录已不存在（有待处理，且比 t0、t1 都新）。
    store.replace(taskID: "t0", doubts: [pending], changeCount: 1)
    store.replace(taskID: "t1", doubts: [done], changeCount: 1)
    store.replace(taskID: "t2", doubts: [pending], changeCount: 1)
    for index in 3..<TranscriptDoubtStore.maximumTasks {
      store.replace(taskID: "t\(index)", doubts: [pending], changeCount: 1)
    }
    XCTAssertEqual(store.taskIDs.count, TranscriptDoubtStore.maximumTasks)
    let live = Set((0..<TranscriptDoubtStore.maximumTasks).map { "t\($0)" }).subtracting(["t2"])

    store.replace(taskID: "n1", doubts: [pending], changeCount: 1) { live.union(["n1"]) }
    XCTAssertNil(store.entry(taskID: "t2"), "先删已经不存在的记录，哪怕它比别的新")
    XCTAssertNotNil(store.entry(taskID: "t0"))
    XCTAssertNotNil(store.entry(taskID: "t1"))

    store.replace(taskID: "n2", doubts: [pending], changeCount: 1) { live.union(["n1", "n2"]) }
    XCTAssertNil(store.entry(taskID: "t1"), "其次删没有待处理项的，哪怕最旧的是有待处理的 t0")
    XCTAssertNotNil(store.entry(taskID: "t0"))

    store.replace(taskID: "n3", doubts: [pending], changeCount: 1) { live.union(["n1", "n2", "n3"]) }
    XCTAssertNil(store.entry(taskID: "t0"), "都有待处理项时才按时间删最旧的")
    XCTAssertNotNil(store.entry(taskID: "n3"), "刚写入的这条永远留着")
    XCTAssertEqual(store.taskIDs.count, TranscriptDoubtStore.maximumTasks)
  }

  func testEntriesAreServedFromMemoryAfterFirstRead() throws {
    let store = TranscriptDoubtStore(directoryURL: dir)
    store.replace(taskID: "t1", doubts: [.init(id: "a", original: "奥利克", suggestion: "欧立克", reason: "")], changeCount: 1)
    // 文件在外面被弄坏：已经读进内存的不再每次读盘，也不会被当成坏文件改名。
    let file = dir.appendingPathComponent(TranscriptDoubtStore.fileName)
    try Data("garbage".utf8).write(to: file)
    XCTAssertNotNil(store.entry(taskID: "t1"))
    XCTAssertNil(store.corruptBackupName)
    // 下一次写入会把内存里的状态写回去。
    store.setStatus(taskID: "t1", doubtID: "a", status: .kept)
    XCTAssertEqual(TranscriptDoubtStore(directoryURL: dir).entry(taskID: "t1")?.doubts.first?.status, .kept)
  }
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 0
  func tick() -> Int64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
