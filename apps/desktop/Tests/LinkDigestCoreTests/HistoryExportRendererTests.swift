import Foundation
import XCTest
@testable import LinkDigestCore

final class HistoryExportRendererTests: XCTestCase {
  func testBatchFilenameCollisionUsesCaseInsensitiveNumberingWithinNameLimit() {
    var used: Set<String> = []
    XCTAssertEqual(
      HistoryBatchExporter.uniqueFilename(
        suggestedFilename: "同名标题.md",
        usedLowercasedNames: &used
      ),
      "同名标题.md"
    )
    XCTAssertEqual(
      HistoryBatchExporter.uniqueFilename(
        suggestedFilename: "同名标题.md",
        usedLowercasedNames: &used
      ),
      "同名标题 (2).md"
    )
    XCTAssertEqual(
      HistoryBatchExporter.uniqueFilename(
        suggestedFilename: "同名标题.MD",
        usedLowercasedNames: &used
      ),
      "同名标题 (3).MD"
    )

    let longName = String(repeating: "资料", count: 200) + ".md"
    let first = HistoryBatchExporter.uniqueFilename(
      suggestedFilename: longName,
      usedLowercasedNames: &used
    )
    let second = HistoryBatchExporter.uniqueFilename(
      suggestedFilename: longName,
      usedLowercasedNames: &used
    )
    XCTAssertLessThanOrEqual(second.utf8.count, 255)
    XCTAssertNotEqual(first.lowercased(), second.lowercased())
    XCTAssertTrue(second.hasSuffix(" (2).md"))
  }
  func testMarkdownAndPlainTextGoldenOutput() throws {
    let projection = fixture()

    let markdown = String(decoding: try HistoryExportRenderer.render(projection, as: .markdown).data, as: UTF8.self)
    XCTAssertEqual(markdown, """
    ---
    title: "示例标题"
    source: "https://example.test/article"
    created: "1970-01-01T00:00:01.000Z"
    ---

    # 示例标题

    - 来源：https://example.test/article
    - 标签：—
    - 导出版本：1
    - 创建时间（UTC）：1970-01-01T00:00:01.000Z
    - 最近更新时间（UTC）：1970-01-01T00:00:04.000Z

    ## 最近原文

    - 捕获时间（UTC）：1970-01-01T00:00:02.000Z
    - 来源标签：网页
    - 完整性：complete

    原文

    ## 运行记录

    ### 1. 总结 · 已完成

    - 动作：总结
    - 状态：已完成
    - 时间（UTC）：1970-01-01T00:00:04.000Z
    - 模型：fixture-model
    - Token：输入 12 / 输出 30 / 总计 42
    - 费用：USD 0.000123
    - 结果完整性：完整
    - 结果格式：Markdown

    #### 结果

    总结结果
    """
    + "\n")

    let plainText = String(decoding: try HistoryExportRenderer.render(projection, as: .plainText).data, as: UTF8.self)
    XCTAssertEqual(plainText, """
    标题: 示例标题
    来源: https://example.test/article
    标签: —
    导出版本: 1
    创建时间（UTC）: 1970-01-01T00:00:01.000Z
    最近更新时间（UTC）: 1970-01-01T00:00:04.000Z

    最近原文:
    捕获时间（UTC）: 1970-01-01T00:00:02.000Z
    来源标签: 网页
    完整性: complete
    原文

    运行记录:

    [1] 动作: 总结
    状态: 已完成
    时间（UTC）: 1970-01-01T00:00:04.000Z
    模型: fixture-model
    Token: 输入 12 / 输出 30 / 总计 42
    费用: USD 0.000123
    结果完整性: 完整
    结果格式: Markdown
    结果:
    总结结果
    """
    + "\n")
  }

  func testJSONIsDeterministicAndRoundTripsSafeProjection() throws {
    let projection = fixture()
    let first = try HistoryExportRenderer.render(projection, as: .json).data
    let second = try HistoryExportRenderer.render(projection, as: .json).data
    XCTAssertEqual(first, second)
    let json = String(decoding: first, as: UTF8.self)
    XCTAssertTrue(json.contains("https://example.test/article"))
    XCTAssertTrue(json.contains("\"formatVersion\" : 1"))

    let decoded = try JSONDecoder().decode(HistoryExportProjection.self, from: first)
    XCTAssertEqual(decoded.formatVersion, 1)
    XCTAssertEqual(decoded.task, projection.task)
    XCTAssertEqual(decoded.snapshots, projection.snapshots)
    XCTAssertEqual(decoded.runs, projection.runs)
  }

  func testAllExportFormatsIncludeLocalTags() throws {
    let projection = fixture().withTags(["本地优先", "Swift"])
    let markdown = String(decoding: try HistoryExportRenderer.render(projection, as: .markdown).data, as: UTF8.self)
    let plainText = String(decoding: try HistoryExportRenderer.render(projection, as: .plainText).data, as: UTF8.self)
    let json = try HistoryExportRenderer.render(projection, as: .json).data

    XCTAssertTrue(markdown.contains("- 标签：本地优先, Swift"))
    XCTAssertTrue(plainText.contains("标签: 本地优先, Swift"))
    XCTAssertEqual(try JSONDecoder().decode(HistoryExportProjection.self, from: json).tags.map(\.name), ["本地优先", "Swift"])
  }

  func testRenderedFilesHaveExactFormatExtensions() throws {
    let projection = fixture()

    XCTAssertEqual(try HistoryExportRenderer.render(projection, as: .markdown).suggestedFilename, "示例标题.1.md")
    XCTAssertEqual(try HistoryExportRenderer.render(projection, as: .plainText).suggestedFilename, "示例标题.1.txt")
    XCTAssertEqual(try HistoryExportRenderer.render(projection, as: .json).suggestedFilename, "示例标题.1.json")
  }

  func testUnicodeNULAndEmptyResultsRemainRecognizable() throws {
    let projection = fixture(
      title: "👩🏽‍💻 e\u{301}\0标题",
      body: "原\u{0000}文 👩🏽‍💻 e\u{301}",
      artifactBody: "",
      artifactCompleteness: .partial,
      status: .interrupted
    )
    let markdown = String(decoding: try HistoryExportRenderer.render(projection, as: .markdown).data, as: UTF8.self)
    XCTAssertTrue(markdown.contains("原\u{0000}文 👩🏽‍💻 e\u{301}"))
    XCTAssertTrue(markdown.contains("结果完整性：部分结果"))
    XCTAssertTrue(markdown.contains("（结果为空）"))
    let decoded = try JSONDecoder().decode(
      HistoryExportProjection.self,
      from: HistoryExportRenderer.render(projection, as: .json).data
    )
    XCTAssertEqual(decoded, projection)

    let empty = HistoryExportProjection(task: projection.task, snapshots: [], runs: [])
    let plainText = String(decoding: try HistoryExportRenderer.render(empty, as: .plainText).data, as: UTF8.self)
    XCTAssertTrue(plainText.contains("（没有保存的原文）"))
    XCTAssertTrue(plainText.contains("（没有运行记录）"))
  }

  func testInterruptedRunWithoutArtifactAndPartialArtifactAreClear() throws {
    let value = fixture(artifactBody: "已接收的一部分", artifactCompleteness: .partial, status: .interrupted)
    let markdown = String(decoding: try HistoryExportRenderer.render(value, as: .markdown).data, as: UTF8.self)
    XCTAssertTrue(markdown.contains("总结 · 已中断"))
    XCTAssertTrue(markdown.contains("结果完整性：部分结果"))

    let noArtifact = HistoryExportProjection(task: value.task, snapshots: value.snapshots, runs: [.init(run: value.runs[0].run, artifact: nil)])
    let text = String(decoding: try HistoryExportRenderer.render(noArtifact, as: .plainText).data, as: UTF8.self)
    XCTAssertTrue(text.contains("结果: 无可导出的结果"))
  }

  func testSuggestedFilenameRemovesPathControlLeadingDotsAndBoundsLength() throws {
    let unsafe = "... /private\\folder:\u{0000}报告 " + String(repeating: "长", count: 100)
    let safe = HistoryExportRenderer.safeFilenameComponent(unsafe, maximumUTF8ByteCount: 20)
    XCTAssertFalse(safe.contains("/"))
    XCTAssertFalse(safe.contains("\\"))
    XCTAssertFalse(safe.contains(":"))
    XCTAssertFalse(safe.contains("\u{0000}"))
    XCTAssertFalse(safe.hasPrefix("."))
    XCTAssertLessThanOrEqual(safe.utf8.count, 20)
    XCTAssertEqual(HistoryExportRenderer.safeFilenameComponent(". .hidden"), "hidden")
    XCTAssertEqual(HistoryExportRenderer.safeFilenameComponent(".../\u{0000}"), "LinkDigest 历史")

    let emojiProjection = fixture(title: String(repeating: "😀", count: 72))
    for format in HistoryExportFormat.allCases {
      let suggestedFilename = try HistoryExportRenderer.render(emojiProjection, as: format).suggestedFilename
      let suffix = ".1.\(format.fileExtension)"
      XCTAssertLessThanOrEqual(suggestedFilename.utf8.count, 255)
      XCTAssertTrue(suggestedFilename.hasSuffix(suffix))
      XCTAssertFalse(String(suggestedFilename.dropLast(suffix.count)).hasPrefix("."))
    }

    let oversizedCharacter = "e" + String(repeating: "\u{301}", count: 300)
    let oversizedProjection = fixture(title: oversizedCharacter)
    let fallbackFilename = try HistoryExportRenderer.render(oversizedProjection, as: .json).suggestedFilename
    XCTAssertLessThanOrEqual(fallbackFilename.utf8.count, 255)
    XCTAssertTrue(fallbackFilename.hasSuffix(".1.json"))
    XCTAssertFalse(fallbackFilename.hasPrefix("."))
    XCTAssertTrue(fallbackFilename.hasPrefix("LinkDigest 历史"))
  }

  func testPartialUsageShowsInputOutputAndSafelyDerivedTotal() throws {
    let usage = RunUsageCost(inputTokens: 12, outputTokens: 30)
    let projection = fixture(usageCost: usage)

    let markdown = String(decoding: try HistoryExportRenderer.render(projection, as: .markdown).data, as: UTF8.self)
    let plainText = String(decoding: try HistoryExportRenderer.render(projection, as: .plainText).data, as: UTF8.self)
    XCTAssertTrue(markdown.contains("Token：输入 12 / 输出 30 / 总计 42"))
    XCTAssertTrue(plainText.contains("Token: 输入 12 / 输出 30 / 总计 42"))
  }

  func testDecoderRejectsNonCanonicalUUIDAndInvalidUsageCostAsDataCorrupted() throws {
    let projection = fixture()
    let invalidUUID = try mutatedJSON(projection) { json in
      var task = json["task"] as! [String: Any]
      var id = task["id"] as! [String: Any]
      id["rawValue"] = "not-a-uuid"
      task["id"] = id
      json["task"] = task
    }
    assertDataCorrupted(invalidUUID)

    let negativeUsage = try mutatedJSON(projection) { json in
      var runs = json["runs"] as! [[String: Any]]
      var usage = runs[0]["usageCost"] as! [String: Any]
      usage["inputTokens"] = -1
      runs[0]["usageCost"] = usage
      json["runs"] = runs
    }
    assertDataCorrupted(negativeUsage)

    let unpairedCost = try mutatedJSON(projection) { json in
      var runs = json["runs"] as! [[String: Any]]
      var usage = runs[0]["usageCost"] as! [String: Any]
      usage.removeValue(forKey: "costCurrencyCode")
      runs[0]["usageCost"] = usage
      json["runs"] = runs
    }
    assertDataCorrupted(unpairedCost)
  }

  func testDecoderRejectsCrossObjectIDMismatchesAsDataCorrupted() throws {
    let projection = fixture()
    let outsideTaskID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    let outsideSnapshotID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    let outsideRunID = "11111111-1111-1111-1111-111111111111"

    let snapshotTaskMismatch = try mutatedJSON(projection) { json in
      var snapshots = json["snapshots"] as! [[String: Any]]
      snapshots[0]["taskID"] = ["rawValue": outsideTaskID]
      json["snapshots"] = snapshots
    }
    let runSnapshotMismatch = try mutatedJSON(projection) { json in
      var runs = json["runs"] as! [[String: Any]]
      runs[0]["snapshotID"] = ["rawValue": outsideSnapshotID]
      json["runs"] = runs
    }
    let artifactRunMismatch = try mutatedJSON(projection) { json in
      var runs = json["runs"] as! [[String: Any]]
      var artifact = runs[0]["artifact"] as! [String: Any]
      artifact["runID"] = ["rawValue": outsideRunID]
      runs[0]["artifact"] = artifact
      json["runs"] = runs
    }
    let rerunMismatch = try mutatedJSON(projection) { json in
      var runs = json["runs"] as! [[String: Any]]
      runs[0]["rerunOfRunID"] = ["rawValue": outsideRunID]
      json["runs"] = runs
    }
    for data in [snapshotTaskMismatch, runSnapshotMismatch, artifactRunMismatch, rerunMismatch] {
      assertDataCorrupted(data)
    }
  }

  func testProjectionAndRendererExcludeProviderSecretsPathsAndRawErrors() throws {
    let base = fixture()
    let unsafeRun = HistoryRun(
      id: base.runs[0].run.id,
      taskID: base.task.id,
      snapshotID: base.snapshots[0].id,
      idempotencyKey: "api-key-secret-reference",
      rerunOfRunID: nil,
      kind: .summarize,
      targetLanguage: nil,
      status: .failed,
      providerProfileID: "keychain-secret-reference",
      providerKind: "openai-compatible",
      providerBaseURL: "file:///private/secret-provider-path",
      providerAPIMode: "chat_completions",
      model: "fixture-model",
      createdAtMilliseconds: 3_000,
      startedAtMilliseconds: 3_500,
      finishedAtMilliseconds: 4_000,
      failureCode: "RAW_PROVIDER_ERROR: api-key-secret-reference",
      failureRetryable: true,
      usageCost: .unknown
    )
    let projection = HistoryExportProjection(task: base.task, snapshots: base.snapshots, runs: [.init(run: unsafeRun, artifact: nil)])
    let json = String(decoding: try HistoryExportRenderer.render(projection, as: .json).data, as: UTF8.self)
    let markdown = String(decoding: try HistoryExportRenderer.render(projection, as: .markdown).data, as: UTF8.self)
    for forbidden in ["api-key-secret-reference", "keychain-secret-reference", "/private/secret-provider-path", "RAW_PROVIDER_ERROR", "idempotencyKey", "providerBaseURL", "failureCode", "usedCookie"] {
      XCTAssertFalse(json.contains(forbidden))
      XCTAssertFalse(markdown.contains(forbidden))
    }
    XCTAssertNil(projection.runs[0].run.providerProfileID)
    XCTAssertNil(projection.runs[0].run.failureCode)
    XCTAssertFalse(projection.snapshots[0].usedCookie)
  }

  /// 导出笔记时不该出现 `linkdigest-note:<uuid>`。
  ///
  /// 那是本机的行标识，不是地址。跟着 Markdown 导进 Obsidian 后既打不开也没有
  /// 意义，只是每篇笔记顶上多一行噪音。抓取内容的「来源」照旧保留。
  func testNoteExportOmitsTheInternalIdentifierAndCaptureFields() throws {
    let note = noteFixture()

    let markdown = String(decoding: try HistoryExportRenderer.render(note, as: .markdown).data, as: UTF8.self)
    XCTAssertFalse(markdown.contains("linkdigest-note:"), "内部标识不该出现在导出里")
    XCTAssertFalse(markdown.contains("source:"))
    XCTAssertFalse(markdown.contains("- 来源："))
    // 笔记没有被捕获过，这些字段对它都不成立。
    XCTAssertFalse(markdown.contains("捕获时间"))
    XCTAssertFalse(markdown.contains("完整性"))
    XCTAssertTrue(markdown.contains("## 正文"), "笔记的正文不是「原文」")
    XCTAssertTrue(markdown.contains("我写的想法"))
    // 标题、标签、时间这些仍然要在。
    XCTAssertTrue(markdown.contains("title: \"我的笔记标题\""))

    let plain = String(decoding: try HistoryExportRenderer.render(note, as: .plainText).data, as: UTF8.self)
    XCTAssertFalse(plain.contains("linkdigest-note:"))
    XCTAssertTrue(plain.contains("正文:"))
    XCTAssertTrue(plain.contains("我写的想法"))
  }

  /// 抓取内容的来源必须照旧导出——上面那条不能顺手把它也删了。
  func testCapturedExportStillCarriesItsSource() throws {
    let markdown = String(decoding: try HistoryExportRenderer.render(fixture(), as: .markdown).data, as: UTF8.self)
    XCTAssertTrue(markdown.contains("source: \"https://example.test/article\""))
    XCTAssertTrue(markdown.contains("- 来源：https://example.test/article"))
    XCTAssertTrue(markdown.contains("## 最近原文"))
  }

  private func noteFixture() -> HistoryExportProjection {
    let taskID = TaskID(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!)
    let snapshotID = ContentSnapshotID(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
    let url = "linkdigest-note:eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    let body = "我写的想法"
    let task = HistoryTask(
      id: taskID, canonicalURL: url, canonicalizationVersion: 1,
      createdAtMilliseconds: 1_000, updatedAtMilliseconds: 4_000
    )
    let snapshot = ContentSnapshot(
      id: snapshotID, taskID: taskID, sequence: 1, envelopeCreatedAtMilliseconds: 1_500,
      capturedAtMilliseconds: 2_000, sourceKind: "user_note", sourceURL: url,
      title: "我的笔记标题", platform: "note", captureMethod: "user_note",
      completeness: "complete", bodyText: body, characterCount: body.unicodeScalars.count,
      bodySHA256: String(repeating: "b", count: 64), sourceLabel: "我的笔记", usedCookie: false
    )
    return .init(task: task, snapshots: [snapshot], runs: [])
  }

  private func fixture(
    title: String = "示例标题",
    body: String = "原文",
    artifactBody: String = "总结结果",
    artifactCompleteness: ArtifactCompleteness = .complete,
    status: RunStatus = .completed,
    usageCost: RunUsageCost? = nil
  ) -> HistoryExportProjection {
    let taskID = TaskID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
    let snapshotID = ContentSnapshotID(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
    let runID = RunID(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!)
    let artifactID = ArtifactID(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)
    let task = HistoryTask(id: taskID, canonicalURL: "https://example.test/article", canonicalizationVersion: 1, createdAtMilliseconds: 1_000, updatedAtMilliseconds: 4_000)
    let snapshot = ContentSnapshot(id: snapshotID, taskID: taskID, sequence: 1, envelopeCreatedAtMilliseconds: 1_500, capturedAtMilliseconds: 2_000, sourceKind: "web", sourceURL: task.canonicalURL, title: title, platform: "fixture", captureMethod: "page", completeness: "complete", bodyText: body, characterCount: body.unicodeScalars.count, bodySHA256: String(repeating: "a", count: 64), sourceLabel: "网页", usedCookie: true)
    let usage = usageCost ?? RunUsageCost(inputTokens: 12, outputTokens: 30, totalTokens: 42, costAmountMicros: 123, costCurrencyCode: "USD")
    let run = HistoryRun(id: runID, taskID: taskID, snapshotID: snapshotID, idempotencyKey: "internal-key", rerunOfRunID: nil, kind: .summarize, targetLanguage: nil, status: status, providerProfileID: "internal-profile", providerKind: "openai-compatible", providerBaseURL: "https://provider.invalid/v1", providerAPIMode: "chat_completions", model: "fixture-model", createdAtMilliseconds: 3_000, startedAtMilliseconds: 3_500, finishedAtMilliseconds: 4_000, failureCode: "INTERNAL", failureRetryable: false, usageCost: usage)
    let artifact = HistoryArtifact(id: artifactID, runID: runID, contentFormat: .markdown, completeness: artifactCompleteness, bodyText: artifactBody, createdAtMilliseconds: 4_000, updatedAtMilliseconds: 4_000)
    return .init(task: task, snapshots: [snapshot], runs: [.init(run: run, artifact: artifact)])
  }

  private func mutatedJSON(
    _ projection: HistoryExportProjection,
    mutate: (inout [String: Any]) -> Void
  ) throws -> Data {
    let data = try HistoryExportRenderer.render(projection, as: .json).data
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    mutate(&json)
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  }

  private func assertDataCorrupted(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try JSONDecoder().decode(HistoryExportProjection.self, from: data), file: file, line: line) { error in
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("Expected dataCorrupted, got \(error)", file: file, line: line)
      }
    }
  }
}

private extension HistoryExportProjection {
  func withTags(_ names: [String]) -> HistoryExportProjection {
    .init(task: task, snapshots: snapshots, runs: runs, tags: names.compactMap(HistoryTag.init(rawValue:)))
  }
}
