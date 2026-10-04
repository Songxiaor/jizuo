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
///
/// 这里的并发、补跑、错配机制用字幕校对来钉（2026-10-04 起，听写稿首段时间码丢失会在本机补回，
/// 「回了别的段」这类错配用字幕稿更好构造）。
final class TranscriptTidierParallelTests: XCTestCase {
  /// 三段各 ~5900 字的转写稿：chunker 上限 6000，恰好一段一片。
  private static let paragraphs = [
    String(repeating: "甲", count: 5_900),
    String(repeating: "乙", count: 5_900),
    String(repeating: "丙", count: 5_900),
  ]
  private static var transcript: String { paragraphs.joined(separator: "\n\n") }

  override func setUp() {
    super.setUp()
    // 失败段补跑之间的等待在测试里归零，不白等几秒；诊断日志不写到真实目录。
    OpenAICompatibleTranscriptTidier.chunkRetryBaseDelaySeconds = 0
    OpenAICompatibleTranscriptTidier.diagnosticsLogURL = nil
  }

  override func tearDown() {
    OpenAICompatibleTranscriptTidier.chunkRetryBaseDelaySeconds = 3
    super.tearDown()
  }

  /// 校对稿和原段字数相当（整理器会核对字数，差太多当成错配）。
  private static let tidiedText = String(repeating: "整", count: 5_900)
  private static let tidiedJSON = #"{"choices":[{"message":{"content":""# + tidiedText
    + #""}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
  /// 字数只有原段零头：像是回了别的东西，必须当失败。
  private static let mismatchedJSON = #"""
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
    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)
    let elapsed = clock.now - started

    XCTAssertEqual(server.attemptCount, 3)
    XCTAssertLessThan(elapsed, .seconds(2), "三片各延迟 0.8s，串行 ≥2.4s——超过 2s 说明退回了串行")
    XCTAssertEqual(outcome.text, [Self.tidiedText, Self.tidiedText, Self.tidiedText].joined(separator: "\n\n"))
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

    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)

    XCTAssertEqual(outcome.failedChunkCount, 1)
    XCTAssertEqual(outcome.chunkCount, 3)
    let parts = outcome.text.components(separatedBy: "\n\n")
    XCTAssertEqual(parts.count, 3)
    var originalsKept = 0
    for (index, part) in parts.enumerated() {
      if part == Self.tidiedText { continue }
      XCTAssertEqual(part, Self.paragraphs[index], "失败片的原文必须留在它自己的位置")
      originalsKept += 1
    }
    XCTAssertEqual(originalsKept, 1)
  }

  /// 一段偶发失败（限流、超时）：并发跑完后单独补跑，补跑成功就不算失败。
  func testFailedChunkIsRetriedAndRecovers() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(
      contentType: "application/json",
      chunks: [.init(Self.tidiedJSON)]
    )
    // 第三个到达的请求 500，之后（也就是补跑）成功。
    let server = FakeOpenAICompatibleServer(
      expectedAPIKey: key,
      scripts: [success, success, .init(statusCode: 500), success]
    )
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)

    XCTAssertEqual(outcome.failedChunkCount, 0)
    XCTAssertNil(outcome.failureReason)
    XCTAssertEqual(outcome.text, [Self.tidiedText, Self.tidiedText, Self.tidiedText].joined(separator: "\n\n"))
    XCTAssertEqual(server.attemptCount, 4)
  }

  /// 补跑也失败时，说出原因，而且只补跑规定的次数。
  func testChunkThatKeepsFailingReportsWhyAfterBoundedRetries() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(
      contentType: "application/json",
      chunks: [.init(Self.tidiedJSON)]
    )
    let server = FakeOpenAICompatibleServer(
      expectedAPIKey: key,
      scripts: [success, success, .init(statusCode: 429)]
    )
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)

    XCTAssertEqual(outcome.failedChunkCount, 1)
    XCTAssertEqual(outcome.failureReason, "服务繁忙被限流")
    XCTAssertEqual(server.attemptCount, 3 + OpenAICompatibleTranscriptTidier.chunkRetryAttempts)
  }

  /// 回的不是这一段（字数、时间戳对不上）：当失败、保留原文、说明原因，绝不放进稿子。
  func testMismatchedReplyIsRejectedAndOriginalKept() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(contentType: "application/json", chunks: [.init(Self.tidiedJSON)])
    let mismatch = FakeOpenAICompatibleServer.ResponseScript(contentType: "application/json", chunks: [.init(Self.mismatchedJSON)])
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [success, success, mismatch])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)

    XCTAssertEqual(outcome.failedChunkCount, 1)
    XCTAssertEqual(outcome.failureReason, "模型返回的内容和这一段对不上")
    XCTAssertFalse(outcome.text.contains("已整理。"))
    XCTAssertEqual(outcome.text.components(separatedBy: "\n\n").filter { Self.paragraphs.contains($0) }.count, 1)
  }

  /// 真实形状：带时间戳的长稿切成多段，完成顺序和段序相反，每段回显自己收到的内容。
  /// 拼出来必须和原稿段落顺序一致（2026-09-28 实测第 1 段位置出现了最后一段的内容）。
  func testEchoedChunksReassembleInOriginalOrderWhenCompletionOrderIsReversed() async throws {
    let paragraphs = (0..<50).map { index in
      String(format: "%02d:%02d ", index / 2, (index % 2) * 30) + String(repeating: "字", count: 200) + "第\(index)段"
    }
    let transcript = paragraphs.joined(separator: "\n\n")
    let key = "sentinel-\(UUID().uuidString)"
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: []) { body in
      let data = Data(body.utf8)
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let messages = object?["messages"] as? [[String: Any]] ?? []
      let chunk = messages.last?["content"] as? String ?? ""
      // 越靠前的段回得越慢：完成顺序和段序相反。
      let first = TranscriptTidyChunkCheck.timestamps(in: chunk).first ?? "00:00"
      let minutes = Double(first.prefix(2)) ?? 0
      let delay = max(0, 0.6 - minutes * 0.03)
      let reply = try? JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": chunk]]],
        "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2],
      ])
      return .init(contentType: "application/json", chunks: [.init(String(decoding: reply ?? Data(), as: UTF8.self), delay: delay)])
    }
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)

    let outcome = try await tidier.tidy(text: transcript, model: nil, style: .subtitles)

    XCTAssertGreaterThan(outcome.chunkCount, 3)
    XCTAssertEqual(outcome.failedChunkCount, 0)
    XCTAssertEqual(outcome.text.components(separatedBy: "\n\n"), paragraphs)
  }

  /// 进度只数成功段，限流段收尾补跑时报「正在补跑第 k 段（共 m 段）」（2026-10-01 体检）。
  ///
  /// 原来失败段也算「已完成」，界面停在「已校对 3/3 段」，背后补跑还要十几分钟。
  func testProgressCountsOnlySuccessesAndReportsRetryPhase() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(contentType: "application/json", chunks: [.init(Self.tidiedJSON)])
    let server = FakeOpenAICompatibleServer(
      expectedAPIKey: key,
      scripts: [success, success, .init(statusCode: 429), success]
    )
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)
    let phases = PhaseRecorder()

    let outcome = try await tidier.tidy(
      text: Self.transcript, model: nil, style: .subtitles, context: .empty,
      phase: { phases.append($0) }
    )

    XCTAssertEqual(outcome.failedChunkCount, 0)
    let recorded = phases.values
    let tidyingCounts = recorded.compactMap { phase -> Int? in
      if case let .tidying(succeeded, _) = phase { return succeeded }
      return nil
    }
    XCTAssertFalse(tidyingCounts.prefix(3).contains(3), "并发那一波只有 2 段成功，不能报 3/3：\(recorded)")
    XCTAssertTrue(recorded.contains(.retrying(attempt: 1, failed: 1, total: 3)), "补跑时要报阶段：\(recorded)")
    XCTAssertEqual(recorded.last, .tidying(succeeded: 3, total: 3), "补跑成功后回到 3/3")
  }

  /// 网络中断这类失败在并发池里就补跑，不等整轮跑完（2026-10-04）。
  ///
  /// 原来所有失败段都等整轮结束后串行补：Day2 实测网关成批掐断 12 段，
  /// 串行补跑一段约 60 秒，收尾多等了 13 分钟。这里第 1 段首发 500，
  /// 它的补跑必须在最后几段首发之前就到达服务器。
  func testTransientFailureIsRetriedInsideThePoolBeforeLaterChunks() async throws {
    let paragraphs = (0..<30).map { index in
      String(format: "%02d:%02d ", index / 2, (index % 2) * 30) + String(repeating: "字", count: 400) + "第\(index)段"
    }
    let transcript = paragraphs.joined(separator: "\n\n")
    let key = "sentinel-\(UUID().uuidString)"
    let arrivals = ArrivalLog()
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: []) { body in
      let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
      let messages = object?["messages"] as? [[String: Any]] ?? []
      let chunk = messages.last?["content"] as? String ?? ""
      let first = TranscriptTidyChunkCheck.timestamps(in: chunk).first ?? "-"
      if arrivals.record(first) == 0, first == "00:00" {
        return .init(statusCode: 500)
      }
      let reply = try? JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["content": chunk]]],
        "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2],
      ])
      return .init(contentType: "application/json", chunks: [.init(String(decoding: reply ?? Data(), as: UTF8.self), delay: 0.05)])
    }
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)
    let phases = PhaseRecorder()

    let outcome = try await tidier.tidy(
      text: transcript, model: nil, style: .subtitles, context: .empty,
      phase: { phases.append($0) }
    )

    XCTAssertGreaterThan(outcome.chunkCount, 4)
    XCTAssertEqual(outcome.failedChunkCount, 0)
    XCTAssertEqual(outcome.text.components(separatedBy: "\n\n"), paragraphs)
    let order = arrivals.values
    let firstChunkArrivals = order.indices.filter { order[$0] == "00:00" }
    XCTAssertEqual(firstChunkArrivals.count, 2, "第 1 段首发失败、补跑一次")
    XCTAssertLessThan(firstChunkArrivals.last ?? .max, order.count - 3, "补跑要在池里进行，不排到所有段之后：\(order)")
    XCTAssertFalse(
      phases.values.contains { if case .retrying = $0 { true } else { false } },
      "池内补跑不进入收尾补跑阶段"
    )
  }

  /// 老的两数进度接口也只数成功段，补跑阶段不混进来。
  func testLegacyProgressNeverReportsFailedChunksAsDone() async throws {
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(contentType: "application/json", chunks: [.init(Self.tidiedJSON)])
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [success, success, .init(statusCode: 401)])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)
    let reports = PhaseRecorder()

    let outcome = try await tidier.tidy(
      text: Self.transcript, model: nil, style: .subtitles, context: .empty,
      progress: { done, total in reports.append(.tidying(succeeded: done, total: total)) }
    )

    XCTAssertEqual(outcome.failedChunkCount, 1)
    XCTAssertEqual(reports.values.last, .tidying(succeeded: 2, total: 3))
  }

  /// 补跑期间取消：立刻停下、抛「已取消」，不再发补跑请求。
  func testCancellationDuringRetryStopsWithoutFurtherRequests() async throws {
    // 补跑前要等 5 秒：取消必须打断这段等待。
    OpenAICompatibleTranscriptTidier.chunkRetryBaseDelaySeconds = 5
    let key = "sentinel-\(UUID().uuidString)"
    let success = FakeOpenAICompatibleServer.ResponseScript(contentType: "application/json", chunks: [.init(Self.tidiedJSON)])
    let server = FakeOpenAICompatibleServer(expectedAPIKey: key, scripts: [success, success, .init(statusCode: 429), success])
    let baseURL = try server.start()
    defer { server.stop() }
    let tidier = try await makeTidier(baseURL: baseURL, apiKey: key)
    let phases = PhaseRecorder()

    let work = Task {
      try await tidier.tidy(
        text: Self.transcript, model: nil, style: .subtitles, context: .empty,
        phase: { phases.append($0) }
      )
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while !phases.values.contains(where: { if case .retrying = $0 { true } else { false } }) {
      guard ContinuousClock.now < deadline else { return XCTFail("没有进入补跑阶段") }
      try await Task.sleep(for: .milliseconds(20))
    }
    let started = ContinuousClock.now
    work.cancel()
    do {
      _ = try await work.value
      XCTFail("取消后不该拿到结果")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .cancelled)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "取消要打断补跑前的等待")
    XCTAssertEqual(server.attemptCount, 3, "取消后不该再发补跑请求")
  }

  /// 估时：⌈段数 ÷ 并发⌉ 波 × 50 秒。
  func testEstimatedDurationScalesWithChunkWaves() {
    XCTAssertEqual(OpenAICompatibleTranscriptTidier.estimatedSeconds(chunkCount: 0), 0)
    XCTAssertEqual(OpenAICompatibleTranscriptTidier.estimatedSeconds(chunkCount: 1), 50)
    XCTAssertEqual(OpenAICompatibleTranscriptTidier.estimatedSeconds(chunkCount: 3), 50)
    XCTAssertEqual(OpenAICompatibleTranscriptTidier.estimatedSeconds(chunkCount: 7), 150)
    // 用和执行同一份切法：3 段各 5900 字的稿子，估出来就是这几段的波数。
    let chunks = OpenAICompatibleTranscriptTidier.chunks(for: Self.transcript, style: .subtitles).count
    XCTAssertEqual(
      OpenAICompatibleTranscriptTidier.estimatedSeconds(forText: Self.transcript, style: .subtitles),
      OpenAICompatibleTranscriptTidier.estimatedSeconds(chunkCount: chunks)
    )
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
      _ = try await tidier.tidy(text: Self.transcript, model: nil, style: .subtitles)
      XCTFail("全片失败必须抛错")
    } catch let error as TranscriptTidyError {
      XCTAssertEqual(error, .responseRejected)
    }
  }
}

private final class PhaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [TranscriptTidyPhase] = []
  func append(_ phase: TranscriptTidyPhase) { lock.withLock { stored.append(phase) } }
  var values: [TranscriptTidyPhase] { lock.withLock { stored } }
}

/// 按到达顺序记下每个请求的首个时间戳；返回这个时间戳此前到过几次。
private final class ArrivalLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  func record(_ stamp: String) -> Int {
    lock.withLock {
      let earlier = stored.filter { $0 == stamp }.count
      stored.append(stamp)
      return earlier
    }
  }
  var values: [String] { lock.withLock { stored } }
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
