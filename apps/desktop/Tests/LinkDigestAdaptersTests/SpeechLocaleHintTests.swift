import XCTest
@testable import LinkDigestAdapters

/// 2026-09-24：中文模型听英文讲座吐出拉丁碎片时，探测应指向英文（交给「下载模型」确认），
/// 而不是悄悄退回中文、整篇乱码。
final class SpeechLocaleHintTests: XCTestCase {
  func testLatinFragmentsFromChineseModelPointToEnglish() {
    let sample = "So loatingish models I gus youlways poble of yo have he of this word Latengrish models"
    XCTAssertEqual(
      AppleSpeechVideoTranscriber.installableHint(from: [sample], candidates: ["zh_CN", "en_US"]),
      "en_US"
    )
  }

  func testEmptyOrScriptlessOutputDoesNotRedirect() {
    XCTAssertNil(AppleSpeechVideoTranscriber.installableHint(from: ["", "   "], candidates: ["zh_CN", "en_US"]),
                 "纯音乐、无人声不该把人引去下载模型")
  }

  func testHintOutsideCandidatesIsIgnored() {
    XCTAssertNil(AppleSpeechVideoTranscriber.installableHint(from: ["こんにちは、今日はいい天気ですね、皆さん"], candidates: ["zh_CN", "en_US"]))
  }
}
