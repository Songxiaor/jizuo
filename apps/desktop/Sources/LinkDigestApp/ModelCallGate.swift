import Foundation
import LinkDigestCore

/// 第二批新增的模型调用（整理标签、素材卡）共用的出口闸门：
/// 发出任何内容前，先过现有的「数据去向确认」（`DataDestinationConsent`）。
/// 没确认过当前服务商/模型 → 返回 `needsConfirmation`，由界面问用户；用户确认才记住并放行。
/// 闸门是闭包集合，测试里换成假的，不碰钥匙串和用户设置。
struct ModelCallGate: Sendable {
  enum Status: Equatable, Sendable {
    case allowed
    case needsConfirmation(host: String, model: String)
    case unavailable(String)
  }

  var status: @Sendable () async -> Status
  /// 用户确认的是弹窗里展示的 host + model。只有当前实际服务商/模型仍是它们才记下确认并返回 true；
  /// 弹窗期间换了服务商或模型则不记、返回 false，调用方要重新弹窗，不能发送。
  var confirm: @Sendable (_ host: String, _ model: String) async -> Bool

  static let alwaysAllowed = ModelCallGate(status: { .allowed }, confirm: { _, _ in true })

  static func live(
    configurationService: ProviderConfigurationService,
    consentStore: any DataDestinationConsentStore
  ) -> ModelCallGate {
    ModelCallGate(
      status: {
        guard let profile = try? await configurationService.loadProfileForDisclosure() else {
          return .unavailable("还没有配置模型服务，请先到设置的「模型服务」里添加。")
        }
        let identity = DataDestinationIdentity(profile: profile)
        // 读确认记录失败时按「没确认」处理：多问一次，不默默发出去。
        let confirmed = (try? await consentStore.isConfirmed(for: identity)) ?? false
        return confirmed ? .allowed : .needsConfirmation(host: identity.host, model: identity.model)
      },
      confirm: { host, model in
        guard let profile = try? await configurationService.loadProfileForDisclosure() else { return false }
        let identity = DataDestinationIdentity(profile: profile)
        guard identity.host == host, identity.model == model else { return false }
        return (try? await consentStore.rememberConfirmation(for: identity)) != nil
      }
    )
  }
}
