import Foundation
import LinkDigestCore
import LinkDigestPersistence

struct MetricSummary: Codable {
  let rawMilliseconds: [Double]
  let p50Milliseconds: Double
  let p95Milliseconds: Double
  let maxMilliseconds: Double
}

struct DatasetSummary: Codable {
  let tasks: Int
  let snapshots: Int
  let runs: Int
  let artifacts: Int
  let rerunPercent: Double
  let tasksWithMultipleSnapshotsPercent: Double
  let usageCostIncludesMixedNulls: Bool
  let includesNULArtifact: Bool
}

/// 同一份数据、同一次运行里量的「改之前 / 改之后」。
///
/// 分开两次跑没有可比性：机器状态、页缓存、别的进程都不一样。旧实现因此原样
/// 留在 `LegacyQueryBaseline` 里，只给这里用。
struct ComparisonSummary: Codable {
  let legacy: MetricSummary
  let current: MetricSummary
  let speedup: Double
}

struct BenchmarkOutput: Codable {
  let formatVersion: Int
  let configuration: String
  let seed: Int
  let iterationsPerQuery: Int
  let thresholdP95Milliseconds: Double
  let dataset: DatasetSummary
  let recentHistoryPage: MetricSummary
  let singleTaskDetail: MetricSummary
  /// 侧边栏九条计数（含平台分组）。Migration021 前后对比。
  let navigationCounts: ComparisonSummary
  /// 中文正文搜索。Migration022 前后对比。
  let bodySearch: ComparisonSummary
  /// 「待总结」筛选。Migration021 前后对比。
  let unsummarizedFilter: ComparisonSummary
  let passed: Bool
}

func compare(legacy: [Double], current: [Double]) -> ComparisonSummary {
  let legacySummary = summarize(legacy)
  let currentSummary = summarize(current)
  let speedup = currentSummary.p95Milliseconds > 0
    ? legacySummary.p95Milliseconds / currentSummary.p95Milliseconds
    : 0
  return .init(legacy: legacySummary, current: currentSummary, speedup: speedup)
}

func percentile(_ sorted: [Double], percentile: Double) -> Double {
  let rank = max(1, Int(ceil(Double(sorted.count) * percentile)))
  return sorted[min(sorted.count - 1, rank - 1)]
}

func summarize(_ raw: [Double]) -> MetricSummary {
  let sorted = raw.sorted()
  return MetricSummary(rawMilliseconds: raw, p50Milliseconds: percentile(sorted, percentile: 0.50), p95Milliseconds: percentile(sorted, percentile: 0.95), maxMilliseconds: sorted.last ?? 0)
}

func measure(iterations: Int, operation: () throws -> Void) rethrows -> [Double] {
  try (0..<iterations).map { _ in
    let start = ContinuousClock.now
    try operation()
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
  }
}

/// 真实分布的正文，均值约 6 KB。
///
/// 原来这里是 30 字节的一行字。用它量出来的「分页 p95 1.66 ms」只证明了
/// SQLite 能很快地扫 300 KB，和用户那个 3.8 MB 正文、还要走全文搜索的库没有关系。
///
/// 形状按本机实测：绝大多数是几 KB 的文章，少数是转写稿那种几万字的长正文，
/// 还有一批只有一两百字的视频站点描述（og:description，真内容在视频里）。
/// 中英文混排，因为搜索命中率对分词方式敏感。
func benchmarkBody(index: Int, version: Int) -> String {
  let shape = index % 20
  let paragraphs: Int
  switch shape {
  case 0: paragraphs = 1           // 视频条目：只有站点描述
  case 1: paragraphs = 2
  case 19: paragraphs = 90         // 转写稿：几万字
  default: paragraphs = 10         // 常见文章：6 KB 上下
  }
  var text = "标题行 \(index) 版本 \(version)\n"
  for paragraph in 0..<paragraphs {
    text += """
      第 \(paragraph) 段：这一段讲的是内容采集与本地检索的工程取舍，重点在于\
      索引维护成本 index maintenance cost 与查询延迟 query latency 之间怎么换。\
      benchmark paragraph \(paragraph) of item \(index) version \(version).\
      再补一句中文让长度落到真实区间，避免整段都是可压缩的重复字符。\n
      """
  }
  // 每 250 条埋一个独有词，搜索测量才有稳定命中面而不是零命中或者全命中。
  if index % 250 == 0 { text += "\n独有标记词 鹧鸪天 marker-\(index)\n" }
  return text
}

func envelope(index: Int, bodyVersion: Int = 0) -> CaptureEnvelopeV1 {
  let body = benchmarkBody(index: index, version: bodyVersion)
  return CaptureEnvelopeV1(version: 1, requestId: "benchmark-request-\(index)-\(bodyVersion)", createdAt: "2026-07-15T04:00:00Z", idempotencyKey: "benchmark-delivery-\(index)-\(bodyVersion)", source: .init(kind: "browser_capture", url: "https://benchmark.invalid/article/\(index)", title: "Benchmark \(index)", platform: "generic"), capture: .init(method: "rendered_dom", text: body, characterCount: body.unicodeScalars.count, completeness: "full_article", capturedAt: "2026-07-15T04:00:00Z"), evidence: .init(sourceLabel: "Benchmark fixture", usedCookie: false))
}

func usage(index: Int) throws -> RunUsageCost {
  switch index % 4 {
  case 0: return .unknown
  case 1: return RunUsageCost(inputTokens: Int64(index + 10))
  case 2: return RunUsageCost(outputTokens: Int64(index + 5), totalTokens: Int64(index + 15))
  default: return RunUsageCost(inputTokens: Int64(index + 10), outputTokens: Int64(index + 5), totalTokens: Int64(index + 15), costAmountMicros: Int64(index + 100), costCurrencyCode: "USD")
  }
}

func requireReleaseConfiguration() -> String {
  #if LINKDIGEST_RELEASE_BENCHMARK
  return "release"
  #else
  FileHandle.standardError.write(Data("LinkDigestHistoryBenchmark requires a Release build.\n".utf8))
  exit(64)
  #endif
}

let benchmarkConfiguration = requireReleaseConfiguration()
let seed = 20_260_715
// 规模按「正文总量」而不是「条数」定：3000 条 × 均值 6 KB ≈ 18 MB 正文，
// 是本机当前 3.8 MB 的约 5 倍，留足头寸又不至于让一次测量跑成几分钟。
// 原来是 10000 条 × 30 字节 = 300 KB，量的是空库。
let taskCount = 3_000
let extraSnapshotCount = 600
let runCount = 4_500
let iterations = 30
let threshold = 300.0
let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-history-benchmark-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }

let repository = try GRDBHistoryRepository.open(at: LocalDatabaseLocation(directoryURL: root.appendingPathComponent("Application Support/LinkDigest", isDirectory: true)))
defer { try? repository.database.close() }
var captures: [AcceptCaptureResult] = []
captures.reserveCapacity(taskCount)
for index in 0..<taskCount {
  captures.append(try repository.acceptCapture(.init(envelope: envelope(index: index), receivedAtMilliseconds: Int64(index))))
}
for index in 0..<extraSnapshotCount {
  _ = try repository.acceptCapture(.init(envelope: envelope(index: index, bodyVersion: 1), receivedAtMilliseconds: Int64(taskCount + index)))
}

var originalRuns: [RunID] = []
originalRuns.reserveCapacity(taskCount)
for index in 0..<runCount {
  let taskIndex = index < taskCount ? index : index - taskCount
  let capture = captures[taskIndex]
  let parent = index < taskCount ? nil : originalRuns[taskIndex]
  let created = try repository.createRun(.init(taskID: capture.taskID, snapshotID: capture.snapshotID, idempotencyKey: "benchmark-run-\(index)", rerunOfRunID: parent, kind: index % 3 == 0 ? .translate : .summarize, targetLanguage: index % 3 == 0 ? "zh" : nil, createdAtMilliseconds: Int64(20_000 + index)))
  if index < taskCount { originalRuns.append(created.runID) }
  try repository.markRunRunning(.init(runID: created.runID, startedAtMilliseconds: Int64(30_000 + index), provider: .init(profileID: "benchmark-profile", providerKind: "openai-compatible", baseURL: "https://provider.invalid/v1", apiMode: "chat_completions", model: "benchmark-model")))
  // 产物也要有真实长度：总结稿 1-2 KB，旧夹具里是一行字，于是 artifacts 表
  // 在旧 benchmark 里小到扫它不要钱。
  let artifactBody = index == 0
    ? "\0benchmark artifact"
    : "要点 \(index)：" + String(repeating: "这条总结把原文压到一两千字，保留结论和证据。summary line. ", count: 20)
  try repository.finishRun(.init(runID: created.runID, status: .completed, finishedAtMilliseconds: Int64(40_000 + index), artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: artifactBody), usageCost: try usage(index: index)))
}

let counts = try DatabaseMaintenance(database: repository.database).counts()
guard counts == HistoryTableCounts(
  tasks: taskCount, snapshots: taskCount + extraSnapshotCount,
  deliveries: taskCount + extraSnapshotCount, runs: runCount, artifacts: runCount
) else { throw RepositoryFailure.integrityCheckFailed }
let nulArtifact = try repository.detail(taskID: captures[0].taskID).runs.compactMap(\.artifact).first { $0.bodyText == "\0benchmark artifact" }
guard nulArtifact != nil else { throw RepositoryFailure.integrityCheckFailed }
let detailTaskID = captures[taskCount / 2].taskID
_ = try repository.historyPage(limit: 50, after: nil)
_ = try repository.detail(taskID: detailTaskID)
let recent = try measure(iterations: iterations) {
  guard try repository.historyPage(limit: 50, after: nil).rows.count == 50 else { throw RepositoryFailure.integrityCheckFailed }
}
let detail = try measure(iterations: iterations) {
  guard try repository.detail(taskID: detailTaskID).snapshots.count >= 1 else { throw RepositoryFailure.integrityCheckFailed }
}

// 三组前后对比。每组先各跑一次预热，把冷页缓存的差异从测量里赶出去。
let searchTerm = "鹧鸪天"
_ = try LegacyQueryBaseline.navigationCounts(repository)
_ = try repository.navigationCounts()
_ = try LegacyQueryBaseline.search(repository, text: searchTerm, limit: 50)
_ = try repository.historyPage(limit: 50, after: nil, filter: .init(searchText: searchTerm))
_ = try LegacyQueryBaseline.unsummarized(repository, limit: 50)
_ = try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .unsummarized))

// 命中面先对账：两边找回同一批条目，「快了 40 倍」才不是因为新实现少找了东西。
let legacyHits = try LegacyQueryBaseline.search(repository, text: searchTerm, limit: 200)
let currentHits = try repository.historyPage(
  limit: 200, after: nil, filter: .init(searchText: searchTerm)
).rows.count
guard legacyHits > 0, currentHits >= legacyHits else { throw RepositoryFailure.integrityCheckFailed }

let legacyNavigation = try measure(iterations: iterations) {
  _ = try LegacyQueryBaseline.navigationCounts(repository)
}
let currentNavigation = try measure(iterations: iterations) {
  _ = try repository.navigationCounts()
}
let legacySearch = try measure(iterations: iterations) {
  _ = try LegacyQueryBaseline.search(repository, text: searchTerm, limit: 50)
}
let currentSearch = try measure(iterations: iterations) {
  _ = try repository.historyPage(limit: 50, after: nil, filter: .init(searchText: searchTerm))
}
let legacyUnsummarized = try measure(iterations: iterations) {
  _ = try LegacyQueryBaseline.unsummarized(repository, limit: 50)
}
let currentUnsummarized = try measure(iterations: iterations) {
  _ = try repository.historyPage(limit: 50, after: nil, filter: .init(scope: .unsummarized))
}

let recentSummary = summarize(recent)
let detailSummary = summarize(detail)
let passed = recentSummary.p95Milliseconds <= threshold && detailSummary.p95Milliseconds <= threshold
let output = BenchmarkOutput(
  formatVersion: 2,
  configuration: benchmarkConfiguration,
  seed: seed,
  iterationsPerQuery: iterations,
  thresholdP95Milliseconds: threshold,
  dataset: .init(tasks: counts.tasks, snapshots: counts.snapshots, runs: counts.runs, artifacts: counts.artifacts, rerunPercent: 100.0 * Double(runCount - taskCount) / Double(runCount), tasksWithMultipleSnapshotsPercent: 100.0 * Double(extraSnapshotCount) / Double(taskCount), usageCostIncludesMixedNulls: true, includesNULArtifact: true),
  recentHistoryPage: recentSummary,
  singleTaskDetail: detailSummary,
  navigationCounts: compare(legacy: legacyNavigation, current: currentNavigation),
  bodySearch: compare(legacy: legacySearch, current: currentSearch),
  unsummarizedFilter: compare(legacy: legacyUnsummarized, current: currentUnsummarized),
  passed: passed
)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(output)); FileHandle.standardOutput.write(Data("\n".utf8))
if !passed { exit(2) }
