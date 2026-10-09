import LinkDigestCore
import SwiftUI

/// 转写稿三种排法（逐字稿、分说话人、校对稿）共用的页边尺寸（2026-10-06 排版对齐）。
///
/// 原来三处各写各的：时间码栏 44pt、间距 12 或 14、正文缩进 58，三种稿子的正文差几个点
/// 对不齐；44pt 也放不下超过一小时的 `1:09:34`（等宽 11 号约 46pt），会折成两行。
/// 时间码从页签那条线起排（左对齐），正文统一缩进 `textInset`。
enum TranscriptGutter {
  /// 放得下 `1:09:34`，再留几个点余量。
  static let timecodeWidth: CGFloat = 50
  static let spacing: CGFloat = 12
  /// 正文栏离页签那条线的距离：时间码栏 + 间距。
  static var textInset: CGFloat { timecodeWidth + spacing }
  /// 段和段之间：明显大于行距（7），一眼分得出段落。
  static let paragraphSpacing: CGFloat = 18
  /// 换人（分说话人的一轮发言）比换段再多空一截。
  static let turnSpacing: CGFloat = 30
  static let timecodeFont = Font.system(size: 11, weight: .regular, design: .monospaced)
}

/// 带时间锚点的转写稿。
///
/// 只在**识别器直接产出的那份**正文上出现：它的文字和时间是同一次识别的产物。
/// 模型整理稿、用户手改稿都拿不到分段（写入时已作废），会照常走普通 Markdown
/// 阅读区——宁可没有锚点，也不要点了跳错地方。
///
/// 正文排进一块原生文字（见 `TranscriptTextBlock`），不再一段一个 SwiftUI 视图。
struct TranscriptTimelineView: View {
  let paragraphs: [TranscriptParagraph]
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let accentColor: Color
  let onSeek: (Int) -> Void

  var body: some View {
    TranscriptTextBlock(
      lines: paragraphs.map {
        TranscriptTextLine(
          kind: .body, stamp: $0.startLabel, seekSeconds: Double($0.startMilliseconds) / 1000, text: $0.text
        )
      },
      style: TranscriptTextStyle(
        readingFont: readingFont,
        primaryText: NSColor(primaryTextColor),
        secondaryText: NSColor(secondaryTextColor),
        showsTimecodes: true
      ),
      onSeek: { seconds in onSeek(Int((seconds * 1000).rounded())) },
      identifier: "transcript-timeline"
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 分过说话人的转写稿（2026-09-24）：会议纪要的排法。
///
/// 每一轮发言上面一行小字写名字（页边挂这一轮的时间码），下面是说的话；同一个人连着说的
/// 每一段也挂自己的时间码（2026-10-04 走查）。正文和文章正文同一套字体字号。
struct SpeakerTranscriptView: View {
  let turns: [SpeakerTurn]
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let accentColor: Color
  let showsTimecodes: Bool
  let onSeek: (Double) -> Void

  var body: some View {
    TranscriptTextBlock(
      lines: Self.lines(turns),
      style: TranscriptTextStyle(
        readingFont: readingFont,
        primaryText: NSColor(primaryTextColor),
        secondaryText: NSColor(secondaryTextColor),
        showsTimecodes: showsTimecodes
      ),
      onSeek: onSeek,
      identifier: "speaker-transcript"
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func lines(_ turns: [SpeakerTurn]) -> [TranscriptTextLine] {
    var lines: [TranscriptTextLine] = []
    for turn in turns {
      for (index, paragraph) in turn.paragraphs.enumerated() {
        let label = turn.startLabel(ofParagraph: index)
        let seconds = label.flatMap(SpeakerTurn.seconds(of:))
        if index == 0, let speaker = turn.speaker {
          // 名字一行挂这一轮的时间码；名字和第一段之间只空一点。
          lines.append(TranscriptTextLine(
            kind: .speaker, stamp: label, seekSeconds: seconds, text: speaker,
            spacingBefore: TranscriptGutter.turnSpacing
          ))
          lines.append(TranscriptTextLine(kind: .body, stamp: nil, seekSeconds: nil, text: paragraph, spacingBefore: 4))
        } else {
          lines.append(TranscriptTextLine(
            kind: .body, stamp: label, seekSeconds: seconds, text: paragraph,
            spacingBefore: index == 0 ? TranscriptGutter.turnSpacing : TranscriptGutter.paragraphSpacing
          ))
        }
      }
    }
    return lines
  }
}
