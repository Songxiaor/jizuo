import LinkDigestCore
import SwiftUI

/// 独立的笔记写作窗口。
///
/// 为什么不复用主窗口的详情页：写东西和找资料是两种心智。三栏布局里左边是导航、
/// 中间是列表，正文只占右边一条——那个版式为「快速扫过很多条」优化，而写作要的是
/// 一整片安静的空白。独立窗口还能和主窗口并排：一边看素材，一边写。
///
/// 它只做一件事：标题 + 正文。搜索、标签、翻译这些仍在主窗口，因为写的时候不需要。
struct NoteEditorWindow: View {
  /// 打开哪条笔记。nil 表示这次是「新建」。
  let taskID: TaskID?
  @ObservedObject var model: NoteEditorModel

  @Environment(\.dismiss) private var dismiss
  // 沿用阅读区的字体与字号偏好：改一次设置，看和写用的是同一套排版。
  @AppStorage(ReadingFontSelection.storageKey) private var readingFontRaw = ""
  @AppStorage(ReadingFontSize.storageKey) private var readingFontSizeRaw = Double(ReadingFontSize.default)
  @FocusState private var isBodyFocused: Bool

  private var readingFont: ResolvedReadingFont {
    ReadingFontSelection(storedValue: readingFontRaw).resolved(
      usesEditorialReadingTypography: false,
      bodySize: ReadingFontSize.clamped(CGFloat(readingFontSizeRaw))
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("标题", text: $model.title)
        .textFieldStyle(.plain)
        .font(.system(size: 22, weight: .semibold))
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 10)
        .accessibilityIdentifier("note-editor-title")

      Divider().padding(.horizontal, 28)

      TextEditor(text: $model.body)
        .font(readingFont.body())
        .lineSpacing(7)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .focused($isBodyFocused)
        .accessibilityIdentifier("note-editor-body")

      HStack(spacing: 10) {
        // 自动保存的产品承诺必须写出来。没有「保存」按钮时，用户不知道东西存没存，
        // 关窗口前会犹豫——那点犹豫足以让人不敢用它记东西。
        Text(model.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("note-editor-status")
        Spacer(minLength: 0)
        Text("\(model.body.count) 字")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 520, minHeight: 420)
    .task(id: taskID) {
      await model.load(taskID: taskID)
      // 新建时直接把光标放进正文：打开窗口就是为了写，不该还要先点一下。
      isBodyFocused = taskID == nil
    }
    .onDisappear { model.flushPendingSave() }
  }
}

/// 笔记窗口的标识。集中一处，避免打开与声明两侧写成不同的字符串——
/// 那种错误不会编译失败，只会表现为「点了没反应」。
enum NoteEditorWindowID {
  static let value = "note-editor"
  /// 「新建」用的 value。SwiftUI 的 `WindowGroup(id:for:)` 要求打开时必须给出
  /// 一个值，所以用空串表达「这次没有既有笔记」，而不是 nil。
  static let newNote = ""
}
