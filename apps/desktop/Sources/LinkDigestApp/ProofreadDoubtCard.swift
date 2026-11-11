import LinkDigestCore
import SwiftUI

/// 转写稿上方的校对提示：AI 改了几处字、几处拿不准请你定；改名后「记住这个名字」也在这里。
/// 存疑的地方正文里仍是听写原样，采纳才会改校对稿；机器原稿永远不动。
/// 「记住这个名字」和提示只在它所属的那条记录上显示，不依赖有没有校对稿。
struct ProofreadDoubtCard: View {
  @Bindable var model: HistoryViewModel
  let taskID: TaskID
  /// 现在显示的是不是校对稿；没校对过的转写稿只会有「记住这个名字」。
  let isTidiedTranscript: Bool
  /// 朱批档里切到了「原稿」：不显示卡片，只留一行灰字。
  let showsMachineOriginal: Bool
  let primaryText: Color
  let secondaryText: Color
  let highlight: Color
  /// 全部处理完后收成一行，点开才看细节。
  @State private var isExpanded = false

  var body: some View {
    let entry = isTidiedTranscript ? model.doubtEntry(taskID: taskID) : nil
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      if let entry {
        if showsMachineOriginal {
          if !entry.pending.isEmpty {
            Text("切回校对稿可处理 \(entry.pending.count) 处存疑")
              .themedFont(.caption).foregroundStyle(secondaryText)
          }
        } else {
          doubtSection(entry)
        }
      }
      if let name = model.nameToRemember(for: taskID) {
        HStack(spacing: DesignTokens.Space.sm) {
          Text("把「\(name)」记进常用名字表？下次校对会照这个写法。")
            .themedFont(.caption).foregroundStyle(secondaryText)
          Spacer(minLength: 0)
          Button("记住") { model.rememberOfferedName() }
          Button("不用") { model.dismissNameSuggestion() }
        }
        .buttonStyle(.borderless)
        .themedFont(.caption)
      }
      if let notice = model.proofreadNotice(for: taskID) {
        Text(notice).themedFont(.caption).foregroundStyle(secondaryText)
      }
    }
  }

  @ViewBuilder private func doubtSection(_ entry: TranscriptDoubtEntry) -> some View {
    let pending = entry.pending
    if entry.doubts.isEmpty {
      if entry.changeCount != nil {
        Text(ProofreadDoubtSummary.line(changeCount: entry.changeCount, pending: 0, hasDoubts: false))
          .themedFont(.caption).foregroundStyle(secondaryText)
      }
    } else if pending.isEmpty && !isExpanded {
      Button {
        isExpanded = true
      } label: {
        HStack(spacing: 4) {
          Text(ProofreadDoubtSummary.collapsedLine(handled: entry.doubts.count))
          Image(systemName: "chevron.right").imageScale(.small)
        }
        .themedFont(.caption).foregroundStyle(secondaryText)
      }
      .buttonStyle(.plain)
    } else {
      doubtList(entry, pendingCount: pending.count)
    }
  }

  @ViewBuilder private func doubtList(_ entry: TranscriptDoubtEntry, pendingCount: Int) -> some View {
    let isSaving = model.isSavingDoubts(for: taskID)
    HStack(spacing: DesignTokens.Space.sm) {
      Text(ProofreadDoubtSummary.line(changeCount: entry.changeCount, pending: pendingCount, hasDoubts: true))
        .themedFont(.caption).foregroundStyle(primaryText)
      Spacer(minLength: 0)
      if pendingCount > 1 {
        Button("全部采纳") { model.adoptAllDoubts(taskID: taskID) }.disabled(isSaving)
        Button("全部忽略") { model.keepAllDoubts(taskID: taskID) }.disabled(isSaving)
      }
      if pendingCount == 0 {
        Button("收起") { isExpanded = false }
      }
    }
    .buttonStyle(.borderless)
    .themedFont(.caption)
    ForEach(entry.doubts) { doubt in
      doubtRow(doubt, isSaving: isSaving)
    }
  }

  private func doubtRow(_ doubt: TranscriptDoubt, isSaving: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(doubt.original)
          .background(highlight.opacity(doubt.status == .pending ? 0.28 : 0.1))
          .strikethrough(doubt.status == .adopted)
        Image(systemName: "arrow.right").foregroundStyle(secondaryText)
        Text(doubt.suggestion).foregroundStyle(primaryText)
        Spacer(minLength: 0)
        switch doubt.status {
        case .pending:
          Button("采纳建议") { model.adoptDoubt(taskID: taskID, doubtID: doubt.id) }.disabled(isSaving)
          Button("保留原文") { model.keepDoubt(taskID: taskID, doubtID: doubt.id) }.disabled(isSaving)
        case .adopted:
          Text("已采纳").foregroundStyle(secondaryText)
          if !model.isKnownName(doubt.suggestion) {
            Button("记入名字表") { model.rememberAdoptedName(doubt.suggestion, taskID: taskID) }
          }
        case .kept:
          Text("已保留原文").foregroundStyle(secondaryText)
        }
      }
      .buttonStyle(.borderless)
      if !doubt.reason.isEmpty {
        Text(doubt.reason).themedFont(.caption).foregroundStyle(secondaryText)
      }
    }
    .themedFont(.body)
  }
}

/// 设置里的「常用名字」：校对时会把这些名字附在提示词里，只含名字和词，不含资料内容。
struct KnownNamesSettingsSection: View {
  @Bindable var model: HistoryViewModel
  @State private var draft = ""
  @State private var message: String?

  var body: some View {
    let names = model.knownNameList
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("常用名字").themedFont(.headline)
      Text("校对录音转写时，会把这些名字和词多发给聊天模型一份（只发名字，不发资料内容），让它照这个写法改。最多 \(KnownNamePolicy.maximumNames) 个。")
        .themedFont(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("添加一个名字或词", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
        Button("添加", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let message { Text(message).themedFont(.caption).foregroundStyle(.secondary) }
      if names.isEmpty {
        Text("还没有名字。给说话人改名后，或采纳校对建议时，可以一键记住。")
          .themedFont(.caption).foregroundStyle(.tertiary)
      } else {
        ForEach(names, id: \.text) { name in
          HStack {
            Text(name.text)
            Spacer(minLength: 0)
            Button("删除") { model.removeKnownName(name.text) }.buttonStyle(.borderless)
          }
        }
      }
    }
  }

  private func add() {
    let result = model.addKnownName(draft, source: .manual)
    if result == .added { draft = "" }
    message = KnownNameMessage.message(for: result)
  }
}
