import XCTest
@testable import LinkDigestCore

final class HistoryDomainTests: XCTestCase {
  func testPlatformSynonymNormalizedNamesCoverLegacyAutomaticTags() {
    let names = HistoryTagNormalizer.platformSynonymNormalizedNames
    for legacy in ["公众号", "X", "GitHub", "抖音"] {
      let normalized = HistoryTagNormalizer.normalized(legacy)?.normalizedName
      XCTAssertNotNil(normalized)
      XCTAssertTrue(names.contains(normalized ?? ""))
    }
    XCTAssertFalse(names.contains("swift"))
  }

  func testTagNormalizationAndAutomaticFirstLineLimit() {
    XCTAssertNil(HistoryTag(rawValue: "   "))
    XCTAssertNil(HistoryTag(rawValue: String(repeating: "长", count: 21)))
    XCTAssertEqual(HistoryTag(rawValue: "  Swift ")?.normalizedName, "swift")
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "甲, 乙, 甲, 丙, 丁, 戊\n第 2 行不解析").map(\.name),
      ["甲", "乙", "丙", "丁", "戊"]
    )
    // Chinese comma / bullet formats that models often emit.
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "微信，验证，本地").map(\.name),
      ["微信", "验证", "本地"]
    )
    XCTAssertEqual(
      HistoryTagNormalizer.automaticTags(from: "- 产品\n- 设计\n- 工程").map(\.name),
      ["产品", "设计", "工程"]
    )
    XCTAssertEqual(
      HistoryTagNormalizer.fallbackTags(from: "该页面是微信公众平台的验证页面，提示环境异常。").map(\.name),
      ["微信", "需验证"]
    )
  }

  func testSummaryTagTrailerSplitsLastLineAndHidesInProgressMarker() {
    let split = SummaryTagTrailer.split("结论是本地优先。\nTAGS: 本地, 隐私")
    XCTAssertEqual(split.body, "结论是本地优先。")
    XCTAssertEqual(split.tags.map(\.name), ["本地", "隐私"])
    XCTAssertEqual(SummaryTagTrailer.visibleBody("结论是本地优先。\nTA"), "结论是本地优先。")
    XCTAssertEqual(SummaryTagTrailer.visibleBody("结论是本地优先。"), "结论是本地优先。")
    XCTAssertEqual(SummaryTagTrailer.split("没有尾标").body, "没有尾标")
    XCTAssertTrue(SummaryTagTrailer.split("没有尾标").tags.isEmpty)
  }

  func testBrowserWireV1FingerprintGoldenHashAndManualNamespaceStaySeparate() {
    let envelope = fixture(requestID: "golden", idempotencyKey: "delivery-golden")
    let fingerprinter = SHA256CaptureFingerprinter()
    XCTAssertEqual(
      fingerprinter.semanticPayloadSHA256(envelope),
      "21cdaa40987a1f9cce2b26136a84ddd9583b29d15fd11f6f2ae16a9e497144c0"
    )
    let manual = CapturedDocument(
      requestID: envelope.requestId, createdAt: envelope.createdAt,
      idempotencyKey: envelope.idempotencyKey, origin: .manualLink,
      url: envelope.source.url, title: envelope.source.title, platform: "manual",
      method: "public_html", text: envelope.capture.text,
      completeness: "best_effort", capturedAt: envelope.capture.capturedAt,
      sourceLabel: "manual fixture"
    )
    XCTAssertTrue(CaptureDeliveryIdentity.key(for: envelope).hasPrefix("capture:v1:"))
    XCTAssertTrue(CaptureDeliveryIdentity.key(for: manual).hasPrefix("manual:v1:"))
    XCTAssertNotEqual(fingerprinter.semanticPayloadSHA256(envelope), fingerprinter.semanticPayloadSHA256(manual))
  }
  func testCanonicalURLV1IsConservativeAndDeterministic() throws {
    XCTAssertEqual(try CanonicalURL("HTTPS://Example.COM:443").value, "https://example.com/")
    XCTAssertEqual(try CanonicalURL("http://EXAMPLE.com:80/path?q=2&q=1#fragment").value, "http://example.com/path?q=2&q=1")
    XCTAssertEqual(try CanonicalURL("https://example.com/a?utm_source=x&b=2").value, "https://example.com/a?utm_source=x&b=2")
    XCTAssertNotEqual(try CanonicalURL("https://example.com/a?b=2&a=1").value, try CanonicalURL("https://example.com/a?a=1&b=2").value)
    XCTAssertEqual(try CanonicalURL("https://example.com:444/path").value, "https://example.com:444/path")
    XCTAssertThrowsError(try CanonicalURL("file:///tmp/private"))
  }

  func testCaptureFingerprintsIncludeNULAndExcludeTransportIdentity() {
    let fingerprinter = SHA256CaptureFingerprinter()
    XCTAssertEqual(fingerprinter.bodySHA256("a\0b"), "59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138")
    let first = fixture(requestID: "request-one", idempotencyKey: "delivery-one")
    let retry = fixture(requestID: "request-two", idempotencyKey: "delivery-two")
    XCTAssertEqual(fingerprinter.semanticPayloadSHA256(first), fingerprinter.semanticPayloadSHA256(retry))
    let changed = CaptureEnvelopeV1(version: 1, requestId: "request-two", createdAt: first.createdAt, idempotencyKey: "delivery-two", source: first.source, capture: .init(method: first.capture.method, text: "a\0c", characterCount: 3, completeness: first.capture.completeness, capturedAt: first.capture.capturedAt), evidence: first.evidence)
    let titleChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: .init(kind: first.source.kind, url: first.source.url, title: "Changed title", platform: first.source.platform), capture: first.capture, evidence: first.evidence)
    let sourceChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: .init(kind: first.source.kind, url: "https://example.test/other", title: first.source.title, platform: first.source.platform), capture: first.capture, evidence: first.evidence)
    let capturedAtChanged = CaptureEnvelopeV1(version: 1, requestId: first.requestId, createdAt: first.createdAt, idempotencyKey: first.idempotencyKey, source: first.source, capture: .init(method: first.capture.method, text: first.capture.text, characterCount: first.capture.characterCount, completeness: first.capture.completeness, capturedAt: "2026-07-15T04:00:01Z"), evidence: first.evidence)
    for semanticChange in [changed, titleChanged, sourceChanged, capturedAtChanged] {
      XCTAssertNotEqual(fingerprinter.semanticPayloadSHA256(first), fingerprinter.semanticPayloadSHA256(semanticChange))
    }
  }

  func testRunStateMachineAndUsageCostExactness() throws {
    XCTAssertTrue(RunStatus.queued.canTransition(to: .running))
    XCTAssertTrue(RunStatus.queued.canTransition(to: .stopped))
    XCTAssertTrue(RunStatus.running.canTransition(to: .completed))
    XCTAssertFalse(RunStatus.completed.canTransition(to: .running))
    XCTAssertEqual(RunUsageCost(inputTokens: nil, outputTokens: 2, totalTokens: nil, costAmountMicros: 1234, costCurrencyCode: "USD").costAmountMicros, 1234)
    XCTAssertEqual(RunUsageCost(costAmountMicros: 1, costCurrencyCode: nil), .unknown)
    XCTAssertEqual(RunUsageCost(costAmountMicros: 1, costCurrencyCode: "usd"), .unknown)
    XCTAssertThrowsError(try RunUsageCost.validated(inputTokens: nil, outputTokens: 2, totalTokens: nil, costAmountMicros: 1, costCurrencyCode: nil))
  }

  func testTypedIDsRequireLowercaseCanonicalUUID() {
    let id = TaskID()
    XCTAssertEqual(TaskID(id.rawValue), id)
    XCTAssertNil(TaskID(id.rawValue.uppercased()))
    XCTAssertNil(TaskID("not-a-uuid"))
  }

  private func fixture(requestID: String, idempotencyKey: String?) -> CaptureEnvelopeV1 {
    CaptureEnvelopeV1(version: 1, requestId: requestID, createdAt: "2026-07-15T04:00:00Z", idempotencyKey: idempotencyKey, source: .init(kind: "browser_capture", url: "https://example.test/path?b=2&a=1", title: "Fixture", platform: "generic"), capture: .init(method: "rendered_dom", text: "a\0b", characterCount: 3, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"), evidence: .init(sourceLabel: "Fixture DOM", usedCookie: false))
  }
}

/// 用户自建笔记的 canonical URL。
///
/// 笔记没有来源链接，但 `tasks.canonical_url` 是 NOT NULL 且唯一。给它编假的 https
/// 地址会出事：favicon 抓取会拿域名去发真实网络请求，导出和来源显示也会把假地址
/// 当真链接展示。所以用独立 scheme。
final class CanonicalURLNoteTests: XCTestCase {
  func testNoteURLIsStableAndIdentifiable() throws {
    let id = UUID()
    let note = try CanonicalURL.note(id: id)
    XCTAssertTrue(note.isNote)
    XCTAssertEqual(note.value, "linkdigest-note:\(id.uuidString.lowercased())")
    // 同一个 id 必须得到同一个值——它要进 UNIQUE 约束。
    XCTAssertEqual(try CanonicalURL.note(id: id), note)
    // 不同 id 必须不同，否则第二条笔记会撞唯一约束建不出来。
    XCTAssertNotEqual(try CanonicalURL.note(), try CanonicalURL.note())
  }

  func testNoteSchemeIsCaseInsensitiveAndTrimmed() throws {
    let a = try CanonicalURL("LinkDigest-Note:ABC-123")
    XCTAssertEqual(a.value, "linkdigest-note:abc-123")
    XCTAssertTrue(a.isNote)
  }

  /// 空标识或带空白的标识必须拒绝——它们会破坏唯一性语义。
  func testMalformedNoteURLsAreRejected() {
    XCTAssertThrowsError(try CanonicalURL("linkdigest-note:"))
    XCTAssertThrowsError(try CanonicalURL("linkdigest-note:   "))
    XCTAssertThrowsError(try CanonicalURL("linkdigest-note:has space"))
  }

  /// 最重要的一条：网页 URL 的原有校验一个字都不能松。
  func testWebURLRulesAreUnchanged() throws {
    XCTAssertFalse(try CanonicalURL("https://example.com/a").isNote)
    XCTAssertEqual(try CanonicalURL("HTTPS://Example.COM").value, "https://example.com/")
    XCTAssertEqual(try CanonicalURL("https://example.com:443/x").value, "https://example.com/x")
    // 非 http(s) 且非笔记 scheme，仍然必须拒绝。
    XCTAssertThrowsError(try CanonicalURL("ftp://example.com/a"))
    XCTAssertThrowsError(try CanonicalURL("file:///etc/passwd"))
    XCTAssertThrowsError(try CanonicalURL("javascript:alert(1)"))
    XCTAssertThrowsError(try CanonicalURL("https:///nohost"))
  }
}

/// 笔记 scheme 的放宽必须**只对 userNote 生效**。
///
/// `CapturedDocumentValidator` 的 URL 白名单是抓取内容的安全边界：任何来源若能用
/// 非 http(s) 的 URL 进来，就等于绕过了这里的全部限制。所以放宽绑定到具体 origin，
/// 而不是放宽 scheme 白名单本身。这几条就是钉住那个边界。
final class UserNoteValidationBoundaryTests: XCTestCase {
  private func document(origin: CapturedDocument.Origin, url: String) -> CapturedDocument {
    let now = "2026-08-01T00:00:00Z"
    return CapturedDocument(
      createdAt: now, origin: origin, url: url, title: "标题",
      platform: "note", method: "manual", text: "正文",
      completeness: "complete", capturedAt: now, sourceLabel: "笔记"
    )
  }

  func testUserNoteMayUseNoteScheme() throws {
    let url = try CanonicalURL.note().value
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(document(origin: .userNote, url: url)))
  }

  /// 最关键的一条：浏览器抓取绝不能用笔记 scheme 绕过 URL 校验。
  func testBrowserCaptureCannotUseNoteScheme() throws {
    let url = try CanonicalURL.note().value
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(origin: .browserCapture, url: url)))
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(origin: .manualLink, url: url)))
    XCTAssertThrowsError(try CapturedDocumentValidator.validate(document(origin: .localTranscription, url: url)))
  }

  /// userNote 也不能拿它当后门去用任意 scheme。
  func testUserNoteStillRejectsOtherSchemes() {
    for bad in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/a", "https://example.com/a"] {
      XCTAssertThrowsError(
        try CapturedDocumentValidator.validate(document(origin: .userNote, url: bad)),
        "userNote 只允许笔记 scheme，不该接受 \(bad)"
      )
    }
  }

  /// 普通网页抓取的原有行为不变。
  func testWebCaptureUnchanged() {
    XCTAssertNoThrow(
      try CapturedDocumentValidator.validate(document(origin: .browserCapture, url: "https://example.com/a"))
    )
  }
}

/// 新建笔记的组装。
final class UserNoteDocumentTests: XCTestCase {
  func testNewNotePassesTheCaptureValidator() throws {
    let doc = try UserNoteDocument.make()
    // 最关键的一条：它必须能通过与抓取内容同一个校验器，否则根本落不了库。
    XCTAssertNoThrow(try CapturedDocumentValidator.validate(doc))
    XCTAssertEqual(doc.origin, .userNote)
    XCTAssertTrue((try CanonicalURL(doc.url)).isNote)
    XCTAssertEqual(doc.platform, HistoryPlatformDisplay.noteHost)
  }

  /// 空正文会被校验器拒（emptyContent），所以必须有占位文字——
  /// 一条建不出来的笔记比一条带占位文字的笔记糟糕得多。
  func testEmptyBodyFallsBackToPlaceholderSoTheNoteCanBeCreated() throws {
    for empty in [nil, "", "   ", "\n\t"] {
      let doc = try UserNoteDocument.make(body: empty)
      XCTAssertEqual(doc.text, UserNoteDocument.placeholderBody)
      XCTAssertNoThrow(try CapturedDocumentValidator.validate(doc))
    }
  }

  func testEmptyTitleFallsBackSoTheListRowIsNeverBlank() throws {
    XCTAssertEqual(try UserNoteDocument.make(title: "  ").title, UserNoteDocument.untitledTitle)
    XCTAssertEqual(try UserNoteDocument.make(title: "我的想法").title, "我的想法")
  }

  /// 两条笔记的 URL 必须不同，否则第二条会撞 tasks 的 UNIQUE 约束建不出来。
  func testEachNoteGetsADistinctURL() throws {
    let a = try UserNoteDocument.make()
    let b = try UserNoteDocument.make()
    XCTAssertNotEqual(a.url, b.url)
  }

  /// 正文首行写了 `# 标题` 就拿它当标题，省掉在两个地方写同一句话。
  func testFirstHeadingBecomesTheTitle() {
    XCTAssertEqual(
      UserNoteDocument.derivedTitle(fromBody: "# AI 时代的创作\n\n正文"),
      "AI 时代的创作"
    )
    // 前面的空行不算数，标题仍能被认出来。
    XCTAssertEqual(UserNoteDocument.derivedTitle(fromBody: "\n\n  # 带缩进的\n"), "带缩进的")
  }

  /// 只认第一个非空行的一级标题。正文中段的 `#` 是章节，不是这条笔记叫什么；
  /// `##` 也不是——否则随手写个二级小节就会把标题顶掉。
  func testOnlyALeadingTopLevelHeadingCounts() {
    XCTAssertNil(UserNoteDocument.derivedTitle(fromBody: "先写了一句正文\n\n# 后面才有的标题"))
    XCTAssertNil(UserNoteDocument.derivedTitle(fromBody: "## 二级标题\n正文"))
    XCTAssertNil(UserNoteDocument.derivedTitle(fromBody: "#没有空格\n正文"))
    XCTAssertNil(UserNoteDocument.derivedTitle(fromBody: "#   \n正文"), "只有井号没有字，派生不出标题")
    XCTAssertNil(UserNoteDocument.derivedTitle(fromBody: ""))
  }

  /// 粘贴富文本会带进 U+FFFC，它在标题里显示成一个删不掉的方块。
  func testTitleDropsCharactersThatRenderAsEmptyBoxes() {
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("\u{FFFC}AI 时代的创作"), "AI 时代的创作")
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("标题\u{0007}里的响铃"), "标题 里的响铃")
    // 标题是一行：换行折成空格，多余空白收拢。
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("上一行\n下一行"), "上一行 下一行")
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("  前后留白   中间  "), "前后留白 中间")
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("\u{FFFC}\u{FFFC}"), "")
    // 正常标题不该被动过。
    XCTAssertEqual(UserNoteDocument.sanitizedTitle("AI 时代的创作"), "AI 时代的创作")
  }

  /// 派生标题也要走同一道清洗，否则从粘贴来的正文里取出的标题照样带方块。
  func testDerivedTitleIsSanitizedToo() {
    XCTAssertEqual(UserNoteDocument.derivedTitle(fromBody: "# \u{FFFC}带方块的标题"), "带方块的标题")
  }

  /// 超长标题要截断：列表一行放不下，整条记录就没有抓手了。
  func testOverlongDerivedTitleIsTruncated() {
    let long = String(repeating: "长", count: 200)
    let derived = UserNoteDocument.derivedTitle(fromBody: "# \(long)")
    XCTAssertEqual(derived?.count, 121, "120 个字加一个省略号")
    XCTAssertTrue(derived?.hasSuffix("…") == true)
  }

  /// 侧边栏靠这个 host 把笔记聚成「我的笔记」，而不是掉进「待分类」。
  func testNoteHostMapsToItsOwnSidebarSection() {
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: HistoryPlatformDisplay.noteHost), "我的笔记")
    XCTAssertTrue(HistoryPlatformDisplay.isWellKnown(host: HistoryPlatformDisplay.noteHost))
  }

  func testPlatformRegistryKeepsAliasesNamesAndAssetsTogether() {
    XCTAssertEqual(HistoryPlatformRegistry.canonicalHost(for: "mobile.twitter.com"), "x.com")
    XCTAssertEqual(HistoryPlatformRegistry.canonicalHost(for: "v.douyin.com"), "douyin.com")
    XCTAssertEqual(HistoryPlatformRegistry.canonicalHost(for: "creator.substack.com"), "substack.com")
    XCTAssertEqual(HistoryPlatformRegistry.canonicalHost(for: "uscardforum.com"), "discourse")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "news.ycombinator.com"), "Hacker News")
    XCTAssertEqual(HistoryPlatformDisplay.name(forHost: "douban.com"), "豆瓣")
    XCTAssertTrue(HistoryPlatformDisplay.isWellKnown(host: "juejin.cn"))
    XCTAssertEqual(HistoryPlatformRegistry.bundledAssetName(forHost: "twitter.com"), "x.com")
    XCTAssertNil(HistoryPlatformRegistry.bundledAssetName(forHost: "v2ex.com"))
  }
}

/// 笔记能否真的走完落库前的命令组装。
///
/// 「点新建没反应」时，错误只写进 ManualLinkState 而那个状态不在主界面显示，
/// 失败是静默的。这条测试把那一段搬到测试里，让失败有声音。
final class UserNoteAcceptCommandTests: XCTestCase {
  func testNoteCanBuildAnAcceptCaptureCommand() throws {
    let doc = try UserNoteDocument.make()
    // 这一步在 App 里就是 CaptureIngestService.ingest 的第一件事。
    XCTAssertNoThrow(
      try AcceptCaptureCommand(document: doc, receivedAtMilliseconds: 1_760_000_000_000),
      "笔记无法组装成落库命令——这正是「点了没反应」的来源"
    )
  }
}
