import SwiftUI
import LinkDigestCore

/// 标签管理里的「常用标签表」和「AI 整理标签」入口（2026-11 第二批）。
/// 独立成文件，TagManagerView 只挂一行。
struct TagTidySection: View {
  @Bindable var controller: TagTidyController
  @Bindable var frequent: FrequentTagsModel
  var isReadOnly: Bool

  @State private var isListExpanded = false
  @State private var newTagName = ""

  private var document: FrequentTagsDocument { frequent.document }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("常用标签表").themedFont(.subheadline, weight: .medium)
          Text(summaryLine).themedFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(isListExpanded ? "收起" : "查看 / 编辑") { isListExpanded.toggle() }
          .accessibilityIdentifier("tag-manager-frequent-toggle")
        Button("AI 整理标签…") { controller.start() }
          .disabled(isReadOnly || controller.isBusy)
          .help("把标签名和使用次数发给模型，生成合并方案。不发资料正文，确认前不会改动任何东西。")
          .accessibilityIdentifier("tag-manager-ai-tidy")
      }
      if let notice = frequent.corruptNotice {
        HStack(alignment: .top) {
          Text(notice).themedFont(.caption).foregroundStyle(.orange)
          Spacer()
          Button("知道了") { frequent.dismissNotice() }.controlSize(.small)
        }
      }
      if isListExpanded { listEditor }
      if !document.suggestions.isEmpty { suggestionList }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    .accessibilityIdentifier("tag-manager-tidy-section")
    .sheet(isPresented: Binding(
      get: { controller.state != .idle },
      set: { if !$0 { controller.cancel() } }
    )) {
      TagTidySheet(controller: controller)
    }
  }

  private var summaryLine: String {
    document.tags.isEmpty
      ? "还没设置：新内容的标签照旧由模型自由选。设置后只能从表里选，表外的会进「建议加入」。"
      : "共 \(document.tags.count) 个：新内容的标签只从表里选，不会新建。"
  }

  private var listEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView {
        FlowRow(items: document.tags) { name in
          HStack(spacing: 2) {
            Text(name).themedFont(.caption)
            Button { frequent.remove(name) } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("从常用表去掉")
          }
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
      }
      .frame(maxHeight: 110)
      HStack {
        TextField("加一个常用标签", text: $newTagName)
          .textFieldStyle(.roundedBorder)
          .onSubmit(addNew)
        Button("添加", action: addNew).disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("清空（恢复自由打标签）", role: .destructive) { frequent.clearAll() }
          .disabled(document.tags.isEmpty)
      }
    }
  }

  private func addNew() {
    frequent.add(newTagName)
    newTagName = ""
  }

  private var suggestionList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("建议加入（模型想用、但不在表里的标签）").themedFont(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(document.suggestions.sorted { $0.count > $1.count }.prefix(30), id: \.name) { item in
            HStack {
              Text("\(item.name)（提议 \(item.count) 次）").themedFont(.callout).lineLimit(1)
              Spacer()
              Button("加入") { frequent.accept(item.name) }
                .accessibilityIdentifier("tag-manager-suggestion-accept-\(item.name)")
              Button("忽略") { frequent.dismiss(item.name) }
            }
          }
        }
      }
      .frame(maxHeight: 110)
    }
    .accessibilityIdentifier("tag-manager-suggestions")
  }
}

/// 简单的自动换行排布。
private struct FlowRow<Content: View>: View {
  let items: [String]
  @ViewBuilder var content: (String) -> Content

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 4) {
      ForEach(items, id: \.self) { content($0) }
    }
  }
}

/// 整理方案的预览与确认。
struct TagTidySheet: View {
  @Bindable var controller: TagTidyController

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      switch controller.state {
      case .idle:
        EmptyView()
      case let .needsConsent(host, model):
        Text("整理标签会把标签名和使用次数发给模型服务").themedFont(.headline)
        Text("发往：\(host)（模型 \(model)）。只发标签名和次数，不发任何资料正文。会产生一次模型调用费用。")
          .themedFont(.callout).foregroundStyle(.secondary)
        buttons([("取消", .cancel, { controller.cancel() }), ("同意并开始", .confirm, { controller.confirmConsent() })])
      case .working:
        HStack { ProgressView().controlSize(.small); Text("正在分析标签…") }
        buttons([("取消", .cancel, { controller.cancel() })])
      case .applying:
        HStack { ProgressView().controlSize(.small); Text("正在备份并合并，请不要关闭窗口…") }
        buttons([("停止", .cancel, { controller.cancel() })])
      case .preview:
        previewBody
      case let .finished(message):
        Text(message).themedFont(.callout)
        buttons([("完成", .confirm, { controller.dismissResult() })])
      case let .failed(message):
        Text(message).themedFont(.callout)
        buttons([("好", .confirm, { controller.dismissResult() })])
      }
    }
    .padding(DesignTokens.Space.lg)
    .frame(width: 540)
    .frame(minHeight: 160)
  }

  private enum Role { case cancel, confirm }

  private func buttons(_ items: [(String, Role, () -> Void)]) -> some View {
    HStack {
      Spacer()
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        if item.1 == .cancel {
          Button(item.0, action: item.2).keyboardShortcut(.cancelAction)
        } else {
          Button(item.0, action: item.2).keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  @ViewBuilder private var previewBody: some View {
    if let plan = controller.plan {
      Text("整理方案预览").themedFont(.headline)
      Text("还没有改任何东西。取消不想要的组、改合并后的名字，确认后才会执行（执行前自动备份）。")
        .themedFont(.caption).foregroundStyle(.secondary)
      if let tokens = controller.tokenSummary {
        Text(tokens).themedFont(.caption).foregroundStyle(.tertiary)
      }
      if !plan.merges.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.merges) { merge in mergeRow(merge) }
          }
        }
        .frame(maxHeight: 280)
      }
      if !plan.frequent.isEmpty {
        Toggle(isOn: $controller.adoptFrequent) {
          Text("同时启用建议的常用标签表（\(plan.frequent.count) 个）：新内容的标签今后只从表里选")
            .themedFont(.callout)
        }
        Text(plan.frequent.joined(separator: " · "))
          .themedFont(.caption).foregroundStyle(.secondary).lineLimit(4)
      }
      buttons([("取消", .cancel, { controller.cancel() }), ("确认执行", .confirm, { controller.apply() })])
    }
  }

  private func mergeRow(_ merge: TagTidyPlan.Merge) -> some View {
    let binding = Binding<TagTidyPlan.Merge>(
      get: { controller.plan?.merges.first { $0.id == merge.id } ?? merge },
      set: { updated in
        guard let index = controller.plan?.merges.firstIndex(where: { $0.id == merge.id }) else { return }
        controller.plan?.merges[index] = updated
      }
    )
    return HStack(alignment: .top, spacing: 8) {
      Toggle("", isOn: binding.isEnabled).labelsHidden()
      VStack(alignment: .leading, spacing: 2) {
        Text(zip(merge.sources, merge.sourceCounts).map { "\($0)（\($1)）" }.joined(separator: " · "))
          .themedFont(.callout).lineLimit(2)
        HStack {
          Text("合并为").themedFont(.caption).foregroundStyle(.secondary)
          TextField("新名字", text: binding.target).textFieldStyle(.roundedBorder)
        }
      }
    }
    .opacity(binding.wrappedValue.isEnabled ? 1 : 0.5)
  }
}
