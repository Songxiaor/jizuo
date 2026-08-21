import Foundation
import LinkDigestCore

public protocol RetrySleeper: Sendable {
  func sleep(for seconds: TimeInterval) async throws
}

public struct TaskRetrySleeper: RetrySleeper {
  public init() {}

  public func sleep(for seconds: TimeInterval) async throws {
    guard seconds > 0 else { return }
    try await Task.sleep(for: .seconds(seconds))
  }
}

public enum OpenAICompatibleEndpoint {
  public static func chatCompletionsURL(baseURL: URL) throws -> URL {
    try endpointURL(baseURL: baseURL, suffix: "/chat/completions", rejectingCompletedChatEndpoint: true)
  }

  public static func modelsURL(baseURL: URL) throws -> URL {
    try endpointURL(baseURL: baseURL, suffix: "/models", rejectingCompletedChatEndpoint: false)
  }

  public static func audioTranscriptionsURL(baseURL: URL) throws -> URL {
    try endpointURL(baseURL: baseURL, suffix: "/audio/transcriptions", rejectingCompletedChatEndpoint: false)
  }

  private static func endpointURL(
    baseURL: URL,
    suffix: String,
    rejectingCompletedChatEndpoint: Bool
  ) throws -> URL {
    let normalizedPath = baseURL.path.split(separator: "/").map(String.init)
    if rejectingCompletedChatEndpoint, normalizedPath.suffix(2) == ["chat", "completions"] {
      throw ModelProviderFailure(
        code: .baseURLInvalid,
        retryable: false,
        hadOutput: false
      )
    }

    guard
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw ModelProviderFailure(
        code: .baseURLInvalid,
        retryable: false,
        hadOutput: false
      )
    }

    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    if path == "/" { path = "" }
    components.percentEncodedPath = path + suffix

    guard let url = components.url else {
      throw ModelProviderFailure(
        code: .baseURLInvalid,
        retryable: false,
        hadOutput: false
      )
    }
    return url
  }
}

public final class OpenAICompatibleProvider: ModelProvider, ModelCatalogLoading, SummaryTagGenerating, @unchecked Sendable {
  public static let modelCatalogByteLimit = 1_024 * 1_024
  public static let modelCatalogLimit = 500
  public static let automaticTagResponseByteLimit = 64 * 1_024
  public static let automaticTagMaximumTokens = 64
  private let session: URLSession
  private let sleeper: any RetrySleeper
  private let maximumRetryCount: Int
  private let defaultBackoff: TimeInterval
  private let activeTaskLock = NSLock()
  private var activeStreamTasks: [UUID: Task<Void, Never>] = [:]
  private var streamsFinishedBeforeRegistration: Set<UUID> = []
  /// 已经明确拒绝过 `reasoning_effort` 的目的地，按 (baseURL, model) 记。
  ///
  /// 降级本身是每次请求各自完成的，但**记忆必须跨请求**：长文翻译会把正文切成
  /// 多片、每片各发一次请求，如果每片都重新试一遍这个参数，一个不接受它的服务商
  /// 会让 9 片变成 9 次「被拒」+ 9 次「重发」——一半请求纯属浪费，而且每次浪费
  /// 都要等一个完整的 HTTP 往返。
  ///
  /// 按目的地记而不是全局记：换了服务商或模型就该重新试一次，否则一次偶发的拒绝
  /// 会让后面所有目的地都永久失去这个提速。
  private let reasoningEffortLock = NSLock()
  private var reasoningEffortRejectedDestinations: Set<String> = []
  /// 这个目的地已经拒绝过 `none`。思考卡住时不能再拿 `none` 重试，否则死循环。
  private var reasoningNoneRejectedDestinations: Set<String> = []
  /// 这个目的地用 `low` 仍会先想很久。下次直接从 `none` 起。
  private var reasoningStallDestinations: Set<String> = []

  /// 只出思考、不出正文超过这个时间，就改用不思考再打一次。
  /// 测试可改小；产品路径 8 秒——正常首字中位约 5 秒，超过即明确在想。
  var thinkingStallRetryThreshold: TimeInterval = 8
  /// 测试用来指定第一档推理力度；产品路径为 nil。
  var testingPreferredReasoningEffort: StreamReasoningEffort?

  public init(
    session: URLSession = .shared,
    sleeper: any RetrySleeper = TaskRetrySleeper(),
    maximumRetryCount: Int = 2,
    defaultBackoff: TimeInterval = 1
  ) {
    self.session = session
    self.sleeper = sleeper
    self.maximumRetryCount = max(0, maximumRetryCount)
    self.defaultBackoff = max(0, defaultBackoff)
  }

  public func stream(
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent
  ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let streamID = UUID()
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish(throwing: CancellationError())
          return
        }
        defer { self.finishTrackingStream(streamID) }
        do {
          try await self.perform(
            profile: profile,
            apiKey: apiKey,
            intent: intent,
            continuation: continuation
          )
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let failure as ModelProviderFailure {
          continuation.finish(throwing: failure)
        } catch {
          continuation.finish(throwing: ModelProviderFailure(
            code: .networkInterrupted,
            retryable: true,
            hadOutput: false
          ))
        }
      }
      trackStream(task, id: streamID)

      continuation.onTermination = { @Sendable [weak self] _ in
        self?.cancelStream(id: streamID)
      }
    }
  }

  /// 拼 `Authorization` 头之前清洗密钥。
  ///
  /// 粘贴进来的 Key 很容易尾随一个换行或空格。此前判空用了 `trimmingCharacters`，
  /// 拼头却直接用原串——两处标准不一致：判空说「这 Key 有效」，发出去的头却是
  /// `Bearer sk-xxx\n`，服务端只会回 401。更糟的是 `setValue` 遇到带换行的值会
  /// 直接丢掉整个头，那时请求根本没带鉴权。
  ///
  /// 清洗只去首尾空白，不改中间任何字符。
  private func sanitizedKey(_ apiKey: String) -> String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func cancelActiveStreams() {
    let tasks = activeTaskLock.withLock {
      Array(activeStreamTasks.values)
    }
    tasks.forEach { $0.cancel() }
  }

  var activeStreamCount: Int {
    activeTaskLock.withLock { activeStreamTasks.count }
  }

  public func listModels(baseURL: URL, apiKey: String) async throws -> [String] {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    }
    let validatedBaseURL: URL
    do {
      validatedBaseURL = try ProviderProfile.validatedBaseURL(
        baseURL.absoluteString,
        allowLoopbackHTTP: baseURL.scheme?.lowercased() == "http" && baseURL.host == "127.0.0.1"
      )
    } catch {
      throw ModelProviderFailure(code: .baseURLInvalid, retryable: false, hadOutput: false)
    }
    let url = try OpenAICompatibleEndpoint.modelsURL(baseURL: validatedBaseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(sanitizedKey(apiKey))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let redirectGuard = CatalogRedirectGuard(origin: url)
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
      guard let http = response as? HTTPURLResponse,
            let finalURL = response.url,
            redirectGuard.acceptedFinalURL(finalURL),
            (200..<300).contains(http.statusCode)
      else {
        throw catalogFailure(response: response)
      }
      guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
        throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
      }
      var data = Data()
      for try await byte in bytes {
        guard data.count < Self.modelCatalogByteLimit else {
          throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: false)
        }
        data.append(byte)
      }
      guard let responseBody = try? JSONDecoder().decode(ModelCatalogResponse.self, from: data) else {
        throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
      }
      guard responseBody.data.count <= Self.modelCatalogLimit else {
        throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: false)
      }
      var unique = Set<String>()
      for entry in responseBody.data {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { continue }
        unique.insert(id)
      }
      guard !unique.isEmpty else {
        throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
      }
      return unique.sorted()
    } catch let failure as ModelProviderFailure {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      throw CancellationError()
    } catch {
      throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    }
  }

  public static let transcriptTidyResponseByteLimit = 4 * 1_024 * 1_024

  /// One tidy pass over one transcript chunk. Non-streaming on purpose: the
  /// result replaces nothing until it is complete and persisted.
  public func tidyTranscriptChunk(
    profile: ProviderProfile,
    apiKey: String,
    model: String,
    text: String,
    systemPrompt: String = TranscriptTidyPrompt.system
  ) async throws -> TranscriptTidyOutcome {
    let completion = try await nonStreamingChatCompletion(
      profile: profile, apiKey: apiKey, model: model,
      systemPrompt: systemPrompt, userContent: text
    )
    return TranscriptTidyOutcome(
      text: completion.content,
      promptTokens: completion.promptTokens,
      completionTokens: completion.completionTokens,
      totalTokens: completion.totalTokens
    )
  }

  /// Extracts a mind-map outline as raw model text (JSON per the fixed
  /// contract); the Core parser owns validation and clamping.
  public func extractMindMapOutline(
    profile: ProviderProfile,
    apiKey: String,
    model: String,
    text: String
  ) async throws -> (content: String, promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
    let completion = try await nonStreamingChatCompletion(
      profile: profile, apiKey: apiKey, model: model,
      systemPrompt: MindMapPrompt.system, userContent: text
    )
    return (completion.content, completion.promptTokens, completion.completionTokens, completion.totalTokens)
  }

  private struct NonStreamingChatResult {
    let content: String
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
  }

  private func nonStreamingChatCompletion(
    profile: ProviderProfile,
    apiKey: String,
    model: String,
    systemPrompt: String,
    userContent: String
  ) async throws -> NonStreamingChatResult {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    }
    guard profile.apiMode == .chatCompletions else {
      throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }
    let url = try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: profile.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("Bearer \(sanitizedKey(apiKey))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(RequestBody(
      model: model,
      messages: [
        Message(role: "system", content: systemPrompt),
        Message(role: "user", content: userContent),
      ],
      stream: false,
      maxTokens: nil
    ))

    do {
      let (bytes, response) = try await session.bytes(for: request)
      var body = Data()
      for try await byte in bytes {
        guard body.count < Self.transcriptTidyResponseByteLimit else {
          throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: false)
        }
        body.append(byte)
      }
      let providerError = ProviderErrorBody(data: body)
      _ = try validateStatus(response: response, providerError: providerError, hadOutput: false)
      guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
        throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
      }
      let decoded = try? JSONDecoder().decode(NonStreamingCompletionResponse.self, from: body)
      return NonStreamingChatResult(
        content: decoded?.choices.first?.message.content ?? "",
        promptTokens: decoded?.usage?.promptTokens,
        completionTokens: decoded?.usage?.completionTokens,
        totalTokens: decoded?.usage?.totalTokens
      )
    } catch let failure as ModelProviderFailure {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      throw CancellationError()
    } catch {
      throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    }
  }

  public func generateSummaryTags(profile: ProviderProfile, apiKey: String, summary: String) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    }
    guard profile.apiMode == .chatCompletions else {
      throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }
    let url = try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: profile.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("Bearer \(sanitizedKey(apiKey))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(RequestBody(
      model: profile.model,
      messages: [
        Message(role: "system", content: "为以下摘要输出 1-5 个中文主题标签，逗号分隔，不要输出其他内容。标签必须是可用于归类多篇文章的领域名或实体名（如：AI 工具、折叠屏、Claude Code），严禁输出文中章节标题或“概述/建议/要点”这类结构词。"),
        Message(role: "user", content: summary),
      ],
      stream: false,
      maxTokens: Self.automaticTagMaximumTokens
    ))

    do {
      let (bytes, response) = try await session.bytes(for: request)
      var body = Data()
      for try await byte in bytes {
        guard body.count < Self.automaticTagResponseByteLimit else {
          throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: false)
        }
        body.append(byte)
      }
      let providerError = ProviderErrorBody(data: body)
      _ = try validateStatus(response: response, providerError: providerError, hadOutput: false)
      guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
        throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
      }
      return (try? JSONDecoder().decode(NonStreamingCompletionResponse.self, from: body))?
        .choices.first?.message.content ?? ""
    } catch let failure as ModelProviderFailure {
      throw failure
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      throw CancellationError()
    } catch {
      throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
    }
  }

  private func trackStream(_ task: Task<Void, Never>, id: UUID) {
    activeTaskLock.withLock {
      if streamsFinishedBeforeRegistration.remove(id) == nil {
        activeStreamTasks[id] = task
      }
    }
  }

  private func finishTrackingStream(_ id: UUID) {
    activeTaskLock.withLock {
      if activeStreamTasks.removeValue(forKey: id) == nil {
        streamsFinishedBeforeRegistration.insert(id)
      }
    }
  }

  private func cancelStream(id: UUID) {
    let task = activeTaskLock.withLock {
      activeStreamTasks[id]
    }
    task?.cancel()
  }

  private func perform(
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent,
    continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
  ) async throws {
    // 总结/翻译要转述，不要推理。优先发 `none`；不认识就降到 `low`，再不行去掉。
    // 目的地此前拒绝过的话，按记住的档位起，不必每片重新试。
    var effort = preferredReasoningEffort(profile)
    var request = try makeRequest(
      profile: profile, apiKey: apiKey, intent: intent,
      reasoningEffort: effort
    )
    var retryCount = 0
    var didRetryThinkingStall = false

    // 首字来得太慢时留一行分段耗时。见 `ProviderTimingLog`。
    let intentLabel: String = switch intent {
    case .connectionTest: "connectionTest"
    case .summarize: "summarize"
    case .translate: "translate"
    }
    let inflight = activeStreamCount

    while true {
      try Task.checkCancellation()
      var receivedDelta = false
      var currentResponse: HTTPURLResponse?

      do {
        let t0 = Date()
        let (bytes, response) = try await session.bytes(for: request)
        let headersAt = Date()
        currentResponse = response as? HTTPURLResponse
        let providerError = try await providerError(from: bytes, response: response)
        _ = try validate(response: response, providerError: providerError, hadOutput: false)

        let watch = FirstDeltaWatch()
        let effortLabel = effort.logLabel
        let attemptRetryCount = retryCount
        let stallThreshold = thinkingStallRetryThreshold
        let stallAllowed = effort != .none && canRetryThinkingStall(profile)
        // 读流必须留在当前任务里。把 `bytes.lines` 丢进 TaskGroup 再取消，
        // URLSession 内部缓冲会踩到越界（测试里是 ContiguousArrayBuffer）。
        // 卡住时只取消这一次 URLSessionTask，读循环按网络中断退出，再改 `none` 重打。
        let sessionTask = bytes.task
        let stallWatchdog = Task {
          guard stallAllowed else { return }
          do {
            while !watch.hasDelta {
              try await Task.sleep(for: .milliseconds(200))
              try Task.checkCancellation()
              if Date().timeIntervalSince(t0) >= stallThreshold, watch.sawReasoningOnly {
                sessionTask.cancel()
                return
              }
            }
          } catch {
            return
          }
        }
        defer { stallWatchdog.cancel() }

        do {
          var firstLineAt: Date?
          var lineCount = 0
          var reasoningCount = 0
          for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1
            if firstLineAt == nil { firstLineAt = Date() }
            guard let event = try ChatCompletionsStreamDecoder().decode(line: line) else {
              continue
            }
            switch event {
            case .delta:
              if !watch.hasDelta {
                let elapsed = Date().timeIntervalSince(t0)
                if elapsed >= ProviderTimingLog.slowFirstDeltaThreshold {
                  let connectMs = Int(headersAt.timeIntervalSince(t0) * 1000)
                  let openMs = firstLineAt.map { Int($0.timeIntervalSince(headersAt) * 1000) } ?? -1
                  ProviderTimingLog.write(
                    "SLOW_FIRST_DELTA intent=\(intentLabel) model=\(profile.model) "
                      + "host=\(profile.baseURL.host ?? "?") "
                      + "reasoningEffort=\(effortLabel) "
                      + "inflightStreams=\(inflight) retry=\(attemptRetryCount) "
                      + "totalMs=\(Int(elapsed * 1000)) connectMs=\(connectMs) openMs=\(openMs) "
                      + "sseLines=\(lineCount) reasoningEvents=\(reasoningCount)"
                  )
                }
              }
              watch.markDelta()
              continuation.yield(event)
            case .reasoning:
              reasoningCount += 1
              watch.markReasoning()
              continuation.yield(event)
            case .usage:
              continuation.yield(event)
            case .completed:
              continuation.yield(.completed)
              continuation.finish()
              return
            }
          }
          receivedDelta = watch.hasDelta
          throw ModelProviderFailure(
            code: .networkInterrupted,
            retryable: true,
            hadOutput: receivedDelta
          )
        } catch is ThinkingStallRetry {
          throw ThinkingStallRetry()
        } catch is CancellationError {
          receivedDelta = watch.hasDelta
          if !Task.isCancelled, stallAllowed, watch.sawReasoningOnly, !watch.hasDelta {
            throw ThinkingStallRetry()
          }
          throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
          receivedDelta = watch.hasDelta
          if !Task.isCancelled, stallAllowed, watch.sawReasoningOnly, !watch.hasDelta {
            throw ThinkingStallRetry()
          }
          throw error
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch is ThinkingStallRetry {
        guard !didRetryThinkingStall, !receivedDelta, canRetryThinkingStall(profile) else {
          throw ModelProviderFailure(code: .networkInterrupted, retryable: true, hadOutput: false)
        }
        didRetryThinkingStall = true
        rememberThinkingStall(profile)
        effort = .none
        request = try makeRequest(
          profile: profile, apiKey: apiKey, intent: intent,
          reasoningEffort: effort
        )
        continue
      } catch let failure as ModelProviderFailure {
        // 服务端在还没吐出任何内容时就拒了请求，且我们确实多发了那个键——先怀疑
        // 是它不被接受，降一档重来。只沿梯子走，避免和下面的重试互相叠加。
        if let next = effort.steppedDown(), !failure.hadOutput,
           Self.mayRejectUnknownParameter(failure) {
          rememberRejected(effort, for: profile)
          effort = next
          request = try makeRequest(
            profile: profile, apiKey: apiKey, intent: intent,
            reasoningEffort: effort
          )
          continue
        }
        if shouldRetry(failure: failure, retryCount: retryCount) {
          retryCount += 1
          let delay = retryDelay(from: currentResponse)
          try await sleeper.sleep(for: delay)
          continue
        }
        throw failure
      } catch let error as URLError {
        let failure = ModelProviderFailure(
          code: .networkInterrupted,
          retryable: true,
          hadOutput: receivedDelta
        )
        if shouldRetry(failure: failure, retryCount: retryCount) {
          retryCount += 1
          try await sleeper.sleep(for: defaultBackoff)
          continue
        }
        if error.code == .cancelled, Task.isCancelled {
          throw CancellationError()
        }
        throw failure
      } catch {
        throw ModelProviderFailure(
          code: .networkInterrupted,
          retryable: true,
          hadOutput: receivedDelta
        )
      }

    }
  }

  private func makeRequest(
    profile: ProviderProfile,
    apiKey: String,
    intent: RunIntent,
    reasoningEffort: StreamReasoningEffort = .none
  ) throws -> URLRequest {
    // 仪表：只记长度和模型名，绝不记 Key 本身。
    //
    // `MODEL_AUTH_INVALID` 有两个来源：服务端返 401，和下面这条「取到的 Key 是
    // 空串」——后者一个请求都不发。界面上两者显示同一句「请更新 API Key」，
    // 于是「换了 Key 还是不行」时根本分不清该查哪头。
    guard !apiKey.isEmpty else {
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    }
    guard profile.apiMode == .chatCompletions else {
      throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }

    let url = try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: profile.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(sanitizedKey(apiKey))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let messages: [Message]
    switch intent {
    case .connectionTest:
      messages = [Message(role: "user", content: "Reply with OK.")]
    case let .summarize(title, text, prompt):
      messages = [
        Message(
          role: "system",
          content: prompt
        ),
        Message(role: "user", content: capturedContent(title: title, text: text))
      ]
    case let .translate(title, text, targetLanguage):
      let titleInstruction = title.map {
        "The source title is: \($0). Put the translated title first as a Markdown heading, then the translated body."
      } ?? ""
      messages = [
        Message(
          role: "system",
          content: """
          Translate the captured webpage content into \(targetLanguage). Do not add commentary or facts that are not present in the captured content.
          \(titleInstruction)

          Output only the translated title and body. Do not output labels such as Captured title, Captured content, <<<, >>>, or any translation of those labels (including 捕获的标题 and 捕获的内容).

          The finished translation must be entirely in \(targetLanguage). This is one-way into \(targetLanguage), never a language swap:
          - If a sentence is already in \(targetLanguage), copy it unchanged.
          - If a sentence is in any other language, translate it into \(targetLanguage).
          - Never translate \(targetLanguage) into English or any other language.

          Preserve meaning, structure, names, numbers, and links. Preserve Markdown syntax and indentation exactly. LinkDigest comment sections use structural metadata that must remain machine-readable:
          - Copy unchanged every section heading beginning with `## 评论（` or `## 评论与回复（`.
          - Copy unchanged every comment metadata line beginning with `- **`, including its leading indentation, username, score, timestamp, `回复层级`, and `[原评论](...)` link.
          - Translate only the prose body of each comment into \(targetLanguage). Never translate usernames or change comment nesting.
          """
        ),
        Message(role: "user", content: text)
      ]
    }
    request.httpBody = try JSONEncoder().encode(RequestBody(
      model: profile.model,
      messages: messages,
      stream: true,
      maxTokens: nil,
      reasoningEffort: reasoningEffort.jsonValue
    ))
    return request
  }

  private func capturedContent(title: String?, text: String) -> String {
    let titleLine = title.map { "Captured title:\n\($0)\n\n" } ?? ""
    return "\(titleLine)Captured content:\n<<<\n\(text)\n>>>"
  }

  private func validate(
    response: URLResponse,
    providerError: ProviderErrorBody?,
    hadOutput: Bool
  ) throws -> HTTPURLResponse {
    let response = try validateStatus(response: response, providerError: providerError, hadOutput: hadOutput)
    guard response.value(forHTTPHeaderField: "Content-Type")?
      .lowercased().hasPrefix("text/event-stream") == true else {
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: hadOutput
      )
    }
    return response
  }

  private func validateStatus(
    response: URLResponse,
    providerError: ProviderErrorBody?,
    hadOutput: Bool
  ) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: hadOutput)
    }

    switch response.statusCode {
    case 200..<300:
      break
    case 401, 403:
      // 服务端明说是余额/配额问题时以它为准：opencode Zen 余额不足返回的是 401，
      // 按状态码归类会把「去充值」说成「去换 Key」。
      if providerError?.indicatesBillingLimit == true {
        throw ModelProviderFailure(code: .providerBillingLimited, retryable: false, hadOutput: hadOutput)
      }
      throw ModelProviderFailure(
        code: response.statusCode == 401 ? .authInvalid : .authForbidden,
        retryable: false,
        hadOutput: hadOutput
      )
    case 404:
      throw ModelProviderFailure(
        code: providerError?.indicatesMissingModel == true ? .modelNotFound : .endpointNotFound,
        retryable: false,
        hadOutput: hadOutput
      )
    case 402:
      throw ModelProviderFailure(
        code: .providerBillingLimited,
        retryable: false,
        hadOutput: hadOutput
      )
    case 413:
      throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: hadOutput)
    case 429:
      throw ModelProviderFailure(code: .rateLimited, retryable: true, hadOutput: hadOutput)
    case 500...599:
      throw ModelProviderFailure(code: .providerUnavailable, retryable: true, hadOutput: hadOutput)
    case 400..<500:
      throw ModelProviderFailure(
        code: .providerRequestRejected,
        retryable: false,
        hadOutput: hadOutput
      )
    default:
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: hadOutput
      )
    }
    return response
  }

  private func providerError(
    from bytes: URLSession.AsyncBytes,
    response: URLResponse
  ) async throws -> ProviderErrorBody? {
    guard let response = response as? HTTPURLResponse,
          !(200..<300).contains(response.statusCode)
    else {
      return nil
    }

    var data = Data()
    let limit = 8_192
    for try await byte in bytes {
      guard data.count < limit else { break }
      data.append(byte)
    }

    // 所有非 2xx 都把正文交给分类器：404 用它区分「模型不存在」和「端点不存在」，
    // 401/403 用它区分「鉴权失败」和「余额不足」。
    return ProviderErrorBody(data: data)
  }

  private func shouldRetry(failure: ModelProviderFailure, retryCount: Int) -> Bool {
    failure.retryable
      && !failure.hadOutput
      && retryCount < maximumRetryCount
      && (failure.code == .rateLimited || failure.code == .providerUnavailable)
  }

  private func retryDelay(from response: HTTPURLResponse?) -> TimeInterval {
    guard
      let value = response?.value(forHTTPHeaderField: "Retry-After"),
      let seconds = TimeInterval(value)
    else {
      return defaultBackoff
    }
    return min(max(0, seconds), 10)
  }

  private func catalogFailure(response: URLResponse) -> ModelProviderFailure {
    guard let http = response as? HTTPURLResponse else {
      return .init(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }
    switch http.statusCode {
    case 401: return .init(code: .authInvalid, retryable: false, hadOutput: false)
    case 403: return .init(code: .authForbidden, retryable: false, hadOutput: false)
    case 404: return .init(code: .endpointNotFound, retryable: false, hadOutput: false)
    case 402: return .init(code: .providerBillingLimited, retryable: false, hadOutput: false)
    case 413: return .init(code: .inputTooLarge, retryable: false, hadOutput: false)
    case 429: return .init(code: .rateLimited, retryable: true, hadOutput: false)
    case 500...599: return .init(code: .providerUnavailable, retryable: true, hadOutput: false)
    case 400..<500: return .init(code: .providerRequestRejected, retryable: false, hadOutput: false)
    default: return .init(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }
  }

  private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let maxTokens: Int?
    /// 推理深度。nil 时整个字段不出现在 JSON 里——不认识它的服务端不该因为我们
    /// 多发了一个键就拒绝请求。
    var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
      case model, messages, stream
      case maxTokens = "max_tokens"
      case reasoningEffort = "reasoning_effort"
    }
  }

  /// 总结与翻译要的是**转述**，不是推理。
  ///
  /// 实测 `step-3.7-flash`（StepFun 推理模型）一次 13,402 字符的英译中：输出
  /// 15,249 token，而落到译文里的只有 5,982 字符——约七成 token 是用户看不到的
  /// 思考过程，却照样占生成时间。同一条链路上非推理模型的字符/token 是 1.24，
  /// 它只有 0.39。
  ///
  /// 所以这两类任务一律请求最低推理档。StepFun 官方文档的取值是 low/medium/high；
  /// 这也正是 OpenAI 的 `reasoning_effort` 参数名，兼容面足够宽。
  static let lowReasoningEffort = "low"
  static let noneReasoningEffort = "none"

  /// 这个失败**可能**是「服务端不认识我们多发的那个参数」。
  ///
  /// 只认那些「请求本身被拒」的码：拒绝的原因是模型不存在、鉴权不过、限流或服务端
  /// 挂了时，去掉一个参数重来毫无意义，只会白白多打一次请求。
  /// 目的地的标识：同一个 baseURL 上不同模型对参数的支持可能不同。
  static func reasoningEffortDestinationKey(_ profile: ProviderProfile) -> String {
    "\(profile.baseURL.absoluteString)|\(profile.model)"
  }

  private func preferredReasoningEffort(_ profile: ProviderProfile) -> StreamReasoningEffort {
    if let testingPreferredReasoningEffort { return testingPreferredReasoningEffort }
    let key = Self.reasoningEffortDestinationKey(profile)
    return reasoningEffortLock.withLock {
      if reasoningEffortRejectedDestinations.contains(key) { return .omitted }
      if reasoningNoneRejectedDestinations.contains(key) { return .low }
      return .none
    }
  }

  private func rememberRejected(_ effort: StreamReasoningEffort, for profile: ProviderProfile) {
    let key = Self.reasoningEffortDestinationKey(profile)
    reasoningEffortLock.withLock {
      switch effort {
      case .none:
        _ = reasoningNoneRejectedDestinations.insert(key)
      case .low, .omitted:
        _ = reasoningEffortRejectedDestinations.insert(key)
      }
    }
  }

  private func rememberThinkingStall(_ profile: ProviderProfile) {
    let key = Self.reasoningEffortDestinationKey(profile)
    reasoningEffortLock.withLock { _ = reasoningStallDestinations.insert(key) }
  }

  private func canRetryThinkingStall(_ profile: ProviderProfile) -> Bool {
    let key = Self.reasoningEffortDestinationKey(profile)
    return reasoningEffortLock.withLock { !reasoningNoneRejectedDestinations.contains(key) }
  }

  static func mayRejectUnknownParameter(_ failure: ModelProviderFailure) -> Bool {
    switch failure.code {
    case .providerRequestRejected, .protocolIncompatible:
      true
    default:
      false
    }
  }


  private struct NonStreamingCompletionResponse: Decodable {
    struct Choice: Decodable {
      struct ResponseMessage: Decodable { let content: String? }
      let message: ResponseMessage
    }
    struct Usage: Decodable {
      let promptTokens: Int?
      let completionTokens: Int?
      let totalTokens: Int?

      enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
      }
    }
    let choices: [Choice]
    let usage: Usage?
  }

  private struct ModelCatalogResponse: Decodable {
    let data: [ModelCatalogEntry]
  }
  private struct ModelCatalogEntry: Decodable {
    let id: String
  }

  private struct Message: Encodable {
    let role: String
    let content: String
  }

  private struct ProviderErrorBody {
    let normalizedCode: String?
    let indicatesMissingModel: Bool
    /// 服务端说这是「余额/配额」问题。
    ///
    /// 起因：opencode Zen 在余额不足时返回的是 **HTTP 401**，正文里写着
    /// `{"error":{"type":"CreditsError","message":"余额不足…"}}`。只看状态码就会
    /// 归成「鉴权失败」，界面于是让用户去换 API Key——Key 换十次也没用，
    /// 该做的是充值。状态码在这里是错的，服务端自己给的类型才是对的。
    let indicatesBillingLimit: Bool

    init?(data: Data) {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
      }

      let openAIError = object["error"] as? [String: Any]
      let detail = object["detail"] as? [String: Any]
      // Only structured error codes classify a response. Free-form message
      // text is deliberately neither stored nor consulted: it is not a
      // closed, provider-neutral syntax boundary.
      normalizedCode = Self.firstString(
        openAIError?["code"],
        detail?["code"],
        object["code"]
      )?.lowercased()
      // `type` 和 `code` 一样是结构化字段，不是自由文本，所以可以用来分类。
      let normalizedType = Self.firstString(
        openAIError?["type"],
        detail?["type"],
        object["type"]
      )?.lowercased()
      indicatesMissingModel = Self.indicatesMissingModel(normalizedCode: normalizedCode)
      indicatesBillingLimit = Self.indicatesBillingLimit(normalizedCode: normalizedCode)
        || Self.indicatesBillingLimit(normalizedCode: normalizedType)
    }

    /// 覆盖各家常见写法：`CreditsError`、`insufficient_quota`、`billing_*`。
    private static func indicatesBillingLimit(normalizedCode: String?) -> Bool {
      guard let normalizedCode else { return false }
      return normalizedCode.contains("credit")
        || normalizedCode.contains("quota")
        || normalizedCode.contains("billing")
        || normalizedCode.contains("insufficient")
    }

    private static func indicatesMissingModel(normalizedCode: String?) -> Bool {
      if let normalizedCode,
         normalizedCode.contains("model") && (normalizedCode.contains("not_found") || normalizedCode.contains("not-found")) {
        return true
      }
      return false
    }

    private static func firstString(_ values: Any?...) -> String? {
      values.compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
  }
}

/// Keep redirects within the original API origin. It uses the same URLSession
/// transport as streaming and never relaxes normal HTTPS/loopback validation.
private final class CatalogRedirectGuard: NSObject, URLSessionTaskDelegate {
  private let scheme: String
  private let host: String
  private let port: Int?

  init(origin: URL) {
    scheme = origin.scheme?.lowercased() ?? ""
    host = origin.host?.lowercased() ?? ""
    port = origin.port
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url.flatMap { acceptedFinalURL($0) ? request : nil })
  }

  func acceptedFinalURL(_ url: URL) -> Bool {
    url.user == nil && url.password == nil
      && url.scheme?.lowercased() == scheme
      && url.host?.lowercased() == host
      && url.port == port
  }
}

enum StreamReasoningEffort: Equatable {
  case none
  case low
  case omitted

  var jsonValue: String? {
    switch self {
    case .none: OpenAICompatibleProvider.noneReasoningEffort
    case .low: OpenAICompatibleProvider.lowReasoningEffort
    case .omitted: nil
    }
  }

  var logLabel: String {
    jsonValue ?? "omitted"
  }

  func steppedDown() -> StreamReasoningEffort? {
    switch self {
    case .none: .low
    case .low: .omitted
    case .omitted: nil
    }
  }
}

private struct ThinkingStallRetry: Error {}

private final class FirstDeltaWatch: @unchecked Sendable {
  private let lock = NSLock()
  private var delta = false
  private var reasoning = false

  func markDelta() { lock.withLock { delta = true } }
  func markReasoning() { lock.withLock { reasoning = true } }
  var hasDelta: Bool { lock.withLock { delta } }
  var sawReasoningOnly: Bool { lock.withLock { reasoning && !delta } }
}

/// 一次「出字特别慢」的流式请求留下的分段耗时。
///
/// 为什么需要它：慢有四种完全不同的原因——建连慢、服务端接单后不开口、服务端
/// 一直在流用户看不见的思考、App 自己卡住。四者在界面上长得一模一样（都是转圈），
/// 靠读代码分不出来。2026-08-06 排查「总结要 30 秒」时，先后猜过通道、VPN、
/// 模型，三次都错；加上这几个时间戳后一次定位：TTFB 的 99% 是服务端在流思考，
/// 而抑制它的 `reasoning_effort` 被误删了。
///
/// 为什么写文件而不是 NSLog：汲作用 `open` 启动时 stderr 没有去处，NSLog 也不
/// 落进统一日志——打了等于没打，只会被误判成「代码没走到」。
///
/// 只写非敏感值：模型名、host、毫秒数、事件计数。请求体、响应体、API Key
/// 一概不写。
enum ProviderTimingLog {
  /// 低于这个首字延迟不记录。正常请求（实测中位 5 秒）因此完全不写盘，
  /// 日志里留下的每一行都是真的值得看的一次。
  static let slowFirstDeltaThreshold: TimeInterval = 15

  /// 文件上限。超了就从头写，避免长期使用堆成一个没人清理的大文件。
  private static let byteLimit = 256 * 1_024

  private static let lock = NSLock()
  /// 只在 `lock` 里碰它，所以共享可变状态是被序列化的；`ISO8601DateFormatter`
  /// 本身不是 Sendable，这里显式标注而不是每次新建一个。
  private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let fileURL: URL? = {
    guard let root = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    ) else { return nil }
    return root.appendingPathComponent("LinkDigest/slow-run-diagnostic.log")
  }()

  static func write(_ line: String) {
    guard let fileURL else { return }
    let now = Date()
    lock.withLock {
      guard let data = "\(formatter.string(from: now)) \(line)\n".data(using: .utf8) else { return }
      let existing = (try? FileHandle(forWritingTo: fileURL)).flatMap { handle -> UInt64? in
        defer { try? handle.close() }
        return try? handle.seekToEnd()
      }
      guard let existing, existing < UInt64(byteLimit),
            let handle = try? FileHandle(forWritingTo: fileURL)
      else {
        try? data.write(to: fileURL)
        return
      }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
