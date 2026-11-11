import SwiftUI
import LinkDigestCore

/// 阅读页的素材卡（2026-11 第二批）：谁在说、核心观点、开头怎么抓人、金句、是否真人口播。
/// 只有已转写的视频才出现；没有卡时给「生成素材卡」按钮，花钱的动作永远由用户点。
struct MaterialCardSectionView: View {
  let detail: HistoryDetailProjection
  @Bindable var model: HistoryViewModel

  private var taskID: TaskID { detail.task.id }

  private var hasTranscript: Bool {
    detail.snapshots.contains {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
        && !$0.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    if let controller = model.materialCards, hasTranscript || controller.record(for: taskID) != nil {
      MaterialCardBody(controller: controller, taskID: taskID, hasTranscript: hasTranscript)
        .padding(.top, DesignTokens.Space.xl)
        .task(id: taskID) { await controller.load(taskID: taskID) }
    }
  }
}

private struct MaterialCardBody: View {
  @Bindable var controller: MaterialCardController
  let taskID: TaskID
  let hasTranscript: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("素材卡").themedFont(.headline)
        if let record = controller.record(for: taskID) {
          Text(record.card.isLiveSpeaker ? "真人口播" : "非真人口播")
            .themedFont(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(record.card.isLiveSpeaker ? 0.18 : 0.08)))
            .accessibilityIdentifier("material-card-live-badge")
        }
        Spacer(minLength: 0)
        actionButton
      }
      if let record = controller.record(for: taskID) { cardContent(record) }
      statusView
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    .accessibilityIdentifier("material-card-section")
  }

  @ViewBuilder private var actionButton: some View {
    let reason = controller.unavailableReason(taskID: taskID, hasTranscript: hasTranscript)
    let title = controller.record(for: taskID) == nil ? "生成素材卡" : "重新生成"
    Button(title) { controller.generate(taskID: taskID) }
      .controlSize(.small)
      .disabled(reason != nil)
      .help(reason ?? "把这条的转写稿发给模型，提取一张素材卡；每次点击调用一次模型。")
      .accessibilityIdentifier("material-card-generate")
  }

  @ViewBuilder private func cardContent(_ record: TaskMaterialCardRecord) -> some View {
    let card = record.card
    VStack(alignment: .leading, spacing: 6) {
      if !card.speaker.isEmpty { field("谁在说", card.speaker) }
      if !card.viewpoints.isEmpty {
        field("核心观点", card.viewpoints.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
      }
      if !card.hook.isEmpty { field("开头怎么抓人", card.hook) }
      if !card.quotes.isEmpty { field("金句", card.quotes.map { "“\($0)”" }.joined(separator: "\n")) }
      if !card.liveSpeakerReason.isEmpty { field("判断依据", card.liveSpeakerReason) }
      if let total = record.totalTokens {
        Text("本卡用了 \(total) tokens").themedFont(.caption).foregroundStyle(.tertiary)
      }
    }
    .textSelection(.enabled)
  }

  private func field(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).themedFont(.caption).foregroundStyle(.secondary)
      Text(value).themedFont(.body)
    }
  }

  @ViewBuilder private var statusView: some View {
    switch controller.state(for: taskID) {
    case .idle:
      EmptyView()
    case .working:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在生成素材卡…").themedFont(.caption).foregroundStyle(.secondary)
        Button("取消") { controller.cancel(taskID: taskID) }.controlSize(.small)
      }
    case let .needsConsent(host, model):
      VStack(alignment: .leading, spacing: 4) {
        Text("将把这条的转写稿（最多 \(MaterialCardPrompt.transcriptCharacterLimit) 字）发送给 \(host)（模型 \(model)）提取素材卡。不发送视频、音频或链接。")
          .themedFont(.caption)
        HStack {
          Button("同意并生成") { controller.confirmConsent(taskID: taskID) }.controlSize(.small)
          Button("取消") { controller.cancel(taskID: taskID) }.controlSize(.small)
        }
      }
      .accessibilityIdentifier("material-card-consent")
    case let .failed(message):
      Text(message).themedFont(.caption).foregroundStyle(.red)
        .accessibilityIdentifier("material-card-error")
    }
  }
}

/// 设置里的素材卡：自动开关（默认关）和批量补做入口。
struct MaterialCardSettingsSection: View {
  @Bindable var model: HistoryViewModel
  @State private var autoOn = false

  var body: some View {
    if let controller = model.materialCards {
      VStack(alignment: .leading, spacing: 10) {
        Text("素材卡").themedFont(.headline)
        Toggle("视频转写后自动做素材卡", isOn: Binding(
          get: { autoOn },
          set: { autoOn = $0; controller.autoAfterTranscript = $0 }
        ))
        .accessibilityIdentifier("material-card-auto-toggle")
        Text("打开后，你在阅读页手动转写一条视频完成时，会自动把转写稿发给模型做一张素材卡：每个视频调用一次模型，会产生费用。批量转写、导入队列和 MCP 不会触发。默认关闭。")
          .themedFont(.caption).foregroundStyle(.secondary)
        MaterialCardBatchView(controller: controller)
      }
      .onAppear { autoOn = controller.autoAfterTranscript }
    }
  }
}

private struct MaterialCardBatchView: View {
  @Bindable var controller: MaterialCardController

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch controller.batchState {
      case .idle:
        Button("为未处理的视频生成素材卡…") { controller.prepareBatch() }
          .accessibilityIdentifier("material-card-batch-prepare")
      case .estimating:
        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在统计…").themedFont(.caption) }
      case let .estimate(estimate):
        Text("将为 \(estimate.count) 个已转写、还没有素材卡的视频各调用一次模型，共约 \(estimate.characters) 字转写稿；预计输入约 \(estimate.estimatedInputTokens) tokens、输出约 \(estimate.estimatedOutputTokens) tokens，会产生费用。逐条串行，可随时停止，失败不重试。")
          .themedFont(.caption)
        if let consent = estimate.needsConsent {
          Text("确认后会把转写稿发送给 \(consent.host)（模型 \(consent.model)）。").themedFont(.caption)
        }
        HStack {
          Button("确认开始") { controller.confirmBatch() }
            .accessibilityIdentifier("material-card-batch-confirm")
          Button("取消") { controller.dismissBatch() }
        }
      case let .running(done, total, failed):
        HStack(spacing: 8) {
          ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
          Text("\(done)/\(total)" + (failed > 0 ? "，失败 \(failed)" : "")).themedFont(.caption)
          Button("停止") { controller.stopBatch() }
            .accessibilityIdentifier("material-card-batch-stop")
        }
      case let .finished(message), let .failed(message):
        Text(message).themedFont(.caption).foregroundStyle(.secondary)
        Button("好") { controller.dismissBatch() }.controlSize(.small)
      }
    }
  }
}
