import XCTest
@testable import LinkDigestCore

/// 整理稿的时间锚点迁移。
///
/// 整理会重新划分段落，所以不能按序号一一对应。这一组钉住前缀锚定的行为，
/// 尤其是**什么时候必须放弃迁移**——一份跳错地方的时间比没有时间更糟。
final class TranscriptParagraphMigrationTests: XCTestCase {
  private func paragraph(_ start: Int, _ end: Int, _ text: String) -> TranscriptParagraph {
    TranscriptParagraph(startMilliseconds: start, endMilliseconds: end, text: text)
  }

  private let original = [
    TranscriptParagraph(startMilliseconds: 0, endMilliseconds: 5_000, text: "大家好我是瓜哥今天讲一个开源项目"),
    TranscriptParagraph(startMilliseconds: 5_000, endMilliseconds: 12_000, text: "这个项目叫做herdr在GitHub上已经有两万八千星"),
    TranscriptParagraph(startMilliseconds: 12_000, endMilliseconds: 20_000, text: "我上官网看了下核心能力赶紧上手安装实战"),
  ]

  /// 只改标点、段落照旧：每段都该拿到自己的时间。
  func testPunctuationOnlyEditsKeepEveryAnchor() {
    let tidied = """
      大家好，我是瓜哥，今天讲一个开源项目。

      这个项目叫做 herdr，在 GitHub 上已经有两万八千星。

      我上官网看了下核心能力，赶紧上手安装实战。
      """
    let migrated = TranscriptParagraphMigration.migrated(original, toTidiedBody: tidied)
    XCTAssertEqual(migrated?.map(\.startMilliseconds), [0, 5_000, 12_000])
  }

  /// 重新分段：合并了前两段，新段落的时间应当取它开头所在的那一原段。
  func testMergedParagraphsTakeTheTimeOfTheirOpening() {
    let tidied = """
      大家好，我是瓜哥，今天讲一个开源项目。这个项目叫做 herdr，在 GitHub 上已经有两万八千星。

      我上官网看了下核心能力，赶紧上手安装实战。
      """
    let migrated = TranscriptParagraphMigration.migrated(original, toTidiedBody: tidied)
    XCTAssertEqual(migrated?.count, 2)
    XCTAssertEqual(migrated?[0].startMilliseconds, 0)
    XCTAssertEqual(migrated?[1].startMilliseconds, 12_000)
  }

  /// 拆分：后半段应当落在它实际所属的那一原段，而不是继承前半段。
  func testSplitParagraphAnchorsToWhereItActuallyStarts() {
    let tidied = """
      大家好，我是瓜哥。

      今天讲一个开源项目。

      这个项目叫做 herdr，在 GitHub 上已经有两万八千星。

      我上官网看了下核心能力，赶紧上手安装实战。
      """
    let migrated = TranscriptParagraphMigration.migrated(original, toTidiedBody: tidied)
    XCTAssertEqual(migrated?.count, 4)
    XCTAssertEqual(migrated?[0].startMilliseconds, 0)
    XCTAssertEqual(migrated?[1].startMilliseconds, 0, "仍在第一段之内")
    XCTAssertEqual(migrated?[2].startMilliseconds, 5_000)
    XCTAssertEqual(migrated?[3].startMilliseconds, 12_000)
  }

  /// 小标题不占段落，也不该拿到锚点。
  func testHeadingsAreNotTreatedAsParagraphs() {
    let tidied = """
      ## 开场

      大家好，我是瓜哥，今天讲一个开源项目。

      ## 项目介绍

      这个项目叫做 herdr，在 GitHub 上已经有两万八千星。

      我上官网看了下核心能力，赶紧上手安装实战。
      """
    let migrated = TranscriptParagraphMigration.migrated(original, toTidiedBody: tidied)
    XCTAssertEqual(migrated?.count, 3)
    XCTAssertFalse(migrated?.contains { $0.text.hasPrefix("## ") } ?? true)
    XCTAssertEqual(migrated?.map(\.startMilliseconds), [0, 5_000, 12_000])
  }

  /// **整批放弃**：模型把内容重写了，一条锚点都不可信。
  ///
  /// 这一条是整个迁移的安全阀。命中率不足时返回 nil，界面退回没有锚点的整理稿，
  /// 而不是给出一份点了就跳错地方的时间。
  func testHeavyRewriteIsRejectedEntirely() {
    let rewritten = """
      本视频介绍了一款开源工具。

      作者对其评价很高。

      建议读者自行尝试。
      """
    XCTAssertNil(TranscriptParagraphMigration.migrated(original, toTidiedBody: rewritten))
  }

  func testEmptyInputsAreRejected() {
    XCTAssertNil(TranscriptParagraphMigration.migrated([], toTidiedBody: "有正文"))
    XCTAssertNil(TranscriptParagraphMigration.migrated(original, toTidiedBody: "   "))
    XCTAssertNil(TranscriptParagraphMigration.migrated(original, toTidiedBody: "## 只有标题"))
  }
}
