import Foundation

/// User-added model configurations plus the per-capability assignments shown
/// in settings. `summaryProfileID` selects the profile used for summary and
/// translation runs; `transcriptionProfileID == nil` means the built-in local
/// Apple Speech transcription, which stays the default.
public struct ModelLibrary: Codable, Sendable, Equatable {
  public var profiles: [ProviderProfile]
  public var summaryProfileID: String?
  public var transcriptionProfileID: String?

  public init(
    profiles: [ProviderProfile] = [],
    summaryProfileID: String? = nil,
    transcriptionProfileID: String? = nil
  ) {
    self.profiles = profiles
    self.summaryProfileID = summaryProfileID
    self.transcriptionProfileID = transcriptionProfileID
  }

  public func profile(withID id: String?) -> ProviderProfile? {
    guard let id else { return nil }
    return profiles.first(where: { $0.id == id })
  }

  public var summaryProfile: ProviderProfile? { profile(withID: summaryProfileID) }
  public var transcriptionProfile: ProviderProfile? { profile(withID: transcriptionProfileID) }
}

public protocol ModelLibraryStore: Sendable {
  func load() async throws -> ModelLibrary?
  func save(_ library: ModelLibrary) async throws
}
