import CryptoKit
import Foundation
import LinkDigestCore
import LinkDigestAdapters
import WebKit

// Loop 5 / PRD section 12 acceptance tool. The manifest is the durable test
// contract; results are observations from either the exact production network
// path or the production HTML extractor applied to synthetic, credential-free
// fixtures. Fixture verification never substitutes for a successful peer-bound
// public-network run.

struct SampleManifestEntry: Codable {
  let id: String
  let category: String
  let url: String
  let expectedTitle: String
  let expectedBodyStart: String
  let expectedBodyEnd: String
  let minimumCharacterCount: Int
  let completenessLabel: String
  let allowedDegradationPaths: [String]
  let expectedOutcome: String // capture | browser-extension | intentional-failure
  let expectedErrorCodes: [String]
  let htmlFile: String?
}

struct AcceptanceCheck: Codable {
  let name: String
  let passed: Bool
  let detail: String
}

struct SampleResult: Codable {
  let id: String
  let category: String
  let url: String
  let status: String
  let errorCode: String?
  let title: String?
  let characterCount: Int?
  let textPrefix: String?
  let textSuffix: String?
  let completeness: String?
  let allowedDegradationPaths: [String]
  let checks: [AcceptanceCheck]
}

enum ManifestError: Error, CustomStringConvertible {
  case invalid(String)
  var description: String {
    switch self { case let .invalid(message): message }
  }
}

func stableErrorCode(_ error: Error) -> String {
  guard let manual = error as? ManualLinkError else { return "unknown" }
  switch manual {
  case .invalidURL: return "invalidURL"
  case .unsafeURL: return "unsafeURL"
  case .webHostNotAllowed: return "webHostNotAllowed"
  case .invalidPageResult: return "invalidPageResult"
  case .proxyHTTPSRequired: return "proxyHTTPSRequired"
  case .proxyAuthenticationRequired: return "proxyAuthenticationRequired"
  case .fakeIPProxyUnavailable: return "fakeIPProxyUnavailable"
  case .proxyTLSValidation: return "proxyTLSValidation"
  case .responseStatus: return "responseStatus"
  case .unsupportedContentType: return "unsupportedContentType"
  case .responseTooLarge: return "responseTooLarge"
  case .timedOut: return "timedOut"
  case .emptyContent: return "emptyContent"
  case .loginRequired: return "loginRequired"
  case .shareLinkExpired: return "shareLinkExpired"
  case .verificationRequired: return "verificationRequired"
  case .extensionCaptureRequired: return "extensionCaptureRequired"
  case .githubRepositoryUnavailable: return "githubRepositoryUnavailable"
  case .githubRateLimited: return "githubRateLimited"
  case .cancelled: return "cancelled"
  case .network: return "network"
  }
}

func prefixSuffix(_ text: String, span: Int = 200) -> (String, String) {
  let scalars = Array(text.unicodeScalars)
  return (
    String(String.UnicodeScalarView(scalars.prefix(span))),
    String(String.UnicodeScalarView(scalars.suffix(span)))
  )
}

func loadEntries(_ path: String) throws -> [SampleManifestEntry] {
  try JSONDecoder().decode([SampleManifestEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func validateManifest(_ entries: [SampleManifestEntry]) throws {
  let expectedCounts = ["static": 10, "csr": 5, "login-visible": 3, "intentional-fail": 2]
  guard entries.count == 20 else { throw ManifestError.invalid("expected 20 samples, found \(entries.count)") }
  guard Set(entries.map(\.id)).count == entries.count else { throw ManifestError.invalid("sample ids must be unique") }
  for (category, count) in expectedCounts {
    let actual = entries.count { $0.category == category }
    guard actual == count else { throw ManifestError.invalid("expected \(count) \(category) samples, found \(actual)") }
  }
  guard entries.contains(where: { $0.category == "static" && URL(string: $0.url)?.host == "github.com" }) else {
    throw ManifestError.invalid("one static sample must be a public GitHub repository page")
  }
  for entry in entries {
    guard URL(string: entry.url)?.scheme == "https" else { throw ManifestError.invalid("\(entry.id): URL must use https") }
    guard !entry.expectedTitle.isEmpty else { throw ManifestError.invalid("\(entry.id): expectedTitle is empty") }
    guard entry.minimumCharacterCount >= 0 else { throw ManifestError.invalid("\(entry.id): minimumCharacterCount is negative") }
    guard !entry.completenessLabel.isEmpty else { throw ManifestError.invalid("\(entry.id): completenessLabel is empty") }
    guard !entry.allowedDegradationPaths.isEmpty else { throw ManifestError.invalid("\(entry.id): allowedDegradationPaths is empty") }
    guard ["capture", "browser-extension", "intentional-failure"].contains(entry.expectedOutcome) else {
      throw ManifestError.invalid("\(entry.id): unknown expectedOutcome")
    }
    if entry.category == "login-visible" {
      guard entry.expectedOutcome == "browser-extension",
            entry.allowedDegradationPaths == ["browser-extension-current-page-dom"],
            entry.htmlFile != nil else {
        throw ManifestError.invalid("\(entry.id): login-visible samples may only degrade to the browser extension and need a synthetic fixture")
      }
    }
    if entry.category == "intentional-fail" {
      guard entry.expectedOutcome == "intentional-failure", !entry.expectedErrorCodes.isEmpty, entry.htmlFile != nil else {
        throw ManifestError.invalid("\(entry.id): intentional failures need expected errors and a synthetic fixture")
      }
    }
  }
}

func checks(for entry: SampleManifestEntry, title: String?, text: String, completeness: String) -> [AcceptanceCheck] {
  let scalars = Array(text.unicodeScalars)
  let startWindow = String(String.UnicodeScalarView(scalars.prefix(1_200)))
  let endWindow = String(String.UnicodeScalarView(scalars.suffix(1_200)))
  return [
    .init(name: "title", passed: title?.localizedCaseInsensitiveContains(entry.expectedTitle) == true, detail: "expected title to contain manifest marker"),
    .init(name: "body-start", passed: entry.expectedBodyStart.isEmpty || startWindow.localizedCaseInsensitiveContains(entry.expectedBodyStart), detail: "expected marker in first 1200 scalars"),
    .init(name: "body-end", passed: entry.expectedBodyEnd.isEmpty || endWindow.localizedCaseInsensitiveContains(entry.expectedBodyEnd), detail: "expected marker in last 1200 scalars"),
    .init(name: "minimum-character-count", passed: scalars.count >= entry.minimumCharacterCount, detail: "actual=\(scalars.count) minimum=\(entry.minimumCharacterCount)"),
    .init(name: "completeness", passed: completeness == entry.completenessLabel, detail: "actual=\(completeness) expected=\(entry.completenessLabel)")
  ]
}

func successResult(_ entry: SampleManifestEntry, title: String?, text: String, completeness: String) -> SampleResult {
  let acceptance = checks(for: entry, title: title, text: text, completeness: completeness)
  let (prefix, suffix) = prefixSuffix(text)
  return .init(
    id: entry.id, category: entry.category, url: entry.url,
    status: acceptance.allSatisfy(\.passed) ? "success" : "expectation-mismatch",
    errorCode: nil, title: title, characterCount: text.unicodeScalars.count,
    textPrefix: prefix, textSuffix: suffix, completeness: completeness,
    allowedDegradationPaths: entry.allowedDegradationPaths, checks: acceptance
  )
}

func failureResult(_ entry: SampleManifestEntry, error: Error) -> SampleResult {
  let code = stableErrorCode(error)
  let status: String
  if entry.expectedOutcome == "browser-extension" && entry.expectedErrorCodes.contains(code) {
    status = "degraded"
  } else if entry.expectedOutcome == "intentional-failure" && entry.expectedErrorCodes.contains(code) {
    status = "failed-as-expected"
  } else {
    status = "unexpected-failure"
  }
  return .init(
    id: entry.id, category: entry.category, url: entry.url, status: status,
    errorCode: code, title: nil, characterCount: nil, textPrefix: nil,
    textSuffix: nil, completeness: nil,
    allowedDegradationPaths: entry.allowedDegradationPaths, checks: []
  )
}

func writeResults(_ results: [SampleResult], to path: String) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(results).write(to: URL(fileURLWithPath: path), options: .atomic)
  FileHandle.standardError.write(Data("wrote \(results.count) results to \(path)\n".utf8))
}

guard CommandLine.arguments.count >= 3 else {
  FileHandle.standardError.write(Data("""
  usage:
    LinkDigestManualSampleVerifier validate-manifest <manifest.json>
    LinkDigestManualSampleVerifier verify-network <manifest.json> <output.json>
    LinkDigestManualSampleVerifier verify-fixtures <manifest.json> <output.json>
    LinkDigestManualSampleVerifier verify-github <output.json>
    LinkDigestManualSampleVerifier verify-wechat-wkwebview <mp.weixin.qq.com URL>
    LinkDigestManualSampleVerifier verify-douyin-wkwebview <douyin URL> [data-store UUID]

  verify-network uses PeerBoundNetworkWebPageFetcher + ManualLinkCaptureService.
  verify-fixtures only checks entries with htmlFile using MinimalHTMLExtractor;
  it proves extractor/fallback semantics, never public-network reachability.

  """.utf8))
  exit(64)
}

let mode = CommandLine.arguments[1]
guard ["validate-manifest", "verify-network", "verify-fixtures", "verify-github", "verify-wechat-wkwebview", "verify-douyin-wkwebview"].contains(mode) else { exit(64) }

if mode == "verify-douyin-wkwebview" {
  guard (3...4).contains(CommandLine.arguments.count),
        let url = URL(string: CommandLine.arguments[2])
  else { exit(64) }
  let dataStore: WKWebsiteDataStore
  if CommandLine.arguments.count == 4 {
    guard let identifier = UUID(uuidString: CommandLine.arguments[3]) else { exit(64) }
    dataStore = WKWebsiteDataStore(forIdentifier: identifier)
  } else {
    dataStore = .nonPersistent()
  }
  let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  let started = ContinuousClock.now
  do {
    let service = DouyinWKWebViewCaptureService(dataStore: dataStore, userAgent: userAgent)
    let document = try await service.capture(url: url)
    let note = MarkdownNoteFrontmatter.parse(document.text)
    let bodyImageURLs = MarkdownRemoteImageReferences.absoluteHTTPSURLs(in: note.body)
    let plainBody = note.body
      .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let elapsed = started.duration(to: .now)
    func reportValue(_ value: String?) -> String {
      (value ?? "")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
    }
    print("status=success canonicalURL=\(document.url) title=\(reportValue(document.title)) author=\(reportValue(note.author)) publishedAt=\(reportValue(note.published)) characters=\(plainBody.unicodeScalars.count) images=\(bodyImageURLs.count) elapsed=\(elapsed) verificationPage=false")
    exit(0)
  } catch {
    let elapsed = started.duration(to: .now)
    let code = stableErrorCode(error)
    let verificationPage = code == "verificationRequired"
    print("status=failure errorCode=\(code) elapsed=\(elapsed) verificationPage=\(verificationPage)")
    exit(1)
  }
}

if mode == "verify-wechat-wkwebview" {
  guard CommandLine.arguments.count == 3,
        let url = URL(string: CommandLine.arguments[2])
  else { exit(64) }
  let started = ContinuousClock.now
  do {
    let service = WeChatWKWebViewCaptureService()
    let document = try await service.capture(url: url)
    let note = MarkdownNoteFrontmatter.parse(document.text)
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-manual-wechat-sample.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let cache = GitHubREADMEImageCache(applicationSupportRoot: cacheRoot)
    let resources = ProxyAwareWebPageFetcher()
    let taskID = TaskID(), snapshotID = ContentSnapshotID()
    let bodyImageURLs = MarkdownRemoteImageReferences.absoluteHTTPSURLs(in: note.body)
    await cache.stageWeChatImages(
      bodyImageURLs: bodyImageURLs.map(\.absoluteString),
      coverImageURL: nil,
      articleURL: url,
      captureID: document.requestID,
      resources: resources
    )
    cache.promote(captureID: document.requestID, taskID: taskID, snapshotID: snapshotID)
    let downloaded = cache.localImageURLs(taskID: taskID, snapshotID: snapshotID)
    let elapsed = started.duration(to: .now)
    let coverDownloaded = note.coverImage.map { remote in
      let digest = SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
      return downloaded.contains { $0.lastPathComponent == digest }
    } ?? false
    let downloadedFilenames = Set(downloaded.map(\.lastPathComponent))
    let inlineDownloaded = Set(bodyImageURLs.map { remote in
      SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }).intersection(downloadedFilenames).count
    let plainBody = note.body
      .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"<img\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    func reportValue(_ value: String?) -> String {
      (value ?? "").replacingOccurrences(of: "\n", with: " ")
    }
    print("status=success characters=\(plainBody.unicodeScalars.count) capturedImages=\(bodyImageURLs.count) downloadedImages=\(inlineDownloaded) cover=\(coverDownloaded) accountName=\(reportValue(note.accountName)) author=\(reportValue(note.author)) publishedAt=\(reportValue(note.published)) elapsed=\(elapsed) verificationPage=false")
    exit(0)
  } catch {
    let elapsed = started.duration(to: .now)
    let code = stableErrorCode(error)
    print("status=failure errorCode=\(code) elapsed=\(elapsed) verificationPage=\(code == "verificationRequired")")
    exit(1)
  }
}

if mode == "verify-github" {
  guard CommandLine.arguments.count == 3 else { exit(64) }
  let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("linkdigest-manual-github-samples", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: cacheRoot) }
  let resources = ProxyAwareWebPageFetcher()
  let cache = GitHubREADMEImageCache(applicationSupportRoot: cacheRoot)
  let adapter = GitHubRepositorySourceAdapter(resources: resources, imageCache: cache)
  let service = ManualLinkCaptureService(fetcher: resources, sourceAdapters: [adapter])
  let samples = [
    ("github-powertoys-relative-images", "https://github.com/microsoft/PowerToys"),
    ("github-vscode", "https://github.com/microsoft/vscode"),
    ("github-missing", "https://github.com/linkdigest-does-not-exist/does-not-exist")
  ]
  var githubResults: [SampleResult] = []
  for (id, rawURL) in samples {
    FileHandle.standardError.write(Data("fetching \(id) \(rawURL)\n".utf8))
    do {
      let document = try await service.capture(urlString: rawURL)
      let (prefix, suffix) = prefixSuffix(document.text)
      githubResults.append(.init(id: id, category: "github-adapter", url: rawURL, status: "success", errorCode: nil, title: document.title, characterCount: document.characterCount, textPrefix: prefix, textSuffix: suffix, completeness: document.completeness, allowedDegradationPaths: [], checks: []))
    } catch {
      githubResults.append(.init(id: id, category: "github-adapter", url: rawURL, status: "failure", errorCode: stableErrorCode(error), title: nil, characterCount: nil, textPrefix: nil, textSuffix: nil, completeness: nil, allowedDegradationPaths: [], checks: []))
    }
  }
  try writeResults(githubResults, to: CommandLine.arguments[2])
  exit(0)
}
let entries = try loadEntries(CommandLine.arguments[2])
try validateManifest(entries)
if mode == "validate-manifest" {
  print("manifest: OK (20 samples: static=10 csr=5 login-visible=3 intentional-fail=2; GitHub baseline present)")
  exit(0)
}
guard CommandLine.arguments.count == 4 else { exit(64) }

var results: [SampleResult] = []
if mode == "verify-network" {
  let resources = ProxyAwareWebPageFetcher()
  let service = ManualLinkCaptureService(fetcher: resources, sourceAdapters: [GitHubRepositorySourceAdapter(resources: resources)])
  for entry in entries {
    FileHandle.standardError.write(Data("fetching \(entry.id) \(entry.url)\n".utf8))
    do {
      let document = try await service.capture(urlString: entry.url)
      results.append(successResult(entry, title: document.title, text: document.text, completeness: document.completeness))
    } catch {
      results.append(failureResult(entry, error: error))
    }
  }
} else {
  let extractor = MinimalHTMLExtractor()
  let manifestDirectory = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent()
  for entry in entries where entry.htmlFile != nil {
    do {
      let fileURL = URL(fileURLWithPath: entry.htmlFile!, relativeTo: manifestDirectory).standardizedFileURL
      let html = try String(contentsOf: fileURL, encoding: .utf8)
      let extracted = try extractor.extract(html: html)
      results.append(successResult(entry, title: extracted.title, text: extracted.text, completeness: "best_effort"))
    } catch {
      results.append(failureResult(entry, error: error))
    }
  }
}
try writeResults(results, to: CommandLine.arguments[3])
