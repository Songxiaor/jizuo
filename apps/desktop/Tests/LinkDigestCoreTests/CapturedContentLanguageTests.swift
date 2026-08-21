import XCTest
@testable import LinkDigestCore

final class CapturedContentLanguageTests: XCTestCase {
  func testDetectsOnlyClearDominantScriptsAndMatchesOutputLanguage() {
    let chinese = String(repeating: "这是中文正文。", count: 4)
    XCTAssertEqual(CapturedContentLanguage.detect(in: chinese), .chinese)
    XCTAssertTrue(CapturedContentLanguage.isSameOutputLanguage(content: chinese, outputLanguage: "简体中文"))
    XCTAssertFalse(CapturedContentLanguage.isSameOutputLanguage(content: chinese, outputLanguage: "English"))

    XCTAssertEqual(CapturedContentLanguage.detect(in: String(repeating: "This is English prose. ", count: 3)), .latin)
    XCTAssertNil(CapturedContentLanguage.detect(in: "短文本"), "ambiguous short text must stay translatable")
  }

  func testMixedTiedMinorKanaAndUnknownScriptsRemainAmbiguous() {
    let closeMixed = String(repeating: "中", count: 24) + String(repeating: "a", count: 20)
    XCTAssertNil(CapturedContentLanguage.detect(in: closeMixed), "close mixed scripts are not a unique language")

    let tiedScripts = String(repeating: "中", count: 16) + String(repeating: "a", count: 16)
    XCTAssertNil(CapturedContentLanguage.detect(in: tiedScripts), "tied scripts are not a unique language")

    let latinWithMinorKana = String(repeating: "a", count: 48) + "かな"
    XCTAssertNil(CapturedContentLanguage.detect(in: latinWithMinorKana), "a small kana fragment must not classify the whole document as Japanese")

    XCTAssertNil(CapturedContentLanguage.detect(in: String(repeating: "مرحبا", count: 8)), "unknown scripts must stay translatable")
  }

  func testUnknownAlphabeticScriptsCompeteWithLatinMarkers() {
    let latinMarker = "OpenAIBrandURL"
    let fixtures = [
      String(repeating: "مرحبا", count: 20) + latinMarker,
      String(repeating: "Привет", count: 20) + latinMarker,
      String(repeating: "नमस्ते", count: 20) + latinMarker
    ]

    for fixture in fixtures {
      XCTAssertNil(CapturedContentLanguage.detect(in: fixture))
      XCTAssertFalse(CapturedContentLanguage.isSameOutputLanguage(content: fixture, outputLanguage: "English"))
    }
  }

  func testSpeechLocaleFollowsCaptionLanguageNotOutputLanguage() {
    let english = String(repeating: "Instead of watching Netflix tonight, watch this Stanford lecture. ", count: 2)
    XCTAssertEqual(CapturedContentLanguage.speechLocaleIdentifier(in: english), "en_US")
    XCTAssertEqual(CapturedContentLanguage.speechLanguageCode(forLocaleIdentifier: "en_US"), "en")

    let chinese = String(repeating: "这是一段中文配文。", count: 4)
    XCTAssertEqual(CapturedContentLanguage.speechLocaleIdentifier(in: chinese), "zh_CN")
    XCTAssertEqual(CapturedContentLanguage.speechLanguageCode(forLocaleIdentifier: "zh_CN"), "zh")
  }

  func testSpeechLocaleUsesMajorityScriptWhenDetectIsAmbiguous() {
    let latinHeavy = String(repeating: "a", count: 20) + String(repeating: "中", count: 12)
    XCTAssertNil(CapturedContentLanguage.detect(in: latinHeavy))
    XCTAssertEqual(CapturedContentLanguage.speechLocaleIdentifier(in: latinHeavy), "en_US")
  }
}
