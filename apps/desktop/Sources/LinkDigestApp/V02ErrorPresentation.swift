import Foundation
import LinkDigestCore

struct V02ErrorPresentation: Equatable {
  let message: String
  let recoveryAction: String

  init(message: String, recoveryAction: String) {
    self.message = message
    self.recoveryAction = recoveryAction
  }

  var visibleText: String {
    [message, recoveryAction].joined(separator: " ")
  }
}

enum V02ErrorCatalog {
  static let configurationCodes: [String] = [
    ProviderConfigurationError.baseURLRequired.rawValue,
    ProviderConfigurationError.baseURLInvalid.rawValue,
    ProviderConfigurationError.modelRequired.rawValue,
    ProviderConfigurationError.apiKeyRequired.rawValue,
    ProviderConfigurationError.profileStoreReadFailed.rawValue,
    ProviderConfigurationError.profileStoreWriteFailed.rawValue,
    ProviderConfigurationError.secretStoreReadFailed.rawValue,
    ProviderConfigurationError.secretStoreWriteFailed.rawValue,
    ProviderConfigurationError.configurationChanged.rawValue,
    "SECRET_STORE_DELETE_FAILED"
  ]

  static let modelCodes: [String] = [
    ModelProviderErrorCode.baseURLInvalid.rawValue,
    ModelProviderErrorCode.authInvalid.rawValue,
    ModelProviderErrorCode.endpointNotFound.rawValue,
    ModelProviderErrorCode.modelNotFound.rawValue,
    ModelProviderErrorCode.providerBillingLimited.rawValue,
    ModelProviderErrorCode.providerRequestRejected.rawValue,
    ModelProviderErrorCode.rateLimited.rawValue,
    ModelProviderErrorCode.providerUnavailable.rawValue,
    ModelProviderErrorCode.networkInterrupted.rawValue,
    ModelProviderErrorCode.protocolIncompatible.rawValue,
    ModelProviderErrorCode.streamMalformed.rawValue,
    ModelProviderErrorCode.inputTooLarge.rawValue
  ]

  static let runCodes: [String] = [
    ModelRunErrorCode.modelNotConfigured.rawValue,
    ModelRunErrorCode.profileStoreReadFailed.rawValue,
    ModelRunErrorCode.secretStoreReadFailed.rawValue,
    ModelRunErrorCode.captureNotAvailable.rawValue,
    ModelRunErrorCode.captureContentEmpty.rawValue,
    ModelRunErrorCode.runFailed.rawValue
  ]

  static var allStableCodes: Set<String> {
    Set(configurationCodes + modelCodes + runCodes)
  }

  static func presentation(for code: String) -> V02ErrorPresentation {
    let presentation: V02ErrorPresentation = switch code {
    case ProviderConfigurationError.baseURLRequired.rawValue:
      .init(
        message: "Base URL 不能为空。",
        recoveryAction: "请输入以 https:// 开头的 OpenAI-compatible API root 后重新保存。"
      )
    case ProviderConfigurationError.baseURLInvalid.rawValue,
         ModelProviderErrorCode.baseURLInvalid.rawValue:
      .init(
        message: "模型服务地址不正确。",
        recoveryAction: "请填写不含账号、查询参数或片段的 https OpenAI-compatible API root 后重试。"
      )
    case ProviderConfigurationError.modelRequired.rawValue:
      .init(
        message: "模型名不能为空。",
        recoveryAction: "请输入模型服务支持的模型名后重新保存。"
      )
    case ProviderConfigurationError.apiKeyRequired.rawValue:
      .init(
        message: "API Key 不能为空。",
        recoveryAction: "请重新输入 API Key 后保存；\(ProductDisplay.name) 不会回显完整值。"
      )
    case ProviderConfigurationError.profileStoreReadFailed.rawValue:
      .init(
        message: "无法读取已保存的模型配置。",
        recoveryAction: "请重新打开 APP；仍失败时重新保存模型配置。"
      )
    case ProviderConfigurationError.profileStoreWriteFailed.rawValue:
      .init(
        message: "无法保存模型配置。",
        recoveryAction: "请检查本机存储是否可用后重试。"
      )
    case ProviderConfigurationError.secretStoreReadFailed.rawValue:
      .init(
        message: "无法安全读取 API Key。",
        recoveryAction: "请在模型配置中重新输入并保存 API Key 后重试。"
      )
    case ProviderConfigurationError.secretStoreWriteFailed.rawValue:
      .init(
        message: "无法安全保存 API Key。",
        recoveryAction: "请重新输入后重试；\(ProductDisplay.name) 不会降级为明文保存。"
      )
    case ProviderConfigurationError.configurationChanged.rawValue:
      .init(
        message: "模型目的地已变化。",
        recoveryAction: "请确认新的发送目的地后再继续。"
      )
    case "SECRET_STORE_DELETE_FAILED":
      .init(
        message: "旧 API Key 的安全清理未完成。",
        recoveryAction: "当前配置仍可使用；请稍后重新保存，后续可通过维护入口清理。"
      )
    case ModelRunErrorCode.modelNotConfigured.rawValue:
      .init(
        message: "尚未配置模型。",
        recoveryAction: "请先在模型配置中保存 Base URL、模型名和 API Key。"
      )
    case ModelProviderErrorCode.authInvalid.rawValue:
      .init(
        message: "模型服务未通过身份验证。",
        recoveryAction: "请在模型配置中更新 API Key 后重试。"
      )
    case ModelProviderErrorCode.endpointNotFound.rawValue:
      .init(
        message: "模型服务未找到 Chat Completions 接口。",
        recoveryAction: "请检查 Base URL 是否是 OpenAI-compatible Chat Completions API root。"
      )
    case ModelProviderErrorCode.modelNotFound.rawValue:
      .init(
        message: "模型服务未找到所选模型。",
        recoveryAction: "请检查模型名、访问权限和服务商模型目录后重试。"
      )
    case ModelProviderErrorCode.providerBillingLimited.rawValue:
      .init(
        message: "模型服务的计费或配额限制阻止了本次请求。",
        recoveryAction: "请前往服务商控制台检查支付方式、余额或可用额度后重试。"
      )
    case ModelProviderErrorCode.providerRequestRejected.rawValue:
      .init(
        message: "模型服务拒绝了本次请求。",
        recoveryAction: "请检查模型配置、服务商限制和请求参数后重试。"
      )
    case ModelProviderErrorCode.rateLimited.rawValue:
      .init(
        message: "模型服务当前请求过多。",
        recoveryAction: "请稍后重试或更换模型服务。"
      )
    case ModelProviderErrorCode.providerUnavailable.rawValue:
      .init(
        message: "Provider 暂时不可用。",
        recoveryAction: "请稍后重试。"
      )
    case ModelProviderErrorCode.networkInterrupted.rawValue:
      .init(
        message: "与模型服务的连接中断。",
        recoveryAction: "请检查网络后手动重试。"
      )
    case ModelProviderErrorCode.protocolIncompatible.rawValue:
      .init(
        message: "模型服务返回的协议与当前版本不兼容。",
        recoveryAction: "请检查 Base URL 是否是 OpenAI-compatible Chat Completions API root。"
      )
    case ModelProviderErrorCode.streamMalformed.rawValue:
      .init(
        message: "模型服务返回的流式数据无法解析。",
        recoveryAction: "请检查 Provider 兼容性或更换模型服务后重试。"
      )
    case ModelProviderErrorCode.inputTooLarge.rawValue:
      .init(
        message: "当前正文超过模型服务可接受的长度。",
        recoveryAction: "请改用选区或较短页面后重试。"
      )
    case ModelRunErrorCode.captureNotAvailable.rawValue:
      .init(
        message: "当前没有可处理的页面内容。",
        recoveryAction: "请先从浏览器重新发送当前页面。"
      )
    case ModelRunErrorCode.captureContentEmpty.rawValue:
      .init(
        message: "当前页面没有可用正文。",
        recoveryAction: "请等待页面加载、选择正文，或换一个页面后重新发送。"
      )
    case ModelRunErrorCode.runFailed.rawValue:
      .init(
        message: "本次生成未能开始。",
        recoveryAction: "请检查模型配置和网络后重试。"
      )
    default:
      .init(
        message: "操作未完成。",
        recoveryAction: "请检查模型配置和网络后重试。"
      )
    }
    return presentation
  }
}
