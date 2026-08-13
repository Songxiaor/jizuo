import LinkDigestCore
import SwiftUI

/// 学习批注卡：摘录清单 + 我的笔记。位于标签编辑器上方——
/// 用户思考的优先级高于分类整理。
struct AnnotationSectionView: View {
  @Environment(\.appTheme) private var appTheme
  let taskID: TaskID
  @ObservedObject var model: HistoryViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.taskExcerpts.isEmpty {
        Text("摘录").font(.headline)
        ForEach(model.taskExcerpts) { excerpt in
          HStack(alignment: .top, spacing: 8) {
            Rectangle()
              .fill(Color.accentColor.opacity(0.6))
              .frame(width: 3)
              .clipShape(Capsule())
            Text(excerpt.excerpt)
              .font(.callout)
              .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
              model.deleteExcerpt(excerpt)
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("删除这条摘录")
            .accessibilityLabel("删除这条摘录")
          }
          .padding(10)
          .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
          .accessibilityIdentifier("annotation-excerpt-row")
        }
      }
      Text("我的笔记").font(.headline)
      TextEditor(text: $model.taskNoteDraft)
        .font(.callout)
        .frame(minHeight: 72, maxHeight: 180)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .onChange(of: model.taskNoteDraft) { _, _ in
          model.scheduleNoteSave(taskID: taskID)
        }
        .accessibilityIdentifier("annotation-note-editor")
      Text("阅读时选中文字，右键「添加到摘录」即可收集；笔记自动保存。")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      // 「自动保存」这句承诺必须有对应的失败出口，否则存储出问题时用户毫无察觉
      // 地丢掉整段笔记。这条路径原来全是 `try?`。
      if let failure = model.annotationFailureMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(appTheme.warning)
          Text(failure)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("知道了") { model.annotationFailureMessage = nil }
            .buttonStyle(.link)
            .font(.caption2)
        }
        .accessibilityIdentifier("annotation-failure-banner")
      }
    }
    // 摘录路由跟随当前详情条目；离开时清空，避免误挂到旧条目。
    .onAppear { ExcerptCaptureRouter.shared.handler = { model.addExcerpt($0, taskID: taskID) } }
    .onChange(of: taskID) { _, newTaskID in
      ExcerptCaptureRouter.shared.handler = { model.addExcerpt($0, taskID: newTaskID) }
    }
    .onDisappear { ExcerptCaptureRouter.shared.handler = nil }
    .accessibilityIdentifier("annotation-section")
  }
}
