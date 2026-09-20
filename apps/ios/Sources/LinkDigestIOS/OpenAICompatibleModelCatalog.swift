import Foundation
import LinkDigestShared

public enum ModelCatalogError: Error, LocalizedError, Sendable, Equatable {
  case invalidBaseURL
  case missingAPIKey
  case httpStatus(Int)
  case decodingFailed
  case emptyCatalog
  case providerMessage(String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Base URL 无效，无法请求 /models。"
    case .missingAPIKey:
      return "请先填写或保存 API Key，再获取模型列表。"
    case .httpStatus(let code):
      if code == 404 {
        return "该 Base URL 没有 /models 接口（404）。请检查地址，或手动填写模型名。"
      }
      return OpenAICompatibleAPI.publicHTTPMessage(status: code)
    case .decodingFailed:
      return "服务返回的 /models 协议不兼容，请手动填写模型名。"
    case .emptyCatalog:
      return "服务返回了空的模型列表。"
    case .providerMessage:
      return "模型服务拒绝了这次请求。"
    }
  }
}

/// OpenAI-compatible `GET {base}/models`，与 Mac 设置页「获取模型」同语义。
public struct OpenAICompatibleModelCatalog: Sendable {
  public static let defaultByteLimit = 2 * 1024 * 1024

  private let session: URLSession
  private let byteLimit: Int

  public init(session: URLSession = .shared, byteLimit: Int = OpenAICompatibleModelCatalog.defaultByteLimit) {
    self.session = session
    self.byteLimit = max(64 * 1024, byteLimit)
  }

  public func listModels(baseURL: String, apiKey: String) async throws -> [String] {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else { throw ModelCatalogError.missingAPIKey }

    let endpoint = try Self.modelsURL(baseURL: baseURL)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 30

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    if !(200...299).contains(status) {
      throw ModelCatalogError.httpStatus(status)
    }

    guard data.count <= byteLimit else {
      throw ModelCatalogError.decodingFailed
    }

    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["data"] as? [[String: Any]]
    else {
      throw ModelCatalogError.decodingFailed
    }

    var unique = Set<String>()
    for entry in entries {
      guard let id = entry["id"] as? String else { continue }
      let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { unique.insert(trimmed) }
    }
    guard !unique.isEmpty else { throw ModelCatalogError.emptyCatalog }
    return unique.sorted()
  }

  public static func modelsURL(baseURL: String) throws -> URL {
    do {
      return try OpenAICompatibleAPI.endpointURL(baseURL: baseURL, kind: .models)
    } catch {
      throw ModelCatalogError.invalidBaseURL
    }
  }
}
