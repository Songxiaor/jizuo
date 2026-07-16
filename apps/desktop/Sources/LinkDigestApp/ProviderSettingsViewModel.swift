import Combine
import Foundation
import LinkDigestCore

enum ProviderSettingsState: Equatable {
  case unconfigured
  case saving
  case configured
  case failed(code: String)
}

enum ConnectionTestState: Equatable {
  case idle
  case testing
  case success
  case failure(code: String)
  case blockedUnsavedChanges
}

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
  @Published var baseURL = "" {
    didSet { handleDraftEdit(from: oldValue, to: baseURL) }
  }
  @Published var modelName = "" {
    didSet { handleDraftEdit(from: oldValue, to: modelName) }
  }
  @Published private(set) var state: ProviderSettingsState = .unconfigured
  @Published private(set) var connectionTestState: ConnectionTestState = .idle
  @Published private(set) var savedIdentity: DataDestinationIdentity?

  private let configurationService: ProviderConfigurationService
  private let provider: any ModelProvider
  private var hasLoaded = false
  private var draftGeneration: UInt64 = 0
  private var activeTestRequest: ConnectionTestRequest?

  private struct ConnectionTestRequest {
    let id: UUID
    let generation: UInt64
    let identity: DataDestinationIdentity
  }

  init(
    configurationService: ProviderConfigurationService,
    provider: any ModelProvider
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  var isSaving: Bool {
    state == .saving
  }

  var isTestingConnection: Bool {
    activeTestRequest != nil
  }

  var hasUnsavedIdentityChanges: Bool {
    guard let savedIdentity, let draftIdentity else { return true }
    return draftIdentity != savedIdentity
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

  var connectionTestStatusText: String {
    switch connectionTestState {
    case .idle:
      "尚未测试连接"
    case .testing:
      "正在测试连接…"
    case .success:
      "连接成功。"
    case let .failure(code):
      V02ErrorCatalog.presentation(for: code).visibleText
    case .blockedUnsavedChanges:
      "有未保存更改，请先保存后再测试"
    }
  }

  func load() async {
    guard !hasLoaded else {
      return
    }
    hasLoaded = true

    do {
      guard let profile = try await configurationService.load() else {
        savedIdentity = nil
        state = .unconfigured
        return
      }
      baseURL = profile.baseURL.absoluteString
      modelName = profile.model
      savedIdentity = DataDestinationIdentity(profile: profile)
      connectionTestState = .idle
      state = .configured
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreReadFailed.rawValue)
    }
  }

  func save(apiKey: String) async {
    guard !isSaving, !isTestingConnection else {
      return
    }
    connectionTestState = .idle
    state = .saving
    let submittedBaseURL = baseURL
    let submittedModel = modelName

    do {
      let profile = try await configurationService.save(
        baseURL: submittedBaseURL,
        model: submittedModel,
        apiKey: apiKey
      )
      savedIdentity = DataDestinationIdentity(profile: profile)
      connectionTestState = .idle
      state = .configured
    } catch let error as ProviderConfigurationError {
      state = .failed(code: error.rawValue)
    } catch {
      state = .failed(code: ProviderConfigurationError.profileStoreWriteFailed.rawValue)
    }
  }

  func testConnection() async {
    guard !isSaving,
          activeTestRequest == nil,
          let savedIdentity,
          !hasUnsavedIdentityChanges
    else {
      connectionTestState = .blockedUnsavedChanges
      return
    }

    let request = ConnectionTestRequest(
      id: UUID(),
      generation: draftGeneration,
      identity: savedIdentity
    )
    activeTestRequest = request
    connectionTestState = .testing
    defer { releaseTestRequest(ifOwner: request.id) }

    do {
      guard let credentials = try await configurationService.loadCredentials() else {
        applyTestResult(
          .failure(code: ModelRunErrorCode.modelNotConfigured.rawValue),
          for: request
        )
        return
      }
      guard DataDestinationIdentity(profile: credentials.profile) == request.identity else {
        applyTestResult(
          .failure(code: ProviderConfigurationError.configurationChanged.rawValue),
          for: request
        )
        return
      }
      var completed = false
      for try await event in provider.stream(
        profile: credentials.profile,
        apiKey: credentials.apiKey,
        intent: .connectionTest
      ) {
        if case .completed = event {
          completed = true
          break
        }
      }
      applyTestResult(
        completed ? .success : .failure(code: ModelProviderErrorCode.networkInterrupted.rawValue),
        for: request
      )
    } catch let error as ProviderConfigurationError {
      applyTestResult(.failure(code: error.rawValue), for: request)
    } catch let failure as ModelProviderFailure {
      applyTestResult(.failure(code: failure.code.rawValue), for: request)
    } catch {
      applyTestResult(
        .failure(code: ModelProviderErrorCode.networkInterrupted.rawValue),
        for: request
      )
    }
  }

  private var draftIdentity: DataDestinationIdentity? {
    try? DataDestinationIdentity(baseURL: baseURL, model: modelName)
  }

  private func handleDraftEdit(from oldValue: String, to newValue: String) {
    guard oldValue != newValue else { return }
    draftGeneration &+= 1
    connectionTestState = hasUnsavedIdentityChanges ? .blockedUnsavedChanges : .idle
  }

  private func applyTestResult(_ result: ConnectionTestState, for request: ConnectionTestRequest) {
    guard activeTestRequest?.id == request.id,
          draftGeneration == request.generation,
          savedIdentity == request.identity,
          !hasUnsavedIdentityChanges
    else { return }
    connectionTestState = result
  }

  private func releaseTestRequest(ifOwner requestID: UUID) {
    guard activeTestRequest?.id == requestID else { return }
    activeTestRequest = nil
  }
}
