import XCTest
@testable import LinkDigestCore

final class CapturePreferencesTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/private/tmp/linkdigest-capture-prefs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testMissingFileFallsBackToDefault() {
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 20)
  }

  func testSavedLimitIsReadBackAndClamped() throws {
    let store = CapturePreferencesStore(root: root)
    try store.setCommentLimit(60)
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 60)
    try store.setCommentLimit(500)
    XCTAssertEqual(store.commentLimit, 100)
    try store.setCommentLimit(1)
    XCTAssertEqual(store.commentLimit, 10)
  }

  func testCorruptFileFallsBackToDefault() throws {
    let url = root.appendingPathComponent("Library/Application Support/LinkDigest/capture-preferences-v1.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("oops".utf8).write(to: url)
    XCTAssertEqual(CapturePreferencesStore(root: root).commentLimit, 20)
  }

  /// App 写下自动工序，Host 原样读给扩展；未知键和重复被丢掉，顺序固定。
  func testAutoStepsRoundTripInProcessOrder() throws {
    let store = CapturePreferencesStore(root: root)
    XCTAssertNil(store.autoSteps)
    try store.setAutoSteps(["mindMap", "record", "bogus", "record"])
    XCTAssertEqual(CapturePreferencesStore(root: root).autoSteps, ["record", "mindMap"])
    try store.setCommentLimit(40)
    XCTAssertEqual(store.autoSteps, ["record", "mindMap"], "改评论条数不能冲掉自动工序")
    let response = NativeResponse.capturePreferences(version: 1, requestId: "r", commentLimit: 40, autoSteps: store.autoSteps)
    let decoded = try JSONDecoder().decode(NativeResponse.self, from: JSONEncoder().encode(response))
    XCTAssertEqual(decoded, response)
  }

  func testRequestDecodingClaimsOnlyItsOwnKind() throws {
    XCTAssertNil(try CapturePreferencesRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r"}"#.utf8)))
    XCTAssertNil(try CapturePreferencesRequest.decode(Data("not json".utf8)))
    let request = try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":1,"requestId":"r-1"}"#.utf8))
    XCTAssertEqual(request?.requestId, "r-1")
    XCTAssertThrowsError(try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":2,"requestId":"r"}"#.utf8)))
    XCTAssertThrowsError(try CapturePreferencesRequest.decode(Data(#"{"kind":"getCapturePreferences","version":1}"#.utf8)))
  }

  func testResponseRoundTripsAndIsNotADelivery() throws {
    let response = NativeResponse.capturePreferences(version: 1, requestId: "r-1", commentLimit: 30)
    let encoded = try JSONEncoder().encode(response)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "capturePreferences")
    XCTAssertEqual(object["commentLimit"] as? Int, 30)
    XCTAssertEqual(try JSONDecoder().decode(NativeResponse.self, from: encoded), response)
    XCTAssertFalse(response.isSuccessfulBrowserDelivery)
  }

  /// 2026-09-28 按平台条数和自动保存：旧文件照读，新字段可选。
  func testPerPlatformLimitsAndAutoSave() throws {
    let url = root.appendingPathComponent("Library/Application Support/LinkDigest/capture-preferences-v1.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"commentLimit":30}"#.utf8).write(to: url)
    let store = CapturePreferencesStore(root: root)
    XCTAssertEqual(store.commentLimit, 30, "旧版文件只有 commentLimit")
    XCTAssertEqual(store.commentLimitsByPlatform, [:])
    XCTAssertFalse(store.autoSaveComments)

    try store.setCommentLimit(50, forPlatform: "douyin")
    try store.setCommentLimit(0, forPlatform: "reddit")
    try store.setCommentLimit(500, forPlatform: "x")
    try store.setAutoSaveComments(true)
    XCTAssertEqual(store.commentLimit, 30, "改平台不动默认")
    XCTAssertEqual(store.commentLimitsByPlatform, ["douyin": 50, "reddit": 0, "x": 100])
    XCTAssertTrue(store.autoSaveComments)

    try store.setCommentLimit(nil, forPlatform: "douyin")
    XCTAssertEqual(store.commentLimitsByPlatform, ["reddit": 0, "x": 100], "nil = 改回跟随默认")
  }

  /// App「添加链接」顺带存评论的条数，和扩展弹窗「自动保存前 N 条」同一套规则。
  func testAutoSaveCommentLimitFollowsExtensionRule() throws {
    let store = CapturePreferencesStore(root: root)
    let zhihu = URL(string: "https://www.zhihu.com/question/1/answer/2")!
    XCTAssertNil(store.autoSaveCommentLimit(for: zhihu), "没开自动保存：不存")
    try store.setAutoSaveComments(true)
    XCTAssertEqual(store.autoSaveCommentLimit(for: zhihu), 20, "跟随默认条数")
    try store.setCommentLimit(40, forPlatform: "zhihu")
    XCTAssertEqual(store.autoSaveCommentLimit(for: zhihu), 40, "平台单独设的条数优先")
    try store.setCommentLimit(0, forPlatform: "zhihu")
    XCTAssertNil(store.autoSaveCommentLimit(for: zhihu), "平台设成不抓：不存")
    XCTAssertNil(store.autoSaveCommentLimit(for: URL(string: "https://example.com/post")!), "不支持评论的网页：不存")
  }

  func testResponseCarriesPlatformLimitsOnlyWhenSet() throws {
    let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
      NativeResponse.capturePreferences(version: 1, requestId: "r", commentLimit: 20)
    )) as? [String: Any]
    XCTAssertNil(plain?["commentLimits"], "没设就不发，旧扩展看到的和原来一模一样")
    XCTAssertNil(plain?["autoSaveComments"])
    let full = NativeResponse.capturePreferences(version: 1, requestId: "r", commentLimit: 20, commentLimits: ["douyin": 50, "reddit": 0], autoSaveComments: true)
    let encoded = try JSONEncoder().encode(full)
    XCTAssertEqual(try JSONDecoder().decode(NativeResponse.self, from: encoded), full)
  }
}
