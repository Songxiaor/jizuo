import Foundation
import LinkDigestCore

/// Command Code `/provider/v1/messages` 的 Anthropic 形状编解码。
///
/// 约束来自官方文档：system 在顶层、`max_tokens` 必填、不要发 OpenAI 特有
/// `reasoning_*` 字段；流式认 `text_delta`、跨事件合并的 usage、`message_stop`，
/// 以及必须失败的 `error` SSE。
enum CommandCodeMessagesCodec {
  /// 总结/翻译等长输出的默认上限。Anthropic 要求必填；OpenAI 路径可省略。
  static let defaultMaxTokens = 8_192

  struct TextMessage: Equatable, Encodable {
    let role: String
    let content: String
  }

  static func encodeRequest(
    model: String,
    system: String?,
    messages: [TextMessage],
    stream: Bool,
    maxTokens: Int
  ) throws -> Data {
    let body = RequestBody(
      model: model,
      maxTokens: max(1, maxTokens),
      system: Self.trimmedOrNil(system),
      messages: messages.filter { $0.role == "user" || $0.role == "assistant" },
      stream: stream
    )
    return try JSONEncoder().encode(body)
  }

  static func decodeNonStreamingText(from data: Data) -> NonStreamingResult {
    let decoded = try? JSONDecoder().decode(NonStreamingResponse.self, from: data)
    let text = decoded?.content
      .filter { $0.type == "text" }
      .compactMap(\.text)
      .joined() ?? ""
    return NonStreamingResult(
      content: text,
      promptTokens: decoded?.usage?.inputTokens,
      completionTokens: decoded?.usage?.outputTokens,
      totalTokens: Self.totalTokens(
        input: decoded?.usage?.inputTokens,
        output: decoded?.usage?.outputTokens
      )
    )
  }

  struct NonStreamingResult {
    let content: String
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
  }

  private static func trimmedOrNil(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func totalTokens(input: Int?, output: Int?) -> Int? {
    switch (input, output) {
    case let (prompt?, completion?):
      let sum = prompt.addingReportingOverflow(completion)
      return sum.overflow ? nil : sum.partialValue
    case let (prompt?, nil):
      return prompt
    case let (nil, completion?):
      return completion
    case (nil, nil):
      return nil
    }
  }

  private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [TextMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
      case model, system, messages, stream
      case maxTokens = "max_tokens"
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(model, forKey: .model)
      try container.encode(maxTokens, forKey: .maxTokens)
      try container.encode(messages, forKey: .messages)
      try container.encode(stream, forKey: .stream)
      try container.encodeIfPresent(system, forKey: .system)
    }
  }

  private struct NonStreamingResponse: Decodable {
    struct ContentBlock: Decodable {
      let type: String
      let text: String?
    }

    struct Usage: Decodable {
      let inputTokens: Int?
      let outputTokens: Int?

      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
      }
    }

    let content: [ContentBlock]
    let usage: Usage?
  }
}

/// Anthropic Messages SSE → `ModelStreamEvent`。
///
/// 有状态：输入量在 `message_start.message.usage`，输出量在 `message_delta.usage`，
/// 合并后再发 `.usage`。`error` 事件必须失败，且 `hadOutput` 反映是否已吐过正文。
/// 一次 `decode` 可返回多个事件（例如 stop 时先 usage 再 completed）。
final class CommandCodeMessagesStreamDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private var inputTokens: Int64?
  private var outputTokens: Int64?
  private var didEmitDelta = false
  private var lastUsage: RunUsageCost?

  init() {}

  func decode(line: String) throws -> [ModelStreamEvent] {
    guard line.hasPrefix("data:") else { return [] }
    let payload = line.dropFirst("data:".count)
      .trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty else { return [] }

    guard let data = payload.data(using: .utf8) else {
      throw failure(.streamMalformed, retryable: false)
    }

    let event: StreamEvent
    do {
      event = try JSONDecoder().decode(StreamEvent.self, from: data)
    } catch let error as DecodingError {
      let code: ModelProviderErrorCode
      switch error {
      case .dataCorrupted:
        code = .streamMalformed
      case .keyNotFound, .typeMismatch, .valueNotFound:
        code = .protocolIncompatible
      @unknown default:
        code = .protocolIncompatible
      }
      throw failure(code, retryable: false)
    } catch {
      throw failure(.streamMalformed, retryable: false)
    }

    switch event.type {
    case "message_start":
      mergeUsage(
        input: event.message?.usage?.inputTokens,
        output: event.message?.usage?.outputTokens
      )
      return []
    case "content_block_delta":
      guard event.delta?.type == "text_delta",
            let text = event.delta?.text,
            !text.isEmpty
      else {
        return []
      }
      lock.withLock { didEmitDelta = true }
      return [.delta(text)]
    case "message_delta":
      mergeUsage(
        input: event.usage?.inputTokens,
        output: event.usage?.outputTokens
      )
      if let usage = takeUsageEvent() {
        return [usage]
      }
      return []
    case "message_stop":
      var events: [ModelStreamEvent] = []
      if let usage = takeUsageEvent() {
        events.append(usage)
      }
      events.append(.completed)
      return events
    case "error":
      throw mapError(event.error)
    default:
      return []
    }
  }

  private func mergeUsage(input: Int64?, output: Int64?) {
    lock.withLock {
      if let input, input >= 0 { inputTokens = input }
      if let output, output >= 0 { outputTokens = output }
    }
  }

  private func takeUsageEvent() -> ModelStreamEvent? {
    lock.withLock {
      guard inputTokens != nil || outputTokens != nil else { return nil }
      let prompt = inputTokens
      let completion = outputTokens
      let total: Int64?
      switch (prompt, completion) {
      case let (p?, c?):
        let sum = p.addingReportingOverflow(c)
        total = sum.overflow ? nil : sum.partialValue
      case let (p?, nil): total = p
      case let (nil, c?): total = c
      case (nil, nil): total = nil
      }
      let usage = RunUsageCost(inputTokens: prompt, outputTokens: completion, totalTokens: total)
      guard usage != lastUsage else { return nil }
      lastUsage = usage
      return .usage(usage)
    }
  }

  private func failure(
    _ code: ModelProviderErrorCode,
    retryable: Bool
  ) -> ModelProviderFailure {
    ModelProviderFailure(
      code: code,
      retryable: retryable,
      hadOutput: lock.withLock { didEmitDelta }
    )
  }

  private func mapError(_ error: StreamEvent.ErrorBody?) -> ModelProviderFailure {
    let normalized = error?.type?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    let code: ModelProviderErrorCode
    let retryable: Bool
    switch normalized {
    case "authentication_error":
      code = .authInvalid
      retryable = false
    case "permission_error":
      code = .authForbidden
      retryable = false
    case "rate_limit_error":
      code = .rateLimited
      retryable = true
    case "overloaded_error", "api_error":
      code = .providerUnavailable
      retryable = true
    case "invalid_request_error":
      code = .providerRequestRejected
      retryable = false
    default:
      code = .protocolIncompatible
      retryable = false
    }
    return failure(code, retryable: retryable)
  }

  private struct StreamEvent: Decodable {
    let type: String
    let message: MessageStart?
    let delta: Delta?
    let usage: UsageCounters?
    let error: ErrorBody?

    struct MessageStart: Decodable {
      let usage: UsageCounters?
    }

    struct Delta: Decodable {
      let type: String?
      let text: String?
    }

    struct UsageCounters: Decodable {
      let inputTokens: Int64?
      let outputTokens: Int64?

      enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
      }
    }

    struct ErrorBody: Decodable {
      let type: String?
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
