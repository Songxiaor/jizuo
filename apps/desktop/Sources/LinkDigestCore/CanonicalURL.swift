import Foundation

public enum CanonicalURLFailure: Error, Sendable, Equatable { case unsupported }

public struct CanonicalURL: Codable, Sendable, Equatable, Hashable {
  public static let version = 1
  public let value: String

  public init(_ rawValue: String) throws {
    guard var components = URLComponents(string: rawValue),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host?.lowercased(), !host.isEmpty
    else { throw CanonicalURLFailure.unsupported }

    components.scheme = scheme
    components.host = host
    components.fragment = nil
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
      components.port = nil
    }
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    guard let result = components.string else { throw CanonicalURLFailure.unsupported }
    value = result
  }
}
