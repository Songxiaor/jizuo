import XCTest
@testable import LinkDigestCore

final class TranscriptTidyEditsTests: XCTestCase {
  let chunk = """
  00:00 大家好，今天用3分钟讲讲刁板印刷第一部教写样先把要印的字写在保纸上。

  00:20 在版面上刷一层铺上纸用棕刷轻轻一擦一页就印好了。到了明代书房为了刻得更快这就是送体字。

  00:47 不妨想想当年拿着刻刀的那双手
  """

  func testNumberedMarksEachParagraph() {
    let numbered = TranscriptTidyEdits.numbered(chunk)
    XCTAssertTrue(numbered.hasPrefix("[1] 00:00 大家好"))
    XCTAssertTrue(numbered.contains("\n\n[3] 00:47 不妨想想"))
  }

  func testAppliesReplacementsHeadingsAndSplitsWithoutTouchingTimestamps() {
    let output = """
    改 1 | 讲讲刁板印刷第一部 | 讲讲雕版印刷。第一步
    - 改 1 | 写在保纸上 | 写在薄纸上
    改 2 | 书房为了 | 书坊为了
    改 2 | 这就是送体字 | 这就是宋体字
    题 2 | 从书坊刻字到宋体
    分 2 | 到了明代书坊
    改 3 | 00:47 | 00:48
    改 3 | 根本不存在的话 | 随便
    这一行不是修改
    """
    let edits = TranscriptTidyEdits.parse(output)
    XCTAssertEqual(edits.count, 8)
    let applied = TranscriptTidyEdits.apply(edits, to: chunk)
    XCTAssertEqual(applied.text, """
    00:00 大家好，今天用3分钟讲讲雕版印刷。第一步教写样先把要印的字写在薄纸上。

    ## 从书坊刻字到宋体

    00:20 在版面上刷一层铺上纸用棕刷轻轻一擦一页就印好了。

    到了明代书坊为了刻得更快这就是宋体字。

    00:47 不妨想想当年拿着刻刀的那双手
    """)
    XCTAssertEqual(applied.missed, 2, "改时间码、改不存在的片段都只跳过")
  }

  func testNoChangesKeepsOriginal() {
    XCTAssertTrue(TranscriptTidyEdits.parse("无").isEmpty)
    XCTAssertEqual(TranscriptTidyEdits.apply([], to: chunk).text, TranscriptTidyEdits.paragraphs(of: chunk).joined(separator: "\n\n"))
  }

  /// 清单模式实测在关不掉思考的线路上更慢，目前一律关闭（见 TidyStyle.usesEditList）。
  func testEditListIsOffForEveryStyleForNow() {
    XCTAssertTrue(TidyStyle.allCases.allSatisfy { !$0.usesEditList })
    XCTAssertEqual(TidyStyle.transcript.requestPrompt, TranscriptTidyPrompt.system)
  }

  /// 首段时间码被模型并掉、其余对得上：本机补回；时间码来自别处的照旧不认。
  func testLeadingStampIsRepairedOnlyWhenTheRestBelongs() {
    let chunk = "01:13:18 第一段内容。\n\n01:14:06 第二段内容。"
    let dropped = "第一段内容。\n\n01:14:06 第二段内容。"
    let repaired = TranscriptTidyChunkCheck.repairingLeadingStamp(output: dropped, for: chunk)
    XCTAssertEqual(repaired, "01:13:18 第一段内容。\n\n01:14:06 第二段内容。")
    XCTAssertTrue(TranscriptTidyChunkCheck.belongs(output: repaired, to: chunk))
    let foreign = "02:00:00 别的段。"
    XCTAssertEqual(TranscriptTidyChunkCheck.repairingLeadingStamp(output: foreign, for: chunk), foreign)
  }
}
