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
    let normalizedPath = baseURL.path.split(separator: "/").map(String.init)
    if normalizedPath.suffix(2) == ["chat", "completions"] {
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
    components.percentEncodedPath = path + "/chat/completions"

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

public final class OpenAICompatibleProvider: ModelProvider, @unchecked Sendable {
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
        _ = try validate(response: response, hadOutput: false)

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
    case let .summarize(title, text):
      messages = [
        Message(
          role: "system",
          content: "Summarize only the captured webpage content. Preserve the core conclusions and important evidence, do not invent facts, and explicitly note when the captured content appears incomplete."
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
      stream: true
    ))
    return request
  }

  private func capturedContent(title: String?, text: String) -> String {
    let titleLine = title.map { "Captured title:\n\($0)\n\n" } ?? ""
    return "\(titleLine)Captured content:\n<<<\n\(text)\n>>>"
  }

  private func validate(response: URLResponse, hadOutput: Bool) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: hadOutput
      )
    }

    switch response.statusCode {
    case 200..<300:
      guard response.value(forHTTPHeaderField: "Content-Type")?
        .lowercased().hasPrefix("text/event-stream") == true else {
        throw ModelProviderFailure(
          code: .protocolIncompatible,
          retryable: false,
          hadOutput: hadOutput
        )
      }
    case 401, 403:
      throw ModelProviderFailure(code: .authInvalid, retryable: false, hadOutput: hadOutput)
    case 404:
      throw ModelProviderFailure(code: .endpointNotFound, retryable: false, hadOutput: hadOutput)
    case 413:
      throw ModelProviderFailure(code: .inputTooLarge, retryable: false, hadOutput: hadOutput)
    case 429:
      throw ModelProviderFailure(code: .rateLimited, retryable: true, hadOutput: hadOutput)
    case 500...599:
      throw ModelProviderFailure(code: .providerUnavailable, retryable: true, hadOutput: hadOutput)
    default:
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: hadOutput
      )
    }
    return response
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

  private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
  }

  private struct Message: Encodable {
    let role: String
    let content: String
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
