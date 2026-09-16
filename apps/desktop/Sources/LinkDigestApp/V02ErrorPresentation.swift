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
    ProviderConfigurationError.secretStoreReadTimedOut.rawValue,
    ProviderConfigurationError.secretStoreWriteFailed.rawValue,
    ProviderConfigurationError.configurationChanged.rawValue,
    "SECRET_STORE_DELETE_FAILED"
  ]

  static let modelCodes: [String] = [
    ModelProviderErrorCode.baseURLInvalid.rawValue,
    ModelProviderErrorCode.authInvalid.rawValue,
    ModelProviderErrorCode.authForbidden.rawValue,
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
        message: "服务地址还没填。",
        recoveryAction: "已保存的配置没有变化。请在「模型与识别 → 添加模型」里填上以 https:// 开头的服务地址后再保存。"
      )
    case ProviderConfigurationError.baseURLInvalid.rawValue,
         ModelProviderErrorCode.baseURLInvalid.rawValue:
      .init(
        message: "这个服务地址汲作用不了。",
        recoveryAction: "已保存的配置没有变化。请填服务商文档里给的那个 https 地址，不要带账号、问号后面的参数或井号片段。"
      )
    case ProviderConfigurationError.modelRequired.rawValue:
      .init(
        message: "还没选模型。",
        recoveryAction: "已保存的配置没有变化。请先点「读取模型列表」选一个，或手动填上模型名后再保存。"
      )
    case ProviderConfigurationError.apiKeyRequired.rawValue:
      .init(
        message: "密钥还没填。",
        recoveryAction: "已保存的配置没有变化。请重新输入一次密钥后保存；出于安全，\(ProductDisplay.name) 不会把已存的密钥显示出来。"
      )
    case ProviderConfigurationError.profileStoreReadFailed.rawValue:
      .init(
        message: "读不到已经保存的模型配置。",
        recoveryAction: "配置本身还在本机，没有被删。请重新打开 \(ProductDisplay.name)；还是这样就把这个模型重新保存一次。"
      )
    case ProviderConfigurationError.profileStoreWriteFailed.rawValue:
      .init(
        message: "这次没能把模型配置存下来。",
        recoveryAction: "原来那份配置还在，可以继续用。请确认磁盘还有空间、没有被锁住，然后再点一次保存。"
      )
    case ProviderConfigurationError.secretStoreReadFailed.rawValue:
      .init(
        message: "读不出这个模型的密钥。",
        recoveryAction: "密钥只存在本机钥匙串里，没有外泄。请在这个模型的配置里重新输入一次密钥并保存。"
      )
    case ProviderConfigurationError.secretStoreReadTimedOut.rawValue:
      .init(
        message: "读密钥等太久，这次先停下了。",
        recoveryAction: "密钥没有丢，多半是钥匙串在等你解锁或确认。请解锁本机、处理掉钥匙串弹窗后再试；还是这样就重新保存一次密钥。"
      )
    case ProviderConfigurationError.secretStoreWriteFailed.rawValue:
      .init(
        message: "这次没能把密钥安全地存起来。",
        recoveryAction: "\(ProductDisplay.name) 宁可不保存，也不会把密钥明文写到别处。请重新输入一次再保存。"
      )
    case ProviderConfigurationError.configurationChanged.rawValue:
      .init(
        message: "内容要发去的地方变了。",
        recoveryAction: "在你确认之前，什么都没有发出去。请看清新的目的地，确认后再继续。"
      )
    case "SECRET_STORE_DELETE_FAILED":
      .init(
        message: "旧密钥没能从钥匙串里清干净。",
        recoveryAction: "当前配置照常能用，也没有任何内容因此发错地方。请到「模型与识别」把这个模型删掉再重新添加一次，残留就会一起清掉。"
      )
    case ModelRunErrorCode.modelNotConfigured.rawValue:
      .init(
        message: "还没配置可用的模型。",
        recoveryAction: "你的内容都还在，只是这一步跑不了。请到「模型与识别 → 添加模型」，填好服务地址、密钥并选一个模型。"
      )
    case ModelProviderErrorCode.authInvalid.rawValue:
      .init(
        message: "模型服务不认这个密钥。",
        recoveryAction: "你的内容没有受影响。请到「模型与识别」更新密钥后再试一次。"
      )
    case ModelProviderErrorCode.authForbidden.rawValue:
      .init(
        message: "模型服务不让这个账号用这个模型。",
        recoveryAction: "密钥本身是好的，你的内容也没有受影响——通常是免费额度不含这个付费模型。请换一个已经开通的模型，或去服务商那边为它开通后再试。"
      )
    case ModelProviderErrorCode.endpointNotFound.rawValue:
      .init(
        message: "这个服务地址上没有汲作要调用的接口。",
        recoveryAction: "你的内容没有受影响。请回到「模型与识别」核对服务地址，照服务商文档里给的那一行填。"
      )
    case ModelProviderErrorCode.modelNotFound.rawValue:
      .init(
        message: "模型服务那边找不到你选的这个模型。",
        recoveryAction: "你的内容没有受影响。请回到「模型与识别」点「读取模型列表」重新选一个，或确认这个模型在你的账号下已经开通。"
      )
    case ModelProviderErrorCode.providerBillingLimited.rawValue:
      .init(
        message: "模型服务因为计费或配额限制挡下了这次请求。",
        recoveryAction: "没有产生这次的费用，你的内容也没有受影响。请去服务商控制台看看支付方式、余额或额度，再回来重试。"
      )
    case ModelProviderErrorCode.providerRequestRejected.rawValue:
      .init(
        message: "模型服务拒绝了这次请求。",
        recoveryAction: "你的内容没有受影响。请回到「模型与识别」核对这个模型的配置，或换一个模型再试。"
      )
    case ModelProviderErrorCode.rateLimited.rawValue:
      .init(
        message: "这会儿请求太多，模型服务让先等等。",
        recoveryAction: "你的内容没有受影响。请稍后重试或更换模型服务。"
      )
    case ModelProviderErrorCode.providerUnavailable.rawValue:
      .init(
        message: "模型服务暂时用不了。",
        recoveryAction: "这是对方的问题，你的内容没有受影响。请稍后重试。"
      )
    case ModelProviderErrorCode.networkInterrupted.rawValue:
      .init(
        message: "跟模型服务的连接中途断了。",
        recoveryAction: "已经跑出来的部分不会被覆盖。请检查网络后再点一次。"
      )
    case ModelProviderErrorCode.protocolIncompatible.rawValue:
      .init(
        message: "模型服务返回的东西汲作看不懂。",
        recoveryAction: "你的内容没有受影响。请回到「模型与识别」核对服务地址，照服务商文档里给的那一行填；确认无误还是这样，就换一个模型服务。"
      )
    case ModelProviderErrorCode.streamMalformed.rawValue:
      .init(
        message: "模型服务边生成边发回来的内容读不通。",
        recoveryAction: "已经保存的内容没有受影响。请再试一次；反复这样就换一个模型服务。"
      )
    case ModelProviderErrorCode.inputTooLarge.rawValue:
      .init(
        message: "这篇正文太长，超过了这个模型一次能吃下的量。",
        recoveryAction: "原文完整保存着，没有被截断。请选一段正文再跑，或换一个能吃更长正文的模型。"
      )
    case ModelRunErrorCode.captureNotAvailable.rawValue:
      .init(
        message: "现在没有可以处理的内容。",
        recoveryAction: "历史里的内容都还在。请先从浏览器重新发送一次当前页面。"
      )
    case ModelRunErrorCode.captureContentEmpty.rawValue:
      .init(
        message: "这个页面没抓到正文。",
        recoveryAction: "没有产生空记录。请等页面加载完、或自己选中正文再发一次；换一个页面也行。"
      )
    case ModelRunErrorCode.runFailed.rawValue:
      .init(
        message: "这次生成没能开始。",
        recoveryAction: "你的内容没有受影响。请检查网络和「模型与识别」里的配置后再点一次。"
      )
    default:
      .init(
        message: "这次操作没做完。",
        recoveryAction: "你的内容没有受影响。请检查网络和「模型与识别」里的配置后再试一次。"
      )
    }
    return presentation
  }
}
