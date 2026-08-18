import XCTest
@testable import LinkDigestApp
import LinkDigestCore

/// 语言判定缓存的单元测试。
///
/// 缓存是 @MainActor 静态枚举，测试也要钉在主线程，否则隔离检查直接不编译。
@MainActor
final class TranslationMatchCacheTests: XCTestCase {
  /// 每段正文都要带足 12 个以上汉字，`CapturedContentLanguage.detect` 才会
  /// 判定为中文；再带几句英文兜底，验证拉丁文路径也一样走缓存。
  private func chineseText(_ n: Int) -> String {
    "这是第\(n)段中文测试正文，用来验证语言判定缓存在超过容量之后依然返回正确结果，不因条目被淘汰而给出错误答案。"
  }

  // 同一输入重复调用必须给出同一个结果（缓存命中续命不改变返回值）。
  func testSameInputReturnsConsistentResult() {
    let text = chineseText(1)
    let first = TranslationMatchCache.isMatch(text: text, outputLanguage: "中文")
    let second = TranslationMatchCache.isMatch(text: text, outputLanguage: "中文")
    XCTAssertEqual(first, second)
    XCTAssertTrue(first)
  }

  // 不同输出语言要各自拿到正确结果：同一篇中文正文，中文输出命中、英文输出不命中；
  // 拉丁文正文反过来。
  func testDifferentOutputLanguagesGetDistinctResults() {
    let chinese = chineseText(2)
    XCTAssertTrue(TranslationMatchCache.isMatch(text: chinese, outputLanguage: "中文"))
    XCTAssertFalse(TranslationMatchCache.isMatch(text: chinese, outputLanguage: "english"))

    let latin = "This is a deliberately long English paragraph used to verify that the latin script detection path returns the correct result through the cache."
    XCTAssertTrue(TranslationMatchCache.isMatch(text: latin, outputLanguage: "english"))
    XCTAssertFalse(TranslationMatchCache.isMatch(text: latin, outputLanguage: "中文"))
  }

  // 塞进远超容量的不同键，强制 LRU 淘汰；被淘汰的键再查必须靠重算拿到正确值，
  // 不能因为缓存里没命中就返回错值。
  func testResultsStayCorrectAfterCapacityEviction() {
    for i in 0..<24 {
      XCTAssertTrue(
        TranslationMatchCache.isMatch(text: chineseText(i), outputLanguage: "中文"),
        "第\(i)段中文正文对中文输出应当命中"
      )
      XCTAssertFalse(
        TranslationMatchCache.isMatch(text: chineseText(i), outputLanguage: "english"),
        "第\(i)段中文正文对英文输出不应命中"
      )
    }
    // 最早插入的键已经被顶出缓存，重查走重算路径。
    XCTAssertTrue(TranslationMatchCache.isMatch(text: chineseText(0), outputLanguage: "中文"))
    XCTAssertFalse(TranslationMatchCache.isMatch(text: chineseText(0), outputLanguage: "english"))
    // 最近插入的键仍在缓存里，重查走命中路径。
    XCTAssertTrue(TranslationMatchCache.isMatch(text: chineseText(23), outputLanguage: "中文"))
    XCTAssertFalse(TranslationMatchCache.isMatch(text: chineseText(23), outputLanguage: "english"))
  }
}
