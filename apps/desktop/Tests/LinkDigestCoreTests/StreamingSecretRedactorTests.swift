import XCTest
@testable import LinkDigestCore

/// 脱敏器改成"只返回本次新增片段"之后，两件事必须盯死：
/// 1. 脱敏语义一个字不变——尤其是密钥被切在两个 delta 中间那种；
/// 2. 长文不再随着长度变慢（原来每个 delta 都要复制一遍整串累积文本）。
final class StreamingSecretRedactorTests: XCTestCase {
  private let secret = "sk-live-9f3a77c1d2e4"

  /// 复刻调用方（ModelRunOrchestrator）的累积方式：独占 buffer 累加增量。
  private func stream(_ deltas: [String], secret: String) -> String {
    var redactor = StreamingSecretRedactor(secret: secret)
    var text = ""
    for delta in deltas { text += redactor.append(delta) }
    text += redactor.finalize()
    return text
  }

  func testSecretSplitAcrossTwoDeltaBoundariesIsStillRedacted() {
    // 模型把密钥切在任意位置都不能漏出去。
    for cut in 1..<secret.count {
      let head = String(secret.prefix(cut))
      let tail = String(secret.dropFirst(cut))
      let text = stream(["前文 ", head, tail, " 后文"], secret: secret)
      XCTAssertEqual(text, "前文 \(StreamingSecretRedactor.mask) 后文", "cut=\(cut)")
      XCTAssertFalse(text.contains(secret), "cut=\(cut)")
    }
  }

  func testSecretSplitAcrossThreeDeltasIsStillRedacted() {
    let a = String(secret.prefix(4))
    let b = String(secret.dropFirst(4).prefix(6))
    let c = String(secret.dropFirst(10))
    XCTAssertEqual(stream([a, b, c], secret: secret), StreamingSecretRedactor.mask)
  }

  func testWholeSecretInsideOneDeltaIsRedactedAndSurroundingTextSurvives() {
    XCTAssertEqual(
      stream(["key=\(secret);done"], secret: secret),
      "key=\(StreamingSecretRedactor.mask);done"
    )
  }

  func testRepeatedSecretOccurrencesAreAllRedacted() {
    let masked = StreamingSecretRedactor.mask
    XCTAssertEqual(
      stream([secret, "-中间-", secret], secret: secret),
      "\(masked)-中间-\(masked)"
    )
  }

  func testTrailingSecretPrefixIsNeverReleasedAsPlainText() {
    // 流断在密钥前缀上：宁可整段打码，也不能把前缀原样放出去。
    let prefix = String(secret.prefix(8))
    let text = stream(["尾巴 ", prefix], secret: secret)
    XCTAssertEqual(text, "尾巴 \(StreamingSecretRedactor.mask)")
    XCTAssertFalse(text.contains(prefix))
  }

  func testIncrementsConcatenateToTheSameTextWithoutASecret() {
    let deltas = (0..<50).map { "段落\($0)。" }
    XCTAssertEqual(stream(deltas, secret: secret), deltas.joined())
    // 空密钥（未配置）时全文原样通过。
    XCTAssertEqual(stream(deltas, secret: ""), deltas.joined())
  }

  func testAppendReturnsOnlyTheNewFragmentNotTheWholeTranscript() {
    var redactor = StreamingSecretRedactor(secret: secret)
    XCTAssertEqual(redactor.append("第一段"), "第一段")
    // 返回值若仍是累积全文，这里会是"第一段第二段"。
    XCTAssertEqual(redactor.append("第二段"), "第二段")
    XCTAssertEqual(redactor.finalize(), "")
  }

  /// 性能守卫：20000 个 delta、累计约 200KB。
  ///
  /// 旧实现在这个量级上是二次方级的字符拷贝；Debug 构建下也应远低于 2 秒。
  func testLongStreamStaysFarBelowTheTwoSecondGuard() {
    let delta = String(repeating: "字", count: 10)
    var redactor = StreamingSecretRedactor(secret: secret)
    var text = ""
    let started = Date()
    for _ in 0..<20_000 { text += redactor.append(delta) }
    text += redactor.finalize()
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertEqual(text.count, 200_000)
    XCTAssertLessThan(elapsed, 2, "20000 个 delta 用了 \(elapsed) 秒")
  }
}
