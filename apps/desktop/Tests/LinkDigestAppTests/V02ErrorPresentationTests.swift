import XCTest
@testable import LinkDigestApp
import LinkDigestCore

final class V02ErrorPresentationTests: XCTestCase {
  func testEveryStableCodeHasMessageAndRecoveryAction() {
    // 2026-08-06 加了 MODEL_AUTH_FORBIDDEN（403）：原来 401 和 403 共用
    // MODEL_AUTH_INVALID，界面一律说「请更新 API Key」——403 换 Key 没有用。
    // 2026-09-17 加了 MODEL_FREE_TIER_RESTRICTED：免费模型只许在服务商自家客户端里用，
    // 原来被说成「账号没开通这个模型」。
    XCTAssertEqual(V02ErrorCatalog.allStableCodes.count, 29)

    for code in V02ErrorCatalog.allStableCodes {
      let presentation = V02ErrorCatalog.presentation(for: code)
      XCTAssertFalse(presentation.message.isEmpty, "Missing message for \(code)")
      XCTAssertFalse(presentation.recoveryAction.isEmpty, "Missing recovery for \(code)")
      XCTAssertFalse(presentation.visibleText.contains(code), "Internal code leaked for \(code)")
    }
  }

  func testCriticalProviderFailuresGiveRequiredRecoveryActions() {
    // 文案去工程化后「API Key」统一叫「密钥」；要守的不变量没变——401 的出路
    // 就是换一把密钥，这句话必须明确说出来。
    let auth = V02ErrorCatalog.presentation(for: ModelProviderErrorCode.authInvalid.rawValue)
    XCTAssertTrue(auth.recoveryAction.contains("更新密钥"))
    XCTAssertFalse(auth.visibleText.contains("API Key"), "用户文案里不该再出现工程词「API Key」")

    let rateLimit = V02ErrorCatalog.presentation(for: ModelProviderErrorCode.rateLimited.rawValue)
    XCTAssertTrue(rateLimit.recoveryAction.contains("稍后重试或更换模型服务"))

    let unavailable = V02ErrorCatalog.presentation(
      for: ModelProviderErrorCode.providerUnavailable.rawValue
    )
    // 「Provider」是工程词，界面统一说「模型服务」。
    XCTAssertTrue(unavailable.message.contains("模型服务暂时用不了"))
    XCTAssertFalse(unavailable.visibleText.contains("Provider"))
    XCTAssertTrue(unavailable.recoveryAction.contains("稍后重试"))

    // 协议对不上时，用户唯一能动的就是服务地址——这句必须把人指回那一项，
    // 但不再用「Base URL / OpenAI-compatible API root」这种只有开发者懂的说法。
    let protocolFailure = V02ErrorCatalog.presentation(
      for: ModelProviderErrorCode.protocolIncompatible.rawValue
    )
    XCTAssertTrue(protocolFailure.recoveryAction.contains("服务地址"))
    XCTAssertFalse(protocolFailure.visibleText.contains("Base URL"))
    XCTAssertFalse(protocolFailure.visibleText.contains("OpenAI-compatible"))

    let billing = V02ErrorCatalog.presentation(for: ModelProviderErrorCode.providerBillingLimited.rawValue)
    XCTAssertTrue(billing.message.contains("计费或配额限制"))
    XCTAssertTrue(billing.recoveryAction.contains("服务商控制台"))
    XCTAssertFalse(billing.visibleText.contains("quota denied"))
  }

  /// 每条错误都必须给一个动作，而且不能把工程词丢给用户。
  ///
  /// 这两条以前靠人工把关：改文案时很容易写出「操作未完成，请重试」这种没有出路的
  /// 句子，或者顺手把内部名词抄进去。都不报错，所以钉住。
  func testEveryVisibleErrorIsPlainSpokenAndOffersAnAction() {
    let jargon = ["Base URL", "API Key", "Provider", "manifest", "schema", "SQLite", "WAL", "vacuum", "reasoning_effort"]
    for code in V02ErrorCatalog.allStableCodes {
      let presentation = V02ErrorCatalog.presentation(for: code)
      for word in jargon {
        XCTAssertFalse(
          presentation.visibleText.contains(word),
          "\(code) 的用户文案里还留着工程词「\(word)」")
      }
      XCTAssertTrue(
        presentation.recoveryAction.contains("请"),
        "\(code) 的文案没有给出任何动作")
    }
  }

  func testUnknownInputNeverEchoesCodeBodyHeaderSecretOrPrivateURL() {
    let sentinel = "sentinel-\(UUID().uuidString)"
    let privateURL = "https://private.example.test/account?token=\(sentinel)"
    let untrustedInputs = [
      "MODEL_VENDOR_PRIVATE_FAILURE",
      "provider raw body: {\"error\":\"\(sentinel)\"}",
      "Authorization: Bearer \(sentinel)",
      "X-Provider-Trace: \(sentinel)",
      privateURL
    ]

    // 兜底文案本身是会改的用户文案，不在这里钉死；这里守的是「不管喂进来什么，
    // 出去的都是同一段固定的话」——输入一个字符也不能被回显。
    let fallback = V02ErrorCatalog.presentation(for: "unknown-input").visibleText

    for rawInput in untrustedInputs {
      let presentation = V02ErrorCatalog.presentation(for: rawInput)

      XCTAssertEqual(presentation.visibleText, fallback)
      XCTAssertFalse(presentation.visibleText.contains(rawInput))
      XCTAssertFalse(presentation.visibleText.contains(sentinel))
      XCTAssertFalse(presentation.visibleText.contains("Authorization"))
      XCTAssertFalse(presentation.visibleText.contains("X-Provider-Trace"))
      XCTAssertFalse(presentation.visibleText.contains("provider raw body"))
      XCTAssertFalse(presentation.visibleText.contains(privateURL))
    }
  }
}
