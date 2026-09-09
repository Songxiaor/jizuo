import XCTest
@testable import LinkDigestCore

final class ProviderPresetTests: XCTestCase {
  func testEveryNonCustomPresetHasHTTPSOrExplicitLoopbackBaseURLAndLocalIconMark() {
    for preset in ProviderPreset.allCases {
      XCTAssertFalse(preset.iconMark.isEmpty)
      if preset == .custom { continue }
      let url = URL(string: preset.baseURLTemplate)
      XCTAssertNotNil(url)
      XCTAssertTrue(url?.scheme == "https" || (url?.scheme == "http" && url?.host == "127.0.0.1"))
    }
  }

  func testCommandCodePresetUsesSubscriptionCompatibleRootAndDocumentsEligibility() {
    let preset = ProviderPreset.commandCode
    XCTAssertEqual(preset.displayName, "Command Code")
    XCTAssertEqual(preset.baseURLTemplate, "https://api.commandcode.ai/provider/v1")
    XCTAssertEqual(preset.recommendedChatModel, "deepseek/deepseek-v4-flash")
    XCTAssertFalse(preset.supportsOnlineTranscription)
    XCTAssertNil(preset.recommendedTranscriptionModel)
    XCTAssertTrue(preset.documentationHint.contains("Go 套餐不支持 API"))
    XCTAssertTrue(preset.documentationHint.contains("套餐额度"))
    XCTAssertNotEqual(preset, .openCodeGo)
  }

  func testOnlineTranscriptionRecommendationsAreLimitedToDocumentedCompatiblePresets() {
    XCTAssertEqual(ProviderPreset.groq.recommendedTranscriptionModel, "whisper-large-v3-turbo")
    XCTAssertTrue(ProviderPreset.groq.supportsOnlineTranscription)
    XCTAssertTrue(ProviderPreset.openAI.supportsOnlineTranscription)
    XCTAssertNil(ProviderPreset.deepSeek.recommendedTranscriptionModel)
  }
}
