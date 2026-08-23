import Foundation
import XCTest
@testable import LinkDigestCore

/// 时区固定，否则文件名里的日期会随运行机器漂。
private let fixtureTimeZone = TimeZone(secondsFromGMT: 8 * 3_600)!

final class KnowledgeVaultRendererTests: XCTestCase {
  func testFrontmatterCarriesTheFieldsDownstreamSearchNeeds() {
    let document = KnowledgeVaultRenderer.render(fixture(), timeZone: fixtureTimeZone)

    XCTAssertTrue(document.text.hasPrefix("---\ntype: digest\n"))
    XCTAssertTrue(document.text.contains("digest_id: \"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\""))
    XCTAssertTrue(document.text.contains("title: \"示例标题\""))
    XCTAssertTrue(document.text.contains("url: \"https://example.test/article\""))
    XCTAssertTrue(document.text.contains("platform: \"网页\""))
    XCTAssertTrue(document.text.contains("captured: \"1970-01-01T00:00:02Z\""))
    XCTAssertTrue(document.text.contains("has_transcript: false"))
    XCTAssertTrue(document.text.contains("has_summary: true"))
    XCTAssertTrue(document.text.contains("tags: []"))
    // 回链是这份导出的意义所在，没有它检索命中了也回不去。
    XCTAssertTrue(
      document.text.contains("> 回链：linkdigest://digest/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    )
    XCTAssertTrue(document.text.contains("## 摘要\n\n总结结果"))
    XCTAssertTrue(document.text.contains("## 原文\n\n原文"))
  }

  /// 导出的原文必须带上所有层，元数据必须取自抓取来源层。
  ///
  /// 原来两者都读 `snapshots.last`。那是最新追加的**派生层**——听写稿或画面
  /// 字幕：正文只剩最后那一层（配文和另一层全丢），而 platform 会被写成
  /// 派生层的 sourceLabel（「画面字幕」这种动作名）。派生层每多一种，
  /// 丢失的内容就多一层，且全程不报错。
  func testExportKeepsEveryLayerAndTakesMetadataFromTheCapturedSource() {
    let text = KnowledgeVaultRenderer.render(
      fixture(includeTranscript: true, includeSubtitles: true),
      timeZone: fixtureTimeZone
    ).text

    // 三层都要在，一层都不能少。
    XCTAssertTrue(text.contains("原文"), "配文层丢失")
    XCTAssertTrue(text.contains("听写正文"), "听写层丢失")
    XCTAssertTrue(text.contains("字幕正文"), "画面字幕层丢失")

    // 元数据取自配文层：platform 不能被派生层的 sourceLabel 顶掉。
    XCTAssertTrue(text.contains("platform: \"网页\""), "platform 被派生层污染")
    XCTAssertFalse(text.contains("platform: \"画面字幕\""))
    XCTAssertFalse(text.contains("platform: \"本机转写\""))
  }

  /// 运行记录必须**不在**导出里：下游按「命中次数 / 正文长度」排序，
  /// 模型名、token、费用只会稀释密度，把真正相关的条目压下去。
  func testRunLogIsExcludedSoSearchDensityIsNotDiluted() {
    let text = KnowledgeVaultRenderer.render(fixture(), timeZone: fixtureTimeZone).text

    XCTAssertFalse(text.contains("运行记录"))
    XCTAssertFalse(text.contains("fixture-model"))
    XCTAssertFalse(text.contains("Token"))
    XCTAssertFalse(text.contains("费用"))
    XCTAssertFalse(text.contains("USD"))
  }

  func testTagsAndTranscriptFlagAreReported() {
    let projection = fixture(tags: ["招聘", "FDE"], includeTranscript: true)
    let text = KnowledgeVaultRenderer.render(projection, timeZone: fixtureTimeZone).text

    XCTAssertTrue(text.contains("tags: [\"招聘\", \"FDE\"]"))
    XCTAssertTrue(text.contains("has_transcript: true"))
  }

  func testSummaryAbsentWhenNoCompletedSummarizeRun() {
    let text = KnowledgeVaultRenderer.render(fixture(status: .failed), timeZone: fixtureTimeZone).text

    XCTAssertTrue(text.contains("has_summary: false"))
    XCTAssertFalse(text.contains("## 摘要"))
    XCTAssertTrue(text.contains("## 原文"))
  }

  // MARK: - YAML 转义

  func testYAMLScalarsQuoteValuesThatWouldOtherwiseChangeMeaning() {
    // 这些值裸写进 YAML 会被读成别的东西：冒号加空格变成嵌套键值，
    // 开头的 `-` 变成列表项，纯数字变成数字，yes/null 变成布尔和空值。
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("键: 值"), "\"键: 值\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("- 开头"), "\"- 开头\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("2026"), "\"2026\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("yes"), "\"yes\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("null"), "\"null\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("引号\"在中间"), "\"引号\\\"在中间\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("反斜杠\\"), "\"反斜杠\\\\\"")
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("换\n行"), "\"换\\n行\"")
    // 控制字符不转义会让整份 frontmatter 解析失败。
    XCTAssertEqual(KnowledgeVaultRenderer.yamlScalar("空\u{0000}字符"), "\"空\\x00字符\"")
  }

  func testFrontmatterRoundTripsThroughTheDigestIDReader() {
    // 标题里带冒号和引号——最容易把 frontmatter 写坏的那一类值。
    let projection = fixture(title: "标题: 带\"引号\"和 - 破折号")
    let document = KnowledgeVaultRenderer.render(projection, timeZone: fixtureTimeZone)

    XCTAssertEqual(
      KnowledgeVaultSync.digestID(inMarkdown: document.text),
      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )
  }

  func testDigestIDReaderRejectsFilesItDoesNotUnderstand() {
    XCTAssertNil(KnowledgeVaultSync.digestID(inMarkdown: "没有 frontmatter 的普通笔记"))
    XCTAssertNil(KnowledgeVaultSync.digestID(inMarkdown: "---\ntitle: 别人的文件\n---\n正文"))
    // 未闭合的 frontmatter 不能猜，猜错就会覆盖用户的文件。
    XCTAssertNil(KnowledgeVaultSync.digestID(inMarkdown: "---\ndigest_id: \"x\"\n没有结束标记"))
  }

  // MARK: - 文件名

  func testFilenameUsesDateAndTitleWithoutTheExportFormatVersion() {
    let name = KnowledgeVaultRenderer.filename(fixture(), timeZone: fixtureTimeZone)

    XCTAssertEqual(name, "1970-01-01_示例标题.md")
    // 格式版本进 frontmatter，不进文件名：版本一升就会多出一个 basename，
    // 下游按 basename 去重，两个名字会各占一个结果位。
    XCTAssertFalse(name.contains(".1."))
  }

  func testFilenameDateFollowsLocalTimeZoneNotUTC() {
    // UTC 20:00 在东八区已经是第二天。文件名日期是给人看的「哪天存的」。
    let projection = fixture(capturedAtMilliseconds: 72_000_000)

    XCTAssertEqual(
      KnowledgeVaultRenderer.filename(projection, timeZone: fixtureTimeZone),
      "1970-01-02_示例标题.md"
    )
    XCTAssertEqual(
      KnowledgeVaultRenderer.filename(projection, timeZone: TimeZone(secondsFromGMT: 0)!),
      "1970-01-01_示例标题.md"
    )
  }

  func testFilenameStripsPathSeparatorsAndStaysWithinTheByteBudget() {
    let hostile = fixture(title: "../../etc/passwd:\u{0000} 报告")
    let name = KnowledgeVaultRenderer.filename(hostile, timeZone: fixtureTimeZone)

    XCTAssertFalse(name.contains("/"))
    XCTAssertFalse(name.contains("\\"))
    XCTAssertFalse(name.contains(":"))
    XCTAssertFalse(name.contains("\u{0000}"))
    XCTAssertTrue(name.hasSuffix(".md"))

    for title in [String(repeating: "长", count: 400), String(repeating: "😀", count: 200)] {
      let bounded = KnowledgeVaultRenderer.filename(fixture(title: title), timeZone: fixtureTimeZone)
      XCTAssertLessThanOrEqual(bounded.utf8.count, 255)
      XCTAssertTrue(bounded.hasSuffix(".md"))
      XCTAssertTrue(bounded.hasPrefix("1970-01-01_"))
    }

    // emoji 不能被从中间劈开——截断按 Character 走，不按字节走。
    let emoji = KnowledgeVaultRenderer.filename(
      fixture(title: String(repeating: "👩🏽‍💻", count: 40)),
      timeZone: fixtureTimeZone
    )
    XCTAssertLessThanOrEqual(emoji.utf8.count, 255)
    XCTAssertNotNil(String(data: Data(emoji.utf8), encoding: .utf8))
  }

  // MARK: - 截断

  func testOversizedBodyIsTruncatedWithANoticeAndFileStaysUnderTheSearchLimit() {
    let huge = String(repeating: "长", count: 400_000)  // ~1.2MB UTF-8
    let document = KnowledgeVaultRenderer.render(fixture(body: huge), timeZone: fixtureTimeZone)

    XCTAssertTrue(document.text.contains(KnowledgeVaultRenderer.truncationNotice))
    // 硬指标：超过这个尺寸下游会整个跳过这份文件，等于这条内容彻底搜不到。
    XCTAssertLessThanOrEqual(
      document.text.utf8.count,
      KnowledgeVaultRenderer.maximumFileUTF8ByteCount
    )
  }

  func testBodyExactlyAtTheBudgetIsNotTruncated() {
    let body = String(repeating: "a", count: 1_000)
    let document = KnowledgeVaultRenderer.render(fixture(body: body), timeZone: fixtureTimeZone)

    XCTAssertFalse(document.text.contains(KnowledgeVaultRenderer.truncationNotice))
    XCTAssertTrue(document.text.contains(body))
  }

  func testTruncationKeepsGraphemeClustersWhole() {
    let value = String(repeating: "👩🏽‍💻", count: 10)
    let result = KnowledgeVaultRenderer.truncated(value, withinUTF8ByteCount: 30)

    XCTAssertTrue(result.didTruncate)
    XCTAssertLessThanOrEqual(result.text.utf8.count, 30)
    // 劈开 grapheme cluster 会产生无法解码的字节序列。
    XCTAssertEqual(String(decoding: Data(result.text.utf8), as: UTF8.self), result.text)

    XCTAssertEqual(
      KnowledgeVaultRenderer.truncated("短", withinUTF8ByteCount: 100),
      .init(text: "短", didTruncate: false)
    )
    XCTAssertEqual(
      KnowledgeVaultRenderer.truncated("短", withinUTF8ByteCount: 0),
      .init(text: "", didTruncate: true)
    )
  }

  // MARK: - 范围

  func testOnlyCapturedContentIsSyncable() {
    XCTAssertTrue(KnowledgeVaultRenderer.isSyncable(fixture()))
    // 笔记、稿件、成品是用户自己写的东西，不是采集来的素材。把稿件同步进
    // 知识库，下次找材料会搜到自己的上一稿。
    for prefix in ["linkdigest-note:", "linkdigest-draft:", "linkdigest-work:"] {
      XCTAssertFalse(
        KnowledgeVaultRenderer.isSyncable(fixture(canonicalURL: prefix + UUID().uuidString)),
        "\(prefix) 不该进知识库"
      )
    }
  }

  /// 把一份「最难解析」的渲染结果写出来，交给外部真正的 YAML 解析器验。
  ///
  /// 自己写的 frontmatter 读取器只认 `digest_id` 一个键，用它验自己等于没验；
  /// 这份文件要能被标准解析器整份读下来才算数。默认不产生任何副作用，
  /// 只有显式给了输出路径才写。
  func testHostileValuesRenderIntoAFileForExternalYAMLValidation() throws {
    guard let out = ProcessInfo.processInfo.environment["LINKDIGEST_VAULT_SAMPLE_OUT"] else {
      throw XCTSkip("未指定 LINKDIGEST_VAULT_SAMPLE_OUT，跳过样本导出")
    }
    let projection = fixture(
      title: "标题: 带\"引号\" 和 - 破折号 #井号 😀",
      body: "正文里也有 --- 和 ```，还有 tab\t和换行\n第二行",
      tags: ["yes", "2026", "带: 冒号的标签"]
    )
    let document = KnowledgeVaultRenderer.render(projection, timeZone: fixtureTimeZone)
    try Data(document.text.utf8).write(to: URL(fileURLWithPath: out))

    XCTAssertLessThanOrEqual(
      document.text.utf8.count,
      KnowledgeVaultRenderer.maximumFileUTF8ByteCount
    )
  }

  // MARK: - URL scheme

  func testDigestLinkParsesOnlyCanonicalUUIDs() {
    let id = KnowledgeVaultLink.digestID(
      from: URL(string: "linkdigest://digest/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    )
    XCTAssertEqual(id?.rawValue, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

    // scheme 注册之后任何网页都能扔一个这样的链接过来，所以形状不对一律拒绝。
    for hostile in [
      "linkdigest://digest/../../etc/passwd",
      "linkdigest://digest/not-a-uuid",
      "linkdigest://digest/",
      "linkdigest://digest/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/extra",
      "linkdigest://other/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "https://digest/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    ] {
      XCTAssertNil(
        URL(string: hostile).flatMap(KnowledgeVaultLink.digestID(from:)),
        "\(hostile) 不该被接受"
      )
    }
  }
}

final class KnowledgeVaultSyncTests: XCTestCase {
  func testNewEntryIsCreated() {
    let document = document(id: idA, filename: "2026-08-05_甲.md", text: "内容甲")
    let plan = KnowledgeVaultSync.plan(documents: [document], existing: [])

    XCTAssertEqual(plan.actions, [.create(filename: "2026-08-05_甲.md", text: "内容甲")])
    XCTAssertEqual(plan.creates, 1)
  }

  func testChangedEntryIsUpdated() {
    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_甲.md", text: "新内容")],
      existing: [existing(filename: "2026-08-05_甲.md", digestID: idA, text: "旧内容")]
    )

    XCTAssertEqual(plan.actions, [.update(filename: "2026-08-05_甲.md", text: "新内容")])
  }

  /// 这条是硬要求：目录旁边有上千个既有文件，重写未变更的文件会污染 mtime、
  /// 触发 Obsidian 全量重建索引，并在用户的 Git 仓库里制造巨量噪音。
  func testUnchangedEntryIsSkippedSoMtimeIsPreserved() {
    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_甲.md", text: "一样的内容")],
      existing: [existing(filename: "2026-08-05_甲.md", digestID: idA, text: "一样的内容")]
    )

    XCTAssertEqual(plan.actions, [.skipUnchanged(filename: "2026-08-05_甲.md")])
    XCTAssertEqual(plan.skips, 1)
  }

  func testFilenameOwnedByAnotherDigestIsReportedAndNeverOverwritten() {
    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_撞名.md", text: "我的内容")],
      existing: [existing(filename: "2026-08-05_撞名.md", digestID: idB, text: "别人的内容")]
    )

    XCTAssertEqual(
      plan.actions,
      [.conflict(filename: "2026-08-05_撞名.md", digestID: idA, reason: .otherDigest(idB))]
    )
    XCTAssertEqual(plan.conflicts.count, 1)
    // 冲突不产生任何写入动作。
    XCTAssertEqual(plan.creates + plan.updates + plan.renames, 0)
  }

  func testForeignFileIsNeverOverwritten() {
    // 用户自己的笔记，没有 digest_id。
    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_撞名.md", text: "我的内容")],
      existing: [existing(filename: "2026-08-05_撞名.md", digestID: nil, text: "用户手写的笔记")]
    )

    XCTAssertEqual(
      plan.actions,
      [.conflict(filename: "2026-08-05_撞名.md", digestID: idA, reason: .foreignFile)]
    )
  }

  /// 标题改了要重命名，不能新建——否则同一条内容在目录里留下两份，
  /// 半年后全是名字相近的重复文件。
  func testRetitledEntryIsRenamedRatherThanDuplicated() {
    let plan = KnowledgeVaultSync.plan(
      documents: [document(id: idA, filename: "2026-08-05_新标题.md", text: "内容")],
      existing: [existing(filename: "2026-08-05_旧标题.md", digestID: idA, text: "内容")]
    )

    XCTAssertEqual(
      plan.actions,
      [.rename(from: "2026-08-05_旧标题.md", to: "2026-08-05_新标题.md", text: "内容")]
    )
  }

  func testSameDaySameTitleEntriesGetDistinctFilenames() {
    // 两条不同的历史完全可能同一天有同样的标题。不去重的话第二条会被误判成
    // 冲突，或者两条来回覆盖同一个文件。
    let plan = KnowledgeVaultSync.plan(
      documents: [
        document(id: idA, filename: "2026-08-05_同名.md", text: "甲"),
        document(id: idB, filename: "2026-08-05_同名.md", text: "乙"),
      ],
      existing: []
    )

    guard plan.actions.count == 2,
          case let .create(first, _) = plan.actions[0],
          case let .create(second, _) = plan.actions[1]
    else { return XCTFail("期望两个 create，得到 \(plan.actions)") }
    XCTAssertEqual(first, "2026-08-05_同名.md")
    XCTAssertNotEqual(second, first)
    XCTAssertTrue(second.hasSuffix(".md"))
  }

  func testRepeatedSyncOfTheSameEntryStaysStable() {
    // 第二次同步不该因为上次加过后缀就再改一次名。
    let documents = [
      document(id: idA, filename: "2026-08-05_同名.md", text: "甲"),
      document(id: idB, filename: "2026-08-05_同名.md", text: "乙"),
    ]
    let first = KnowledgeVaultSync.plan(documents: documents, existing: [])
    var onDisk: [KnowledgeVaultExistingFile] = []
    for action in first.actions {
      if case let .create(filename, text) = action {
        onDisk.append(existing(filename: filename, digestID: filename.contains("甲") || text == "甲" ? idA : idB, text: text))
      }
    }
    let second = KnowledgeVaultSync.plan(documents: documents, existing: onDisk)

    XCTAssertEqual(second.skips, 2, "第二次同步应当全部跳过，实际：\(second.actions)")
  }

  func testEntriesRemovedFromHistoryLeaveTheirFilesAlone() {
    // 汲作里删掉一条，不代表要删用户知识库里的文件。只加不删。
    let plan = KnowledgeVaultSync.plan(
      documents: [],
      existing: [existing(filename: "2026-08-05_旧的.md", digestID: idA, text: "内容")]
    )

    XCTAssertTrue(plan.actions.isEmpty)
  }

  // MARK: - 夹具

  private let idA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  private let idB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  private func document(id: String, filename: String, text: String) -> KnowledgeVaultDocument {
    .init(digestID: TaskID(id)!, filename: filename, text: text)
  }

  private func existing(filename: String, digestID: String?, text: String) -> KnowledgeVaultExistingFile {
    .init(filename: filename, digestID: digestID, text: text)
  }
}

// MARK: - 共享夹具

private func fixture(
  title: String = "示例标题",
  body: String = "原文",
  canonicalURL: String = "https://example.test/article",
  capturedAtMilliseconds: Int64 = 2_000,
  status: RunStatus = .completed,
  tags: [String] = [],
  includeTranscript: Bool = false,
  includeSubtitles: Bool = false
) -> HistoryExportProjection {
  let taskID = TaskID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
  let snapshotID = ContentSnapshotID(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
  let transcriptID = ContentSnapshotID(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!)
  let runID = RunID(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!)
  let artifactID = ArtifactID(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!)

  let task = HistoryTask(
    id: taskID,
    canonicalURL: canonicalURL,
    canonicalizationVersion: 1,
    createdAtMilliseconds: 1_000,
    updatedAtMilliseconds: 4_000
  )
  func snapshot(
    id: ContentSnapshotID,
    sequence: Int,
    sourceKind: String,
    text: String,
    label: String = "网页"
  ) -> ContentSnapshot {
    .init(
      id: id, taskID: taskID, sequence: sequence,
      envelopeCreatedAtMilliseconds: 1_500,
      capturedAtMilliseconds: capturedAtMilliseconds,
      sourceKind: sourceKind, sourceURL: canonicalURL, title: title,
      platform: "fixture", captureMethod: "page", completeness: "complete",
      bodyText: text, characterCount: text.unicodeScalars.count,
      bodySHA256: String(repeating: "a", count: 64), sourceLabel: label, usedCookie: true
    )
  }
  var snapshots = [snapshot(id: snapshotID, sequence: 1, sourceKind: "web", text: body)]
  if includeTranscript {
    snapshots.append(
      snapshot(id: transcriptID, sequence: 2, sourceKind: "local_transcription", text: "听写正文", label: "本机转写")
    )
  }
  if includeSubtitles {
    let subtitleID = ContentSnapshotID(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
    snapshots.append(
      snapshot(id: subtitleID, sequence: 3, sourceKind: "burned_in_subtitles", text: "字幕正文", label: "画面字幕")
    )
  }

  let run = HistoryRun(
    id: runID, taskID: taskID, snapshotID: snapshotID, idempotencyKey: "internal-key",
    rerunOfRunID: nil, kind: .summarize, targetLanguage: nil, status: status,
    providerProfileID: "internal-profile", providerKind: "openai-compatible",
    providerBaseURL: "https://provider.invalid/v1", providerAPIMode: "chat_completions",
    model: "fixture-model", createdAtMilliseconds: 3_000, startedAtMilliseconds: 3_500,
    finishedAtMilliseconds: 4_000, failureCode: nil, failureRetryable: nil,
    usageCost: RunUsageCost(inputTokens: 12, outputTokens: 30, totalTokens: 42, costAmountMicros: 123, costCurrencyCode: "USD")
  )
  let artifact = HistoryArtifact(
    id: artifactID, runID: runID, contentFormat: .markdown, completeness: .complete,
    bodyText: "总结结果", createdAtMilliseconds: 4_000, updatedAtMilliseconds: 4_000
  )
  return .init(
    task: task,
    snapshots: snapshots,
    runs: [.init(run: run, artifact: artifact)],
    tags: tags.compactMap(HistoryTag.init(rawValue:))
  )
}
