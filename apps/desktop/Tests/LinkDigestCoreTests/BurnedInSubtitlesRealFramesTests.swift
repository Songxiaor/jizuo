import XCTest
@testable import LinkDigestCore

/// 用**真实视频**的逐帧 OCR 结果做回归。
///
/// 构造数据测不出这三个 bug：它们都来自真实画面里的东西——动画中的标题卡、
/// 字幕切换的那一瞬、以及五个字的短句。夹具是 `Fixtures/*.json`，由抖音视频
/// 实际抽帧 + Vision 识别导出，字段与 `RecognizedTextLine` 一一对应。
final class BurnedInSubtitlesRealFramesTests: XCTestCase {
  private func frames(_ name: String) throws -> [VideoFrameText] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name).json")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
    return raw.map { frame in
      VideoFrameText(
        timeSeconds: frame["timeSeconds"] as! Double,
        lines: (frame["lines"] as! [[String: Any]]).map {
          RecognizedTextLine(
            text: $0["text"] as! String,
            midY: $0["midY"] as! Double,
            minX: $0["minX"] as! Double,
            width: $0["width"] as! Double
          )
        }
      )
    }
  }

  private func composedText(_ name: String) throws -> String {
    BurnedInSubtitles.compose(frames: try frames(name))
      .map(\.text)
      .joined(separator: "\n")
  }

  /// 片头标题卡在动画途中路过字幕带，不能被当成第一句字幕。
  ///
  /// 实测这一帧：标题「应该越用越聪明」滑到 midY=0.284，正落在字幕带内，
  /// 于是字幕稿开头变成「巫该越用越聪明Agent：…」。按 y 分桶的背景剔除抓不到
  /// 它——同一句话在 0.284 和 0.820 属于两个桶。
  func testTitleCardPassingThroughBandIsNotTreatedAsSubtitle() throws {
    let text = try composedText("burned-in-subtitles-agent")
    XCTAssertFalse(
      text.contains("越用越聪明"),
      "片头标题卡混进了字幕稿：\n\(text.prefix(200))"
    )
  }

  /// 单行字幕的切换帧里，下面那句是先说的。
  ///
  /// 这个视频 20 帧里绝大多数只有一行字幕，两行的那几帧都是切换瞬间：新句
  /// 从上方滑入、旧句尚未消失。按「双行、从上往下」拼会把后说的排到前面。
  func testTransitionFrameKeepsSpokenOrder() throws {
    let text = try composedText("burned-in-subtitles-agent")
    guard let early = text.range(of: "我讲一个我觉得接下来"),
          let late = text.range(of: "领域非常重要的概念") else {
      return XCTFail("夹具里两句都该在：\n\(text.prefix(300))")
    }
    XCTAssertTrue(
      early.lowerBound < late.lowerBound,
      "切换帧语序颠倒了——「我讲一个我觉得接下来」应排在「领域非常重要的概念」之前：\n\(text.prefix(300))"
    )
  }

  /// 五个字的短句不能因为窄就被丢掉。
  ///
  /// 实测「已是优质资产」宽度只有 0.210，低于固定门槛 0.25。中文短句极常见，
  /// 一刀切等于每个视频都在静默丢句。
  func testShortSubtitleLineSurvivesWidthFilter() throws {
    let text = try composedText("burned-in-subtitles-shortline")
    XCTAssertTrue(
      text.contains("已是优质资产"),
      "短句被宽度门槛误杀：\n\(text)"
    )
  }


  /// 白板上的板书不能被当成字幕。
  ///
  /// 这条视频里讲者在白板上画「任务→执行→反馈→反思」，它落在 midY≈0.283、
  /// 宽度 0.66，几何上和字幕一模一样，还连着占了 3 帧（t=102/105/108）。
  ///
  /// 光靠「同帧有没有静止位同伴」拦不住它：t=105 那帧静止位上恰好压着一句真
  /// 字幕，同伴判据就放行了。真正的区别是**赖着不走**——切换中的字幕在偏离
  /// 静止位的高度上只闪一帧，板书一动不动待好几帧。
  ///
  /// 计数必须按相似度聚类：OCR 抖动把同一块板书认成「世务一执行一反馈》」
  /// 「世务一执行一反馈一反」「世务一执行一反馈一反忠」，精确比之下每种都只出现
  /// 一次，恰好伪装成「只闪了一帧」的切换残影。
  func testWhiteboardDiagramIsNotTreatedAsSubtitle() throws {
    let text = try composedText("burned-in-subtitles-whiteboard")
    XCTAssertFalse(
      text.contains("执行一反馈") || text.contains("世务"),
      "白板板书混进了字幕稿：\n\(text.prefix(300))"
    )
    // 同一段里的真字幕不能被误删。
    XCTAssertTrue(
      text.contains("但Agent自进化的是不一样啊"),
      "把板书连同真字幕一起删了：\n\(text.prefix(300))"
    )
  }
}
