import LinkDigestCore
import SwiftUI

/// 带时间锚点的转写稿。
///
/// 只在**识别器直接产出的那份**正文上出现：它的文字和时间是同一次识别的产物。
/// 模型整理稿、用户手改稿都拿不到分段（写入时已作废），会照常走普通 Markdown
/// 阅读区——宁可没有锚点，也不要点了跳错地方。
///
/// 不复用 `MarkdownContentView`：转写稿没有标题、表格、代码，它就是一串段落。
/// 为了挂锚点把块模型再改一轮，代价远大于收益。
struct TranscriptTimelineView: View {
  let paragraphs: [TranscriptParagraph]
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let accentColor: Color
  let onSeek: (Int) -> Void

  var body: some View {
    // 一小时音频有上千段：LazyVStack 只排可见的；悬停高亮下沉到每一行自己的
    // 状态，鼠标扫过时间码不再让整份转写稿重排。
    LazyVStack(alignment: .leading, spacing: 18) {
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
        TranscriptTimelineRow(
          index: index,
          paragraph: paragraph,
          readingFont: readingFont,
          primaryTextColor: primaryTextColor,
          accentColor: accentColor,
          onSeek: onSeek
        )
      }
    }
    .accessibilityIdentifier("transcript-timeline")
  }
}

private struct TranscriptTimelineRow: View {
  let index: Int
  let paragraph: TranscriptParagraph
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let accentColor: Color
  let onSeek: (Int) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button {
        onSeek(paragraph.startMilliseconds)
      } label: {
        Text(paragraph.startLabel)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(accentColor)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .fill(accentColor.opacity(isHovered ? 0.16 : 0.08))
          )
      }
      .buttonStyle(.plain)
      .help("跳到 \(paragraph.startLabel)")
      .accessibilityLabel("跳到 \(paragraph.startLabel)")
      .accessibilityIdentifier("transcript-seek-\(index)")
      .onHover { hovering in
        withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isHovered = hovering }
      }
      // 时间戳和第一行文字对齐：按钮比正文矮，不补这一点会显得吊在半空。
      .padding(.top, 2)

      // 走阅读区同一套字体解析：转写稿和正文必须是同一种排版，否则同一页
      // 里两块文字长得不一样。
      Text(paragraph.text)
        // 用正文字号本身：原来按旧的 16.5 设计字号缩放，正文改成 15 后转写稿
        // 反而比文章大一号（2026-09-23 实测）。
        .font(readingFont.body())
        .lineSpacing(MarkdownPresentation.bodyLineSpacing)
        .foregroundStyle(primaryTextColor)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// 分过说话人的转写稿（2026-09-24）：会议纪要的排法。
///
/// 每一轮发言上面一行小字写「谁 · 几分几秒」，下面是说的话；正文和文章正文同一套字体字号。
/// 原来把 `**说话人 1**：` 粗体塞在句首，名字和正文抢同一行，换人处全靠粗体认，读起来像一堆标签。
struct SpeakerTranscriptView: View {
  let turns: [SpeakerTurn]
  let readingFont: ResolvedReadingFont
  let primaryTextColor: Color
  let secondaryTextColor: Color
  let accentColor: Color
  let showsTimecodes: Bool
  let onSeek: (Double) -> Void

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 20) {
      ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
        VStack(alignment: .leading, spacing: 4) {
          if turn.speaker != nil || (showsTimecodes && turn.startSeconds != nil) {
            HStack(spacing: 8) {
              if let speaker = turn.speaker {
                Text(speaker)
                  .font(readingFont.font(size: readingFont.bodySize - 2, weight: .semibold))
                  .foregroundStyle(secondaryTextColor)
              }
              if showsTimecodes, let label = turn.startLabel, let seconds = turn.startSeconds {
                Button { onSeek(seconds) } label: {
                  Text(label)
                    .font(readingFont.font(size: readingFont.bodySize - 3))
                    .monospacedDigit()
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .help("跳到 \(label)")
                .accessibilityLabel("跳到 \(label)")
                .accessibilityIdentifier("speaker-turn-seek-\(index)")
              }
            }
          }
          ForEach(Array(turn.paragraphs.enumerated()), id: \.offset) { _, paragraph in
            Text(paragraph)
              .font(readingFont.body())
              .lineSpacing(MarkdownPresentation.bodyLineSpacing)
              .foregroundStyle(primaryTextColor)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .accessibilityIdentifier("speaker-transcript")
  }
}
