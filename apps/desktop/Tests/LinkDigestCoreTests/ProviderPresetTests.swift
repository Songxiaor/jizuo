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

  func testOnlineTranscriptionRecommendationsAreLimitedToDocumentedCompatiblePresets() {
    XCTAssertEqual(ProviderPreset.groq.recommendedTranscriptionModel, "whisper-large-v3-turbo")
    XCTAssertTrue(ProviderPreset.groq.supportsOnlineTranscription)
    XCTAssertTrue(ProviderPreset.openAI.supportsOnlineTranscription)
    XCTAssertNil(ProviderPreset.deepSeek.recommendedTranscriptionModel)
  }
}
