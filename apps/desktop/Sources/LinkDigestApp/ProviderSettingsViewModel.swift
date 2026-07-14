import Combine
import Foundation
import LinkDigestCore

enum ProviderSettingsState: Equatable {
  case unconfigured
  case saving
  case configured
  case failed(code: String)
}

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
  @Published var baseURL = ""
  @Published var modelName = ""
  @Published private(set) var state: ProviderSettingsState = .unconfigured

  private let configurationService: ProviderConfigurationService
  private var hasLoaded = false

  init(configurationService: ProviderConfigurationService) {
    self.configurationService = configurationService
  }

  var isSaving: Bool {
    state == .saving
  }

  var statusText: String {
    switch state {
    case .unconfigured:
      "未配置模型"
    case .saving:
      "正在安全保存…"
    case .configured:
      "API Key：••••••••（已保存）"
    case let .failed(code):
      V02ErrorCatalog.presentation(for: code).visibleText
    }
  }

  func load() async {
    guard !hasLoaded else {
      return
    }
    hasLoaded = true

    do {
      guard let profile = try await configurationService.load() else {
        state = .unconfigured
        return
      }
      baseURL = profile.baseURL.absoluteString
      modelName = profile.model
      state = .configured
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreReadFailed.rawValue)
    }
  }

  func save(apiKey: String) async {
    guard !isSaving else {
      return
    }
    state = .saving

    do {
      let profile = try await configurationService.save(
        baseURL: baseURL,
        model: modelName,
        apiKey: apiKey
      )
      baseURL = profile.baseURL.absoluteString
      modelName = profile.model
      state = .configured
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreWriteFailed.rawValue)
    }
  }
}
