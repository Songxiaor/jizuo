import LinkDigestCore
import SwiftUI

/// 阅读页页尾的「相关内容」（2026-11-11）。
///
/// 只在真有结果时才出现：没开「按意思搜」、索引没好、或者没有够相近的内容，
/// 这里整块不挂，页面和以前一模一样，不占位置也不闪一下空标题。
struct RelatedContentSection: View {
  @Environment(\.appTheme) private var appTheme

  let taskID: TaskID
  let title: String?
  let summary: String?
  /// 正文只在没有总结时才需要；这里收成闭包，有总结时连拆 markdown 都省了。
  let bodyProvider: () -> String?
  /// 便宜的变更标记（比如快照条数）：正文来源换了才需要重算，不为了判断它去取全文。
  let sourceToken: Int
  /// 具体类型而不是协议：视图要读它的状态，模型从「正在载入」变成「就绪」时
  /// 这一块才能自己长出来，不用等用户切走再切回来。
  let search: SemanticSearchService?
  let history: HistoryApplicationService?
  let onOpen: (TaskID) -> Void

  @State private var service = RelatedContentService()
  @State private var missingNotice: String?
  @State private var missingNoticeTask: Task<Void, Never>?

  private struct TaskKey: Hashable {
    let taskID: TaskID
    let title: String?
    let summary: String?
    let sourceToken: Int
    /// 「没就绪 / 就绪（多少条）」：索引补算期间状态会变，这里跟着重算或重读缓存。
    let readiness: String
  }

  private var readiness: String {
    guard let search else { return "none" }
    if case let .ready(count) = search.state { return "ready-\(count)" }
    return "\(search.isReady)"
  }

  var body: some View {
    let key = TaskKey(
      taskID: taskID,
      title: title,
      summary: summary,
      sourceToken: sourceToken,
      readiness: readiness
    )
    Group {
      if !service.items.isEmpty {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
          RelatedContentList(items: service.items, onOpen: open)
            .accessibilityIdentifier("history-related-content")
          if let missingNotice {
            Text(missingNotice)
              .themedFont(.caption)
              .foregroundStyle(appTheme.secondaryText)
              .accessibilityIdentifier("history-related-content-missing")
          }
        }
        .padding(.top, DesignTokens.Space.xl)
      }
    }
    .task(id: key) {
      // 懒求值：有总结就不调用 `bodyProvider`，不为了一个用不上的正文先拆一遍。
      let query = RelatedContentQuery.text(title: key.title, summary: key.summary, body: bodyProvider())
      await service.load(
        request: RelatedContentRequest(taskID: key.taskID, query: query),
        search: search,
        rows: history.map(HistoryRelatedContentRows.init)
      )
    }
  }

  /// 先确认这条还在，再打开：索引里可能还留着刚被删掉的条目，
  /// 直接跳过去会停在一个加载失败的详情上（2026-11-11 复核）。
  private func open(_ taskID: TaskID) {
    guard let history else {
      onOpen(taskID)
      return
    }
    let loader = HistoryRelatedContentRows(history: history)
    Task {
      let rows = await Task.detached(priority: .userInitiated) {
        loader.rows(for: [taskID])
      }.value
      if rows.isEmpty {
        showMissingNotice()
      } else {
        onOpen(taskID)
      }
    }
  }

  private func showMissingNotice() {
    missingNotice = "这条内容已经不在了，可能刚被删掉。"
    missingNoticeTask?.cancel()
    missingNoticeTask = Task {
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      missingNotice = nil
    }
  }
}

/// 结果列表本身。独立出来是为了能离屏渲染检查，不用连整个详情页和真库一起跑。
struct RelatedContentList: View {
  @Environment(\.appTheme) private var appTheme
  let items: [RelatedContentSelection.Item]
  let onOpen: (TaskID) -> Void

  @State private var hovered: TaskID?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text("相关内容").themedFont(.headline)
        Text("你的备忘录和录音里，意思相近的几条")
          .themedFont(.caption)
          .foregroundStyle(appTheme.secondaryText)
      }
      AppCard(padding: 0, theme: appTheme) {
        VStack(spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
              Rectangle()
                .fill(appTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 34)
            }
            row(item)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ item: RelatedContentSelection.Item) -> some View {
    Button {
      onOpen(item.taskID)
    } label: {
      HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
        Image(systemName: symbol(for: item))
          .font(.system(size: DesignTokens.IconSize.control, weight: .regular))
          .foregroundStyle(appTheme.secondaryText)
          .frame(width: 18, alignment: .center)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .themedFont(.callout, weight: .medium)
            .lineLimit(1)
          if !item.preview.isEmpty {
            Text(item.preview)
              .themedFont(.caption)
              .foregroundStyle(appTheme.secondaryText)
              .lineLimit(2)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, DesignTokens.Space.sm + 2)
      .padding(.horizontal, DesignTokens.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(hovered == item.id ? appTheme.primaryText.opacity(0.035) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
    .help("打开这条")
    .accessibilityLabel("\(item.title)，\(kindName(item))")
    .accessibilityIdentifier("history-related-content-\(item.taskID.rawValue)")
  }

  private func symbol(for item: RelatedContentSelection.Item) -> String {
    item.host == LocalImportSource.voiceMemos.rawValue ? "waveform" : "square.and.pencil"
  }

  private func kindName(_ item: RelatedContentSelection.Item) -> String {
    item.host == LocalImportSource.voiceMemos.rawValue ? "语音备忘录" : "备忘录"
  }
}
