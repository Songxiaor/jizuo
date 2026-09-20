import Foundation
import LinkDigestShared

public enum SummarizerError: Error, LocalizedError, Sendable, Equatable {
  case invalidBaseURL
  case httpStatus(Int)
  case emptyContent
  case decodingFailed
  case providerMessage(String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Base URL 无效。请填写 OpenAI-compatible 根地址（不要带 /chat/completions）。"
    case .httpStatus(let code):
      return OpenAICompatibleAPI.publicHTTPMessage(status: code)
    case .emptyContent:
      return "模型没有返回有效内容。"
    case .decodingFailed:
      return "无法解析模型返回的 JSON。"
    case .providerMessage:
      return "模型服务拒绝了这次请求。"
    }
  }
}

public enum GenerationIntent: String, Sendable, Equatable {
  case summarize
  case translate
  /// 从页面已有文案整理成「转写稿」；不是音轨识别。
  case pageTranscript
}

/// iOS 侧最小 OpenAI-compatible `/chat/completions` 客户端（总结 / 翻译）。
/// 可注入 `URLSession`（测试用本地假服务器）；不依赖桌面 Adapters。
public struct OpenAICompatibleSummarizer: Sendable {
  public static let defaultOutputLanguage = "简体中文"

  private let session: URLSession
  private let maxBodyCharacters: Int

  public init(
    session: URLSession = .shared,
    maxBodyCharacters: Int = 24_000
  ) {
    self.session = session
    self.maxBodyCharacters = max(2_000, maxBodyCharacters)
  }

  public func summarize(
    title: String,
    body: String,
    sourceURL: String?,
    baseURL: String,
    model: String,
    apiKey: String,
    outputLanguage: String = OpenAICompatibleSummarizer.defaultOutputLanguage
  ) async throws -> String {
    try await generate(
      intent: .summarize,
      title: title,
      body: body,
      sourceURL: sourceURL,
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      outputLanguage: outputLanguage
    )
  }

  public func translate(
    title: String,
    body: String,
    sourceURL: String?,
    baseURL: String,
    model: String,
    apiKey: String,
    outputLanguage: String = OpenAICompatibleSummarizer.defaultOutputLanguage
  ) async throws -> String {
    try await generate(
      intent: .translate,
      title: title,
      body: body,
      sourceURL: sourceURL,
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      outputLanguage: outputLanguage
    )
  }

  public func generate(
    intent: GenerationIntent,
    title: String,
    body: String,
    sourceURL: String?,
    baseURL: String,
    model: String,
    apiKey: String,
    outputLanguage: String = OpenAICompatibleSummarizer.defaultOutputLanguage
  ) async throws -> String {
    let endpoint = try Self.chatCompletionsURL(baseURL: baseURL)
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else { throw SummarizerError.providerMessage("API Key 为空。") }
    guard !trimmedModel.isEmpty else { throw SummarizerError.providerMessage("模型名为空。") }

    let language = Self.normalizedOutputLanguage(outputLanguage)
    let systemPrompt = Self.systemPrompt(for: intent, outputLanguage: language)

    var contentParts: [String] = []
    if !title.isEmpty {
      contentParts.append("标题：\(title)")
    }
    if let sourceURL, !sourceURL.isEmpty {
      contentParts.append("链接：\(sourceURL)")
    }
    let clippedBody: String
    if body.count > maxBodyCharacters {
      clippedBody = String(body.prefix(maxBodyCharacters)) + "\n…（正文已截断）"
    } else {
      clippedBody = body
    }
    contentParts.append("正文：\n\(clippedBody)")

    func payload(includesReasoningEffort: Bool) -> [String: Any] {
      var value: [String: Any] = [
        "model": trimmedModel,
        "temperature": intent == .translate ? 0.1 : 0.2,
        "messages": [
          ["role": "system", "content": systemPrompt],
          ["role": "user", "content": contentParts.joined(separator: "\n\n")],
        ],
      ]
      if includesReasoningEffort {
        value["reasoning_effort"] = OpenAICompatibleAPI.lowReasoningEffort
      }
      return value
    }

    func send(includesReasoningEffort: Bool) async throws -> (Data, Int) {
      guard let bodyData = try? JSONSerialization.data(withJSONObject: payload(includesReasoningEffort: includesReasoningEffort)) else {
        throw SummarizerError.decodingFailed
      }
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
      request.httpBody = bodyData
      request.timeoutInterval = 60
      let (data, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      return (data, status)
    }

    var (data, status) = try await send(includesReasoningEffort: true)
    if status == 400 {
      (data, status) = try await send(includesReasoningEffort: false)
    }
    if !(200...299).contains(status) {
      throw SummarizerError.httpStatus(status)
    }

    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw SummarizerError.decodingFailed
    }

    if root["error"] is [String: Any] {
      throw SummarizerError.providerMessage("rejected")
    }

    guard
      let choices = root["choices"] as? [[String: Any]],
      let first = choices.first,
      let message = first["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw SummarizerError.decodingFailed
    }

    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SummarizerError.emptyContent }
    return trimmed
  }

  public static func systemPrompt(
    for intent: GenerationIntent,
    outputLanguage: String = defaultOutputLanguage
  ) -> String {
    let language = normalizedOutputLanguage(outputLanguage)
    switch intent {
    case .summarize:
      return "Summarize only the provided webpage or note content. Preserve core conclusions and important evidence. Do not invent facts. Write the final answer in \(language)."
    case .translate:
      return "Translate the provided content into \(language). Preserve meaning, names, numbers, and structure. Do not summarize or invent facts. Output only the translation in \(language)."
    case .pageTranscript:
      return "Using only the provided page title/description/body, produce a clean spoken-style transcript draft in \(language). This is NOT audio recognition — you never heard the media. Do not invent scenes unsupported by the text. If the source is a short caption, keep it short. Do not claim you transcribed audio or video."
    }
  }

  public static func normalizedOutputLanguage(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultOutputLanguage : trimmed
  }

  public static func chatCompletionsURL(baseURL: String) throws -> URL {
    do {
      return try OpenAICompatibleAPI.endpointURL(baseURL: baseURL, kind: .chatCompletions)
    } catch {
      throw SummarizerError.invalidBaseURL
    }
  }
}
