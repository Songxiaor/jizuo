import XCTest
@testable import LinkDigestApp
import LinkDigestCore

@MainActor
final class ModelHealthTests: XCTestCase {
  private let zen = "https://opencode.ai/zen/v1"

  private func registry(now: Int64 = 1_000_000) -> ModelHealthRegistry {
    let suite = "model-health-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return ModelHealthRegistry(defaults: defaults, now: { now })
  }

  func testFailureCodesMapToWhatTheUserShouldDo() {
    XCTAssertEqual(ModelHealthStatus(failure: .modelNotFound), .removed)
    XCTAssertEqual(ModelHealthStatus(failure: .freeTierRestricted), .officialClientOnly)
    XCTAssertEqual(ModelHealthStatus(failure: .providerUnavailable), .temporarilyUnavailable)
    XCTAssertEqual(ModelHealthStatus(failure: .providerBillingLimited), .billingLimited)
    XCTAssertEqual(ModelHealthStatus(failure: .authInvalid), .keyInvalid)
    XCTAssertNil(ModelHealthStatus(failure: .networkInterrupted), "网络断了不说明模型本身怎样")
    XCTAssertNil(ModelHealthStatus(failure: .inputTooLarge))
  }

  func testSavedModelMissingFromCatalogIsMarkedRemoved() {
    let health = registry()
    // 从没在列表里出现过的（本地模型别名、中转站不列出的）不判下架。
    health.applyCatalog(baseURL: zen, catalog: ["deepseek-v4-flash"], savedModels: ["llama3"], isTruncated: false)
    XCTAssertNil(health.record(for: zen, model: "llama3"))
    // 出现过、后来不见了，才是下架。
    health.applyCatalog(baseURL: zen, catalog: ["longcat-2.0-free", "deepseek-v4-flash"], savedModels: [], isTruncated: false)
    health.applyCatalog(
      baseURL: zen, catalog: ["deepseek-v4-flash", "mimo-v2.5-free"],
      savedModels: ["longcat-2.0-free", "deepseek-v4-flash"], isTruncated: false
    )
    XCTAssertEqual(health.record(for: zen, model: "longcat-2.0-free")?.status, .removed)
    XCTAssertNil(health.record(for: zen, model: "deepseek-v4-flash"))
    XCTAssertEqual(health.record(for: zen + "/", model: "longcat-2.0-free")?.status, .removed, "末尾斜杠不影响匹配")

    // 列表被截断时不下结论。
    let truncated = registry()
    truncated.applyCatalog(baseURL: zen, catalog: ["longcat-2.0-free"], savedModels: [], isTruncated: false)
    truncated.applyCatalog(baseURL: zen, catalog: ["a"], savedModels: ["longcat-2.0-free"], isTruncated: true)
    XCTAssertNil(truncated.record(for: zen, model: "longcat-2.0-free"))

    // 又回到列表里了：清掉「因不在列表而判下架」的结论，但不动真实调用得出的结论。
    health.record(baseURL: zen, model: "mimo-v2.5-free", status: .officialClientOnly, source: .run)
    health.applyCatalog(baseURL: zen, catalog: ["longcat-2.0-free", "mimo-v2.5-free"], savedModels: [], isTruncated: false)
    XCTAssertNil(health.record(for: zen, model: "longcat-2.0-free"))
    XCTAssertEqual(health.record(for: zen, model: "mimo-v2.5-free")?.status, .officialClientOnly)
  }

  func testBadgesExplainAndGoStaleExceptPermanentProblems() {
    let day = ModelHealthRecord.freshnessMilliseconds
    let fresh = ModelHealthBadge(record: .init(status: .available, checkedAtMilliseconds: 0, source: .probe), nowMilliseconds: 10)
    XCTAssertEqual(fresh.text, "可用")
    let stale = ModelHealthBadge(record: .init(status: .available, checkedAtMilliseconds: 0, source: .probe), nowMilliseconds: day + 1)
    XCTAssertEqual(stale.text, "可用 · 需重新检测")
    let removed = ModelHealthBadge(record: .init(status: .removed, checkedAtMilliseconds: 0, source: .catalog), nowMilliseconds: day * 3)
    XCTAssertEqual(removed.text, "已下架", "下架不会自己变好，过期也照样显示")
    XCTAssertEqual(ModelHealthBadge(record: nil, nowMilliseconds: 0).text, "未检测")
    XCTAssertEqual(
      ModelHealthBadge(record: .init(status: .officialClientOnly, checkedAtMilliseconds: 0, source: .run), nowMilliseconds: 0).text,
      "仅限官方客户端"
    )
  }

  func testProbePlanSeparatesFreeModelsFromPaidOnes() {
    let plan = ProviderSettingsViewModel.probePlan(for: ["deepseek-v4-flash-free", "deepseek-v4-flash", "mimo-v2.5-free", "freestyle-pro"])
    XCTAssertEqual(plan.freeModels, ["deepseek-v4-flash-free", "mimo-v2.5-free"])
    XCTAssertEqual(plan.paidModels, ["deepseek-v4-flash", "freestyle-pro"], "只有独立的 free 词才算免费")
  }

  func testOnlyModelProblemsOfferTheFixButton() {
    XCTAssertEqual(
      ModelFailureFix(runState: .failed(intent: .translate, code: ModelProviderErrorCode.modelNotFound.rawValue))?.buttonTitle,
      "去「模型与识别」换一个模型"
    )
    XCTAssertEqual(
      ModelFailureFix(runState: .failed(intent: .translate, code: ModelProviderErrorCode.authInvalid.rawValue))?.buttonTitle,
      "去更换密钥"
    )
    XCTAssertNil(ModelFailureFix(runState: .failed(intent: .translate, code: ModelProviderErrorCode.providerUnavailable.rawValue)))
    XCTAssertNil(ModelFailureFix(runState: .failed(intent: .translate, code: ModelProviderErrorCode.networkInterrupted.rawValue)))
    XCTAssertNil(ModelFailureFix(runState: .idle))
  }

  func testProbeResultIsNotOverwrittenByTheLateRunNotification() {
    let health = registry()
    health.record(baseURL: zen, model: "m", status: .available, source: .probe)
    health.record(baseURL: zen, model: "m", status: .available, source: .run)
    XCTAssertEqual(health.record(for: zen, model: "m")?.source, .probe)
  }

  func testDayGroupSectionsKeepOrderAndIndices() {
    func row(_ savedAt: Int64) -> HistoryRowProjection {
      HistoryRowProjection(
        taskID: TaskID(UUID()), title: "t", canonicalURL: "https://x.com/a/status/1", host: "x.com", sourceLabel: "",
        latestRunKind: nil, latestRunStatus: nil, latestModel: nil, updatedAtMilliseconds: savedAt,
        createdAtMilliseconds: savedAt, latestRunAtMilliseconds: nil, usageCost: .unknown, artifactPreview: nil
      )
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nowMs: Int64 = 1_800_000_000_000
    let day: Int64 = 86_400_000
    let rows = [row(nowMs), row(nowMs - 1), row(nowMs - day), row(nowMs - day - 1), row(nowMs - 3 * day)]
    let sections = HistoryListFinding.sections(for: rows, now: now, calendar: .current)
    XCTAssertEqual(sections.map { $0.entries.map(\.index) }.flatMap { $0 }, [0, 1, 2, 3, 4])
    XCTAssertEqual(sections.count, 3)
  }

  func testPreviewDoesNotCutArticleBodyAtItsOwnTitle() {
    XCTAssertEqual(
      HistoryListFinding.sourcePreviewLine(
        title: "Claude", sourcePreview: "昨天我用 Claude 写了个插件", titleComesFromBody: false
      ),
      "昨天我用 Claude 写了个插件"
    )
  }

  func testListOrdinalIsNotASentenceEnd() {
    let text = "如果你想围绕公众号封面做工具，这三个 GitHub 项目值得先看： 1. cover-maker 2. md2wechat"
    XCTAssertFalse(CapturedContentNaming.leadingSentence(from: text).hasSuffix("1."))
    XCTAssertEqual(CapturedContentNaming.leadingSentence(from: "版本 2.5 已发布. 下一句"), "版本 2.5 已发布.")
    XCTAssertEqual(CapturedContentNaming.leadingSentence(from: "Done. Next"), "Done.")
  }

  func testArtifactPreviewDropsLayerHeadings() {
    XCTAssertEqual(
      HistoryRowProjection.sanitizedDirectoryPreview("## 配文\n但很遗憾，好几个关键问题上", isSummary: true),
      "但很遗憾，好几个关键问题上"
    )
  }
}
