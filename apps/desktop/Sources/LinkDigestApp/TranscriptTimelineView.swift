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

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
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
                  .fill(accentColor.opacity(hoveredIndex == index ? 0.16 : 0.08))
              )
          }
          .buttonStyle(.plain)
          .help("跳到 \(paragraph.startLabel)")
          .accessibilityLabel("跳到 \(paragraph.startLabel)")
          .accessibilityIdentifier("transcript-seek-\(index)")
          .onHover { hovering in
            withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
              hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
            }
          }
          // 时间戳和第一行文字对齐：按钮比正文矮，不补这一点会显得吊在半空。
          .padding(.top, 2)

          // 走阅读区同一套字体解析：转写稿和正文必须是同一种排版，否则同一页
          // 里两块文字长得不一样。
          Text(paragraph.text)
            .font(readingFont.scaled(designSize: MarkdownPresentation.bodyFontSize))
            .lineSpacing(MarkdownPresentation.bodyLineSpacing)
            .foregroundStyle(primaryTextColor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityIdentifier("transcript-timeline")
  }
}
