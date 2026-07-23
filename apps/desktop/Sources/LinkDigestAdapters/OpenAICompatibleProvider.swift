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
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    text: String
  ) async throws -> TranscriptTidyOutcome {
    let completion = try await nonStreamingChatCompletion(
      profile: profile, apiKey: apiKey, model: model,
      systemPrompt: TranscriptTidyPrompt.system, userContent: text
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
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(RequestBody(
      model: profile.model,
      messages: [
        Message(role: "system", content: "为以下摘要输出 1-5 个中文标签，逗号分隔，不要输出其他内容"),
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
    let request = try makeRequest(profile: profile, apiKey: apiKey, intent: intent)
    var retryCount = 0

    while true {
      try Task.checkCancellation()
      var receivedDelta = false
      var currentResponse: HTTPURLResponse?

      do {
        let (bytes, response) = try await session.bytes(for: request)
        currentResponse = response as? HTTPURLResponse
        let providerError = try await providerError(from: bytes, response: response)
        _ = try validate(response: response, providerError: providerError, hadOutput: false)

        for try await line in bytes.lines {
          try Task.checkCancellation()
          do {
            guard let event = try ChatCompletionsStreamDecoder().decode(line: line) else {
              continue
            }
            switch event {
            case .delta:
              receivedDelta = true
              continuation.yield(event)
            case .usage:
              continuation.yield(event)
            case .completed:
              continuation.yield(.completed)
              continuation.finish()
              return
            }
          } catch let failure as ModelProviderFailure {
            throw ModelProviderFailure(
              code: failure.code,
              retryable: false,
              hadOutput: receivedDelta
            )
          }
        }

        throw ModelProviderFailure(
          code: .networkInterrupted,
          retryable: true,
          hadOutput: receivedDelta
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let failure as ModelProviderFailure {
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
    intent: RunIntent
  ) throws -> URLRequest {
    guard !apiKey.isEmpty else {
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: false)
    }
    guard profile.apiMode == .chatCompletions else {
      throw ModelProviderFailure(code: .protocolIncompatible, retryable: false, hadOutput: false)
    }

    let url = try OpenAICompatibleEndpoint.chatCompletionsURL(baseURL: profile.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
      messages = [
        Message(
          role: "system",
          content: "Translate only the captured webpage content into \(targetLanguage). Preserve meaning, structure, names, numbers, and links. Do not add commentary or facts that are not present in the captured content."
        ),
        Message(role: "user", content: capturedContent(title: title, text: text))
      ]
    }
    request.httpBody = try JSONEncoder().encode(RequestBody(
      model: profile.model,
      messages: messages,
      stream: true,
      maxTokens: nil
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
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: hadOutput)
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
          response.statusCode == 404
    else {
      return nil
    }

    var data = Data()
    let limit = 8_192
    for try await byte in bytes {
      guard data.count < limit else { break }
      data.append(byte)
    }
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
    case 401, 403: return .init(code: .authInvalid, retryable: false, hadOutput: false)
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

    enum CodingKeys: String, CodingKey {
      case model, messages, stream
      case maxTokens = "max_tokens"
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
      indicatesMissingModel = Self.indicatesMissingModel(normalizedCode: normalizedCode)
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

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
