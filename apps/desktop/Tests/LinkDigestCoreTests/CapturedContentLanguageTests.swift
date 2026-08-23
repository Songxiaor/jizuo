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

/// 听写语种探测的判据。fixture 是真机实测的输出片段，不是构造的——
/// 同一段斯坦福英文讲座喂给两个 locale，坏法长得完全不一样。
final class SpeechLocalePlausibilityTests: XCTestCase {
  /// 指错 locale 的两种坏法都要判出来。
  func testRejectsBothFailureModesOfAMismatchedLocale() {
    // 英文音频 + zh_CN：吐拉丁碎片。长度正常，只有文字种类暴露了它。
    let latinGibberish = "about carer avisont AI. and in peovisers ae us to do most this yellecture by myself"
    XCTAssertFalse(CapturedContentLanguage.isPlausibleTranscript(latinGibberish, forLocaleIdentifier: "zh_CN"))

    // 中文音频 + en_US：直接吐空。
    XCTAssertFalse(CapturedContentLanguage.isPlausibleTranscript("", forLocaleIdentifier: "en_US"))
    XCTAssertFalse(CapturedContentLanguage.isPlausibleTranscript("   \n  ", forLocaleIdentifier: "en_US"))
  }

  /// 选对 locale 的输出必须放行，否则探测会把正确答案也淘汰掉。
  func testAcceptsMatchingLocaleOutput() {
    let english = "About career advice in AI. And in previous years I used to do most of this lecture by myself."
    XCTAssertTrue(CapturedContentLanguage.isPlausibleTranscript(english, forLocaleIdentifier: "en_US"))

    let chinese = "我用它搭建了六个团队，快速启动了一人公司，评论区问我最多的一个问题是这个。"
    XCTAssertTrue(CapturedContentLanguage.isPlausibleTranscript(chinese, forLocaleIdentifier: "zh_CN"))
  }

  /// 判不出主体文字时放行。中英夹杂的技术口播是常态，误杀正确 locale
  /// 的代价比放过一个错的大。
  func testAmbiguousMixedOutputIsNotRejected() {
    let mixed = String(repeating: "中", count: 20) + String(repeating: "a", count: 18)
    XCTAssertNil(CapturedContentLanguage.detect(in: mixed), "fixture 前提：这段本就判不出主体")
    XCTAssertTrue(CapturedContentLanguage.isPlausibleTranscript(mixed, forLocaleIdentifier: "zh_CN"))
    XCTAssertTrue(CapturedContentLanguage.isPlausibleTranscript(mixed, forLocaleIdentifier: "en_US"))
  }

  /// 不认识的 locale 不拦——探测只在它有把握时否决。
  func testUnknownLocaleIsNeverRejectedOnScript() {
    let arabic = String(repeating: "مرحبا", count: 8)
    XCTAssertNil(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "ar_SA"))
    XCTAssertTrue(CapturedContentLanguage.isPlausibleTranscript(arabic, forLocaleIdentifier: "ar_SA"))
  }

  func testLocaleExpectationsCoverTheSupportedSpeechLocales() {
    XCTAssertEqual(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "zh_CN"), .chinese)
    XCTAssertEqual(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "en_US"), .latin)
    XCTAssertEqual(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "ja_JP"), .japanese)
    XCTAssertEqual(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "ko_KR"), .korean)
    // 连字符写法和大小写不能改变判断。
    XCTAssertEqual(CapturedContentLanguage.expectedScript(forLocaleIdentifier: "en-GB"), .latin)
  }
}
