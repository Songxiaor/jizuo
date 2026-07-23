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

struct BenchmarkOutput: Codable {
  let formatVersion: Int
  let configuration: String
  let seed: Int
  let iterationsPerQuery: Int
  let thresholdP95Milliseconds: Double
  let dataset: DatasetSummary
  let recentHistoryPage: MetricSummary
  let singleTaskDetail: MetricSummary
  let passed: Bool
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

func envelope(index: Int, bodyVersion: Int = 0) -> CaptureEnvelopeV1 {
  let body = "benchmark body \(index) version \(bodyVersion)"
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
let taskCount = 10_000
let extraSnapshotCount = 2_000
let runCount = 15_000
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
  let artifactBody = index == 0 ? "\0benchmark artifact" : "benchmark artifact \(index)"
  try repository.finishRun(.init(runID: created.runID, status: .completed, finishedAtMilliseconds: Int64(40_000 + index), artifact: .init(contentFormat: .markdown, completeness: .complete, bodyText: artifactBody), usageCost: try usage(index: index)))
}

let counts = try DatabaseMaintenance(database: repository.database).counts()
guard counts == HistoryTableCounts(tasks: 10_000, snapshots: 12_000, deliveries: 12_000, runs: 15_000, artifacts: 15_000) else { throw RepositoryFailure.integrityCheckFailed }
let nulArtifact = try repository.detail(taskID: captures[0].taskID).runs.compactMap(\.artifact).first { $0.bodyText == "\0benchmark artifact" }
guard nulArtifact != nil else { throw RepositoryFailure.integrityCheckFailed }
let detailTaskID = captures[5_000].taskID
_ = try repository.historyPage(limit: 50, after: nil)
_ = try repository.detail(taskID: detailTaskID)
let recent = try measure(iterations: iterations) {
  guard try repository.historyPage(limit: 50, after: nil).rows.count == 50 else { throw RepositoryFailure.integrityCheckFailed }
}
let detail = try measure(iterations: iterations) {
  guard try repository.detail(taskID: detailTaskID).snapshots.count >= 1 else { throw RepositoryFailure.integrityCheckFailed }
}
let recentSummary = summarize(recent)
let detailSummary = summarize(detail)
let passed = recentSummary.p95Milliseconds <= threshold && detailSummary.p95Milliseconds <= threshold
let output = BenchmarkOutput(
  formatVersion: 1,
  configuration: benchmarkConfiguration,
  seed: seed,
  iterationsPerQuery: iterations,
  thresholdP95Milliseconds: threshold,
  dataset: .init(tasks: counts.tasks, snapshots: counts.snapshots, runs: counts.runs, artifacts: counts.artifacts, rerunPercent: 100.0 * Double(runCount - taskCount) / Double(runCount), tasksWithMultipleSnapshotsPercent: 100.0 * Double(extraSnapshotCount) / Double(taskCount), usageCostIncludesMixedNulls: true, includesNULArtifact: true),
  recentHistoryPage: recentSummary,
  singleTaskDetail: detailSummary,
  passed: passed
)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(output)); FileHandle.standardOutput.write(Data("\n".utf8))
if !passed { exit(2) }
