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

    guard let firstChoice = response.choices.first else {
      throw ModelProviderFailure(
        code: .protocolIncompatible,
        retryable: false,
        hadOutput: false
      )
    }
    guard let content = firstChoice.delta.content, !content.isEmpty else {
      return nil
    }
    return .delta(content)
  }

  private struct StreamResponse: Decodable {
    let choices: [Choice]
  }

  private struct Choice: Decodable {
    let delta: Delta
  }

  private struct Delta: Decodable {
    let content: String?
  }
}
