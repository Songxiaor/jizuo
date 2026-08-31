import Foundation
import LinkDigestCore

public final class OpenAICompatibleTitleLocalizer: TitleLocalizing, @unchecked Sendable {
  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  public func localize(title: String, body: String?, outputLanguage: String, model: String?) async throws -> String {
    let credentials: (profile: ProviderProfile, apiKey: String)
    do {
      guard let loaded = try await configurationService.loadCredentials() else {
        throw TitleLocalizationError.modelNotConfigured
      }
      credentials = loaded
    } catch let error as TitleLocalizationError {
      throw error
    } catch {
      throw TitleLocalizationError.modelNotConfigured
    }
    let trimmedOverride = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveModel = trimmedOverride?.isEmpty == false ? trimmedOverride! : credentials.profile.model
    do {
      let outcome = try await provider.localizeTitle(
        profile: credentials.profile,
        apiKey: credentials.apiKey,
        model: effectiveModel,
        title: title,
        body: body,
        outputLanguage: outputLanguage
      )
      let sanitized = CapturedTitleLocalization.sanitizedModelTitle(outcome)
      guard !sanitized.isEmpty else { throw TitleLocalizationError.emptyResult }
      return sanitized
    } catch is CancellationError {
      throw TitleLocalizationError.cancelled
    } catch let error as TitleLocalizationError {
      throw error
    } catch {
      throw TitleLocalizationError.emptyResult
    }
  }
}
