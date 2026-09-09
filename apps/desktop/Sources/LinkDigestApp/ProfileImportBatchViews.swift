import SwiftUI
import LinkDigestCore

enum ProfileImportQueuePresentation {
  static let dismissedKey = "profile-import-dismissed-completion-notices"
  static func succeeded(_ batch: ProfileImportBatch) -> Bool {
    !batch.items.isEmpty && batch.completedCount == batch.items.count
  }
  static func visible(_ batch: ProfileImportBatch, dismissed: String) -> Bool {
    !succeeded(batch) || !dismissed.split(separator: ",").contains(Substring(batch.id.uuidString))
  }
}

struct ProfileImportBatchStack: View {
  @AppStorage(ProfileImportQueuePresentation.dismissedKey) private var dismissed = ""
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      ForEach(manualLink.profileImportBatches.filter { ProfileImportQueuePresentation.visible($0, dismissed: dismissed) }) { batch in
        ProfileImportBatchCard(
          batch: batch,
          manualLink: manualLink,
          historyModel: historyModel,
          compact: compact,
          dismiss: { dismissed = (dismissed.isEmpty ? "" : dismissed + ",") + batch.id.uuidString }
        )
      }
    }
  }
}

/// Expand/collapse and resume controls for one import batch.
/// History can place this in a shared LazyVGrid with `.gridCellColumns(columnCount)`.
struct ProfileImportBatchHeader: View {
  let batch: ProfileImportBatch
  @ObservedObject var manualLink: ManualLinkViewModel

  private var interruptedCount: Int {
    batch.items.filter { $0.phase == .interrupted }.count
  }

  var body: some View {
    HStack(spacing: 8) {
      Text("本次抓取 · 已保存 \(batch.completedCount) / \(batch.items.count)")
        .themedFont(.caption, weight: .semibold)
        .monospacedDigit()
      Spacer(minLength: 4)
      if interruptedCount > 0 {
        Button("继续 \(interruptedCount) 项") {
          manualLink.resumeProfileImportBatch(batch.id)
        }
        .controlSize(.small)
      }
      Button(batch.isCollapsed ? "展开" : "收起") {
        manualLink.toggleProfileImportBatch(batch.id)
      }
      .controlSize(.small)
    }
    .accessibilityIdentifier("profile-import-batch-header")
  }
}

/// One reserved or completed work in the creator grid. Identity is `item.id`.
struct ProfileImportBatchWorkCard: View {
  let batchID: UUID
  let item: ProfileImportBatchItem
  let savedRows: [TaskID: HistoryRowProjection]
  let localCover: (TaskID, String?) async -> URL?
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel
  @Environment(\.appTheme) private var theme

  var body: some View {
    Group {
      if case let .completed(taskID) = item.phase, let row = savedRows[taskID] {
        Button {
          historyModel.revealProfileImportResult(
            taskID: taskID,
            batchID: batchID,
            itemID: item.id
          )
        } label: {
          CreatorSavedWorkCard(
            row: row,
            theme: theme,
            localCover: { await localCover(taskID, $0) }
          )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityHint("打开作品")
      } else {
        ProfileImportReservedWorkCard(
          batchID: batchID,
          item: item,
          manualLink: manualLink,
          historyModel: historyModel
        )
      }
    }
    .id(item.id)
  }
}

/// Primary creator-works presentation. These are full-size reserved work cards,
/// not progress rows: all selected items occupy their final grid positions before
/// the serial worker starts.
struct ProfileImportBatchGrid: View {
  let batch: ProfileImportBatch
  let columns: [GridItem]
  let savedRows: [TaskID: HistoryRowProjection]
  let localCover: (TaskID, String?) async -> URL?
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ProfileImportBatchHeader(batch: batch, manualLink: manualLink)
      if !batch.isCollapsed {
        LazyVGrid(columns: columns, spacing: CreatorDirectoryChrome.xGridSpacing) {
          ForEach(batch.items) { item in
            ProfileImportBatchWorkCard(
              batchID: batch.id,
              item: item,
              savedRows: savedRows,
              localCover: localCover,
              manualLink: manualLink,
              historyModel: historyModel
            )
          }
        }
      }
    }
    .accessibilityIdentifier("profile-import-primary-grid")
  }
}

private struct ProfileImportReservedWorkCard: View {
  let batchID: UUID
  let item: ProfileImportBatchItem
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel
  @Environment(\.appTheme) private var theme

  private var host: String { URL(string: item.seed.canonicalURL)?.host ?? "" }

  var body: some View {
    CreatorWorkCardShell(theme: theme) {
      CreatorWorkCardCoverSlot {
        DouyinProfilePreviewImage(
          url: item.seed.coverURL.flatMap(DouyinProfilePreviewResource.admittedURL),
          previewText: item.seed.previewText
        )
        .overlay(alignment: .bottomLeading) { statusBadge }
        .overlay(alignment: .topTrailing) { actionButton.padding(6) }
      }
    } text: {
      VStack(alignment: .leading, spacing: CreatorWorkCardLayout.textSpacing) {
        CreatorWorkCardTextHeader(
          title: displayTitle,
          dateText: nonempty(item.seed.publishedText) ?? "发布时间待获取",
          theme: theme
        )
        CreatorWorkMetricStrip(host: host, theme: theme, values: metricValue, helpSuffix: "抓取前预览")
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .onTapGesture {
      guard case let .completed(taskID) = item.phase else { return }
      historyModel.revealProfileImportResult(taskID: taskID, batchID: batchID, itemID: item.id)
    }
    .help(failureMessage)
    .accessibilityValue(failureMessage)
    .accessibilityIdentifier("profile-import-reserved-work-card")
  }

  @ViewBuilder private var statusBadge: some View {
    HStack(spacing: 5) {
      switch item.phase {
      case .queued:
        ProgressView().controlSize(.mini)
        Text("排队中")
      case .fetching:
        ProgressView().controlSize(.mini)
        Text("正在抓取")
      case .saving:
        ProgressView().controlSize(.mini)
        Text("正在保存")
      case .completed:
        Image(systemName: "checkmark.circle.fill")
        Text("已保存 · 点击阅读")
      case let .failed(message):
        Image(systemName: "exclamationmark.triangle.fill")
        Text(message).lineLimit(2).help(message)
      case .cancelled:
        Image(systemName: "xmark.circle")
        Text("已取消")
      case .interrupted:
        Image(systemName: "pause.circle")
        Text("已中断")
      }
    }
    .themedFont(.caption2, weight: .medium)
    .foregroundStyle(statusColor)
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .padding(6)
  }

  @ViewBuilder private var actionButton: some View {
    if item.phase.canCancel {
      Button {
        manualLink.cancelProfileImportItem(batchID: batchID, itemID: item.id)
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .help("取消这条抓取")
      .accessibilityLabel("取消这条抓取")
    } else if item.phase.canRetry {
      Button {
        manualLink.retryProfileImportItem(batchID: batchID, itemID: item.id)
      } label: {
        Image(systemName: "arrow.clockwise.circle.fill")
      }
      .buttonStyle(.plain)
      .help("重试这条抓取")
      .accessibilityLabel("重试这条抓取")
    }
  }

  private var failureMessage: String {
    if case let .failed(message) = item.phase { return message }
    return ""
  }

  private var statusColor: Color {
    switch item.phase {
    case .completed: theme.success
    case .failed, .interrupted: theme.warning
    default: theme.secondaryText
    }
  }

  private var displayTitle: String {
    nonempty(item.seed.previewText) ?? CreatorDirectoryCardCopy.contentKind(host: host)
  }

  private func metricValue(_ kind: CreatorWorkMetricKind) -> String? {
    switch kind {
    case .likes: item.seed.likes
    case .comments: item.seed.comments
    case .collects: item.seed.collects
    case .shares, .views: nil
    }
  }

  private func nonempty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct ProfileImportBatchCard: View {
  let batch: ProfileImportBatch
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel
  let compact: Bool
  let dismiss: () -> Void
  @Environment(\.appTheme) private var theme

  private var interruptedCount: Int {
    batch.items.filter { $0.phase == .interrupted }.count
  }

  var body: some View {
    if ProfileImportQueuePresentation.succeeded(batch) {
      HStack(spacing: DesignTokens.Space.xs) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(theme.success)
          .accessibilityHidden(true)
        Text("主页抓取批次 · 已保存 \(batch.completedCount) 条")
          .foregroundStyle(theme.secondaryText)
          .lineLimit(1)
        Spacer(minLength: 4)
        Button(action: dismiss) { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .help("关闭完成提示，不会删除资料")
          .accessibilityLabel("关闭抓取完成提示")
      }
      .themedFont(.caption)
      .padding(.vertical, DesignTokens.Space.xxs)
      .accessibilityIdentifier("profile-import-completion-notice")
    } else {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("博主批量抓取")
            .themedFont(.caption, weight: .semibold)
          Text("已保存 \(batch.completedCount) / \(batch.items.count)")
            .themedFont(.caption2, monospacedDigit: true)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        if interruptedCount > 0 {
          Button("继续 \(interruptedCount) 项") {
            manualLink.resumeProfileImportBatch(batch.id)
          }
          .controlSize(.mini)
          .accessibilityIdentifier("profile-import-batch-resume")
        }
        Button {
          manualLink.toggleProfileImportBatch(batch.id)
        } label: {
          Image(systemName: batch.isCollapsed ? "chevron.down" : "chevron.up")
        }
        .buttonStyle(.plain)
        .help(batch.isCollapsed ? "展开批次" : "收起批次")
        .accessibilityLabel(batch.isCollapsed ? "展开批次" : "收起批次")
      }

      if !batch.isCollapsed {
        ForEach(batch.items.filter { if case .completed = $0.phase { return false }; return true }) { item in
          ProfileImportBatchItemRow(
            batchID: batch.id,
            item: item,
            manualLink: manualLink,
            historyModel: historyModel,
            compact: compact
          )
          .id(item.id)
        }
      }
    }
    .padding(10)
    .background(theme.badge.opacity(0.6), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .accessibilityIdentifier("profile-import-batch")
    }
  }
}

private struct ProfileImportBatchItemRow: View {
  let batchID: UUID
  let item: ProfileImportBatchItem
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var historyModel: HistoryViewModel
  let compact: Bool
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(displayTitle)
          .themedFont(.caption, weight: .medium)
          .lineLimit(2)
        statusLine
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      actions
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture {
      guard case let .completed(taskID) = item.phase else { return }
      historyModel.revealProfileImportResult(
        taskID: taskID,
        batchID: batchID,
        itemID: item.id
      )
    }
    .accessibilityIdentifier("profile-import-batch-item")
  }

  @ViewBuilder private var statusLine: some View {
    switch item.phase {
    case .queued:
      HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("排队中") }
        .foregroundStyle(.secondary)
    case .fetching:
      HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("正在抓取…") }
        .foregroundStyle(.secondary)
    case .saving:
      HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("正在保存…") }
        .foregroundStyle(.secondary)
    case .completed:
      Label("已保存 · 点击阅读", systemImage: "checkmark.circle.fill")
        .foregroundStyle(theme.success)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(theme.warning)
        .fixedSize(horizontal: false, vertical: true)
    case .cancelled:
      Label("已取消", systemImage: "xmark.circle").foregroundStyle(.secondary)
    case .interrupted:
      Label("上次抓取已中断，请手动继续", systemImage: "pause.circle")
        .foregroundStyle(theme.warning)
    }
  }

  @ViewBuilder private var actions: some View {
    if item.phase.canCancel {
      Button("取消") {
        manualLink.cancelProfileImportItem(batchID: batchID, itemID: item.id)
      }
      .controlSize(.mini)
      .accessibilityIdentifier("profile-import-item-cancel")
    } else if item.phase.canRetry {
      Button("重试") {
        manualLink.retryProfileImportItem(batchID: batchID, itemID: item.id)
      }
      .controlSize(.mini)
      .accessibilityIdentifier("profile-import-item-retry")
    }
  }

  private var displayTitle: String {
    nonempty(item.seed.previewText) ?? item.seed.canonicalURL
  }

  private func nonempty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
