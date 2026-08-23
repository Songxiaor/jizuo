import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

/// 整理器的分片并发执行。
///
/// 整理曾是逐片串行：半小时视频的转写稿切 6 片、每片几十秒，串起来就是
/// 三五分钟白等，而分片之间毫无依赖。改成并发后必须钉住三件事：
/// 真的在并发（不是换了写法照旧串行）、结果按分片序号还原（绝不能按完成
/// 顺序）、单片失败保留该片原文而不拖垮整体。
final class TranscriptTidierParallelTests: XCTestCase {
  /// 三段各 ~5900 字的转写稿：chunker 上限 6000，恰好一段一片。
  private static let paragraphs = [
    String(repeating: "甲", count: 5_900),
    String(repeating: "乙", count: 5_900),
    String(repeating: "丙", count: 5_900),
  ]
  private static var transcript: String { paragraphs.joined(separator: "\n\n") }

  private static let tidiedJSON = #"""
  {"choices":[{"message":{"content":"已整理。"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
  """#

  private func makeTidier(baseURL: URL, apiKey: String) async throws -> OpenAICompatibleTranscriptTidier {
    let profileStore = TidyProfileStore()
    let secretStore = TidySecretStore()
    let reference = SecretReference(rawValue: "tidy-parallel-reference")
    // 直接种到内存 store：save() 的公开校验拒绝 http，而 loopback HTTP
    // 是假服务器的唯一形态，ProviderProfile 自身有专门的放行参数。
    try await profileStore.save(try ProviderProfile(
      baseURL: baseURL.appending(path: "v1").absoluteString,
      model: "fixture-model",
      secretReference: reference,
      allowLoopbackHTTP: true
    ))
    try await secretStore.save(apiKey, for: reference)
    return OpenAICompatibleTranscriptTidier(
      configurationService: ProviderConfigurationService(profileStore: profileStore, secretStore: secretStore)
    )
  }

  /// 并发证明用墙钟：每片响应被脚本压住 0.8 秒，串行至少 2.4 秒，
  /// 并发应在 1 秒上下。阈值 2.0 秒给足了本机波动余量，同时仍能
  /// 可靠区分「并发」与「串行」两种实现。
  func testChunksRunConcurrentlyAndUsageIsSummed() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let script = FakeOpenAICompatibleServer.ResponseScript(
      contentType: "application/json",
      chunks: [.init(Self.tidiedJSON, delay: 0.8)]
    )
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [script, script, script])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let clock = ContinuousClock()
    let started = clock.now
    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .transcript)
    let elapsed = clock.now - started

    XCTAssertEqual(server.attemptCount, 3)
    XCTAssertLessThan(elapsed, .seconds(2), "三片各延迟 0.8s，串行 ≥2.4s——超过 2s 说明退回了串行")
    XCTAssertEqual(outcome.text, "已整理。\n\n已整理。\n\n已整理。")
    XCTAssertEqual(outcome.failedChunkCount, 0)
    XCTAssertEqual(outcome.chunkCount, 3)
    XCTAssertEqual(outcome.promptTokens, 30)
    XCTAssertEqual(outcome.completionTokens, 15)
    XCTAssertEqual(outcome.totalTokens, 45)
  }

  /// 单片失败：该片保留原文，且必须停在它自己的位置上——并发完成顺序不定，
  /// 位置错乱不崩不报错，只表现为「文稿前言不搭后语」。
  func testFailedChunkKeepsOriginalTextAtItsOwnPosition() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(
      contentType: "application/json",
      chunks: [.init(Self.tidiedJSON)]
    )
    // 前两个到达的请求成功，第三个（也是之后的一切）拿 500。
    // 到达顺序在并发下不定，所以断言只依赖「恰有一片失败」这一事实。
    let server = FakeOpenAICompatibleServer(
      expectedAPIKey: key,
      scripts: [success, success, .init(statusCode: 500)]
    )
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .transcript)

    XCTAssertEqual(outcome.failedChunkCount, 1)
    XCTAssertEqual(outcome.chunkCount, 3)
    let parts = outcome.text.components(separatedBy: "\n\n")
    XCTAssertEqual(parts.count, 3)
    var originalsKept = 0
    for (index, part) in parts.enumerated() {
      if part == "已整理。" { continue }
      XCTAssertEqual(part, Self.paragraphs[index], "失败片的原文必须留在它自己的位置")
      originalsKept += 1
    }
    XCTAssertEqual(originalsKept, 1)
  }

  /// 全片失败是配置/服务故障，不是部分结果：必须整体报错，
  /// 不能把原文原样返回冒充成功。
  func testAllChunksFailingSurfacesTheFailure() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [.init(statusCode: 500)])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    do {
      _ = try await tidier.tidy(text: Self.transcript, model: nil, style: .transcript)
      XCTFail("全片失败必须抛错")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .responseRejected)
    }
  }
}

private actor TidyProfileStore: ProviderProfileStore {
  private var value: ProviderProfile?
  func load() async throws -> ProviderProfile? { value }
  func save(_ profile: ProviderProfile) async throws { value = profile }
  func delete() async throws { value = nil }
}

private actor TidySecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  func save(_ secret: String, for reference: SecretReference) async throws { values[reference] = secret }
  func read(_ reference: SecretReference) async throws -> String? { values[reference] }
  func contains(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
  func delete(_ reference: SecretReference) async throws { values.removeValue(forKey: reference) }
}

/// 取凭据失败时说的是哪句话。
///
/// 「没配模型」和「这次读不出凭据」原来共用同一句「请先在设置中保存文本模型」。
/// 实测点一次校对失败、跑去设置里检查，配置完好无损——人被指向了一个没问题的
/// 地方。两者的用户动作是相反的：一个要去填配置，另一个只需重试。
final class TidyCredentialFailureTests: XCTestCase {
  private func service(
    profile: ProviderProfile?,
    secretStore: any SecretStore
  ) async throws -> ProviderConfigurationService {
    let profileStore = TidyProfileStore()
    if let profile { try await profileStore.save(profile) }
    return ProviderConfigurationService(profileStore: profileStore, secretStore: secretStore)
  }

  private func fixtureProfile(_ reference: SecretReference) throws -> ProviderProfile {
    try ProviderProfile(
      baseURL: "http://127.0.0.1:9/v1",
      model: "fixture-model",
      secretReference: reference,
      allowLoopbackHTTP: true
    )
  }

  /// 真的没有 profile：这时「去设置里配」才是对的指引。
  func testMissingProfileStillReportsModelNotConfigured() async throws {
    let service = try await service(profile: nil, secretStore: TidySecretStore())
    do {
      _ = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: service)
      XCTFail("没有 profile 时不该拿到凭据")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .modelNotConfigured)
    }
  }

  /// 钥匙串读失败：配置好好的，不能说人家没配。
  func testSecretReadFailureIsNotReportedAsMissingConfiguration() async throws {
    let reference = SecretReference(rawValue: "cred-fail-reference")
    let store = FlakySecretStore(failures: [.failure], value: "sk-test")
    let service = try await service(profile: try fixtureProfile(reference), secretStore: store)
    do {
      _ = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: service)
      XCTFail("读不出密钥时不该拿到凭据")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .credentialsUnavailable)
      XCTAssertNotEqual(error, .modelNotConfigured, "配置没问题，别把人指去设置页")
      XCTAssertTrue(error.userMessage.contains("重试"))
    }
  }

  /// 首读超时自动重试一次就能过。
  ///
  /// 钥匙串首读慢是**一次性**的：App 重新签名后系统要重新评估一次代码签名，
  /// 之后有缓存就快了。不自动重试的话，每次部署新版本后第一次用校对都会失败。
  func testTimeoutRetriesOnceAndSucceeds() async throws {
    let reference = SecretReference(rawValue: "cred-timeout-reference")
    let store = FlakySecretStore(failures: [.timeout], value: "sk-test")
    let service = try await service(profile: try fixtureProfile(reference), secretStore: store)
    let credentials = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: service)
    XCTAssertEqual(credentials.apiKey, "sk-test")
    let reads = await store.readCount
    XCTAssertEqual(reads, 2, "首次超时后应自动重试一次")
  }

  /// 但只重试一次：连着超时说明不是那个一次性延迟，再转就是干等。
  func testRepeatedTimeoutsStopAfterOneRetry() async throws {
    let reference = SecretReference(rawValue: "cred-timeout-twice")
    let store = FlakySecretStore(failures: [.timeout, .timeout], value: "sk-test")
    let service = try await service(profile: try fixtureProfile(reference), secretStore: store)
    do {
      _ = try await OpenAICompatibleTranscriptTidier.loadCredentials(from: service)
      XCTFail("连续超时不该成功")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .credentialsUnavailable)
    }
    let reads = await store.readCount
    XCTAssertEqual(reads, 2, "只重试一次，不该无限转")
  }
}

/// 前 N 次读按脚本失败，之后正常返回。
private actor FlakySecretStore: SecretStore {
  enum Failure { case timeout, failure }

  private var remaining: [Failure]
  private let value: String
  private(set) var readCount = 0

  init(failures: [Failure], value: String) {
    self.remaining = failures
    self.value = value
  }

  func save(_ secret: String, for reference: SecretReference) async throws {}
  func contains(_ reference: SecretReference) async throws -> Bool { true }
  func delete(_ reference: SecretReference) async throws {}

  func read(_ reference: SecretReference) async throws -> String? {
    readCount += 1
    guard !remaining.isEmpty else { return value }
    let next = remaining.removeFirst()
    switch next {
    // isTimeout 由 status 推导，超时用的就是这个专门的码。
    case .timeout: throw SecretStoreFailure(operation: .read, status: SecretStoreFailure.timeoutStatus)
    case .failure: throw SecretStoreFailure(operation: .read, status: -25300)
    }
  }
}
