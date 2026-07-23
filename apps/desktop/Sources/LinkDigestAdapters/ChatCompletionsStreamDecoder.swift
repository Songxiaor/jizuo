import Foundation
import LinkDigestCore

public struct ChatCompletionsStreamDecoder: Sendable {
  public init() {}

  public func decode(line: String) throws -> ModelStreamEvent? {
    guard line.hasPrefix("data:") else {
      return nil
    }

    let payload = line.dropFirst("data:".count)
      .trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty else {
      return nil
    }
    if payload == "[DONE]" {
      return .completed
    }

    guard let data = payload.data(using: .utf8) else {
      throw ModelProviderFailure(
        code: .streamMalformed,
        retryable: false,
        hadOutput: false
      )
    }

    let response: StreamResponse
    do {
      response = try JSONDecoder().decode(StreamResponse.self, from: data)
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
      throw ModelProviderFailure(code: code, retryable: false, hadOutput: false)
    } catch {
      throw ModelProviderFailure(
        code: .streamMalformed,
        retryable: false,
        hadOutput: false
      )
    }

    // A textual delta is the primary stream contract. Never let optional
    // usage metadata suppress it, even when that metadata is malformed.
    if let content = response.choices?.first?.delta.content, !content.isEmpty {
      return .delta(content)
    }

    if response.hasUsage {
      // A malformed usage-only tail is intentionally ignored. The provider can
      // still send [DONE], which completes the user-visible generation.
      return response.usage?.usageCost.map(ModelStreamEvent.usage)
    }

    guard response.choices?.first != nil else {
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: false
      )
    }
    return nil
  }

  private struct StreamResponse: Decodable {
    let choices: [Choice]?
    let usage: Usage?
    let hasUsage: Bool

    enum CodingKeys: String, CodingKey { case choices, usage }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      choices = try container.decodeIfPresent([Choice].self, forKey: .choices)
      hasUsage = container.contains(.usage)
      // `Usage` catches its own shape/type errors so the optional sidecar
      // cannot make the enclosing response fail to decode.
      usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
    }
  }

  private struct Choice: Decodable {
    let delta: Delta
  }

  private struct Delta: Decodable {
    let content: String?
  }

  /// OpenAI-compatible providers commonly emit this as a final chunk with an
  /// empty `choices` array. This decoder is intentionally lossy: it treats
  /// each counter as optional accounting metadata, never as stream validity.
  private struct Usage: Decodable {
    let usageCost: RunUsageCost?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
      do {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let prompt = Self.counter(container, key: .promptTokens)
        let completion = Self.counter(container, key: .completionTokens)
        let total = Self.counter(container, key: .totalTokens)
        guard case let .value(promptTokens) = prompt,
              case let .value(completionTokens) = completion,
              case let .value(totalTokens) = total
        else {
          usageCost = nil
          return
        }
        let candidate = RunUsageCost(
          inputTokens: promptTokens,
          outputTokens: completionTokens,
          totalTokens: totalTokens
        )
        usageCost = candidate == .unknown && (promptTokens != nil || completionTokens != nil || totalTokens != nil)
          ? nil
          : candidate
      } catch {
        // Scalar/array/null usage values are no more important than a malformed
        // counter: discard them and keep consuming the stream.
        usageCost = nil
      }
    }

    private enum Counter { case value(Int64?), invalid }

    private static func counter(
      _ container: KeyedDecodingContainer<CodingKeys>,
      key: CodingKeys
    ) -> Counter {
      guard container.contains(key) else { return .value(nil) }
      if (try? container.decodeNil(forKey: key)) == true { return .value(nil) }
      guard let value = try? container.decode(Int64.self, forKey: key), value >= 0 else { return .invalid }
      return .value(value)
    }
  }
}
