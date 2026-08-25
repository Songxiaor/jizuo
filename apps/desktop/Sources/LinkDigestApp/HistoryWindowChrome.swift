import AppKit
import SwiftUI
import LinkDigestCore

struct HistoryInlineState: View {
  let symbol: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 58, height: 58)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
      Text(title).themedFont(.headline)
      Text(message)
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 330)
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
  }
}

struct ClipboardSuggestionBanner: View {
  let suggestion: ClipboardLinkSuggestion
  let capture: () -> Void
  let ignore: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("检测到剪贴板链接：\(suggestion.host)")
        .themedFont(.callout, weight: .semibold)
      Text(suggestion.displayURL)
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 10) {
        Button("抓取", action: capture)
          .accessibilityIdentifier("history-clipboard-capture")
        Button("忽略", action: ignore)
          .accessibilityIdentifier("history-clipboard-ignore")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .accessibilityIdentifier("history-clipboard-suggestion")
  }
}

struct ManualLinkSheet: View {
  // 错误色走主题，理由同其它视图：写死 .red 在低对比与高对比主题上都不成立。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: ManualLinkViewModel
  let modelCallDisclosure: AutomaticModelCallDisclosure
  @FocusState private var focusURL: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加网页链接").themedFont(.title3, weight: .semibold)
      Text("只读取你主动提交的公开 HTML 页面；登录页面请使用 \(ProductDisplay.extensionName)。")
        .themedFont(.callout).foregroundStyle(.secondary)
      TextField("https://example.com/article", text: $model.input)
        .textFieldStyle(.roundedBorder).focused($focusURL)
        .disabled(model.isBusy).accessibilityIdentifier("manual-link-url-input")
      if let validation = model.inputValidationMessage {
        Label(validation, systemImage: "exclamationmark.triangle.fill")
          .themedFont(.caption)
          .foregroundStyle(appTheme.danger)
          .accessibilityIdentifier("manual-link-validation")
      }
      if let disclosure = modelCallDisclosure.message {
        Text(disclosure)
          .themedFont(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("manual-link-model-call-hint")
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .themedFont(.callout).foregroundStyle(appTheme.danger).accessibilityIdentifier("manual-link-error")
      }
      if model.isFetching { ProgressView(model.fetchingMessage).accessibilityIdentifier("manual-link-fetching") }
      if model.isSaving { ProgressView("正在保存到本机历史…").accessibilityIdentifier("manual-link-saving") }
      HStack {
        Button("取消") { model.dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if model.isFetching {
          Button("停止读取", action: model.cancelFetch).accessibilityIdentifier("manual-link-cancel")
        } else if model.isSaving {
          Text("保存中").foregroundStyle(.secondary).accessibilityIdentifier("manual-link-saving-label")
        } else {
          Button("添加") { model.submit() }
            .keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
            .accessibilityIdentifier("manual-link-submit")
        }
      }
    }
    .padding(24).frame(width: 480)
    .onAppear { focusURL = true }
    .alert("这个链接已在库中", isPresented: $model.isDuplicatePromptPresented) {
      Button("取消", role: .cancel) { model.cancelDuplicateSubmit() }
      Button("仍要重新抓取") { model.confirmDuplicateSubmit() }
    } message: {
      Text("重复添加不会产生新条目：重新抓取的内容会併入原条目成为最新快照。若只想查看，请直接在列表中打开。")
    }
  }
}

/// 抓取队列行：URL + 阶段状态；失败可重试/移除，进行中可取消。
struct PendingCaptureRow: View {
  let pending: ManualLinkViewModel.PendingCapture
  @ObservedObject var model: ManualLinkViewModel
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      switch pending.phase {
      case .queued:
        Image(systemName: "clock").foregroundStyle(.secondary)
      case .fetching, .saving:
        ProgressView().controlSize(.small)
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(pending.urlString)
          .themedFont(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        switch pending.phase {
        case .queued: Text("排队中").themedFont(.caption2).foregroundStyle(.tertiary)
        case .fetching: Text("正在抓取…").themedFont(.caption2).foregroundStyle(.tertiary)
        case .saving: Text("正在保存…").themedFont(.caption2).foregroundStyle(.tertiary)
        case let .failed(message):
          // 失败原因必须完整可读。`lineLimit(2)` 会把「网页暂时无法打开，
          // 请检查链接后重试」截掉尾巴——而尾巴恰恰是那句可执行的建议。
          Text(message)
            .themedFont(.caption2)
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 4)
      if case .failed = pending.phase {
        Button("重试") { model.retryPendingCapture(pending.id) }
          .controlSize(.mini)
      }
      Button {
        model.removePendingCapture(pending.id)
      } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .help(pending.phase == .queued ? "移出队列" : "取消并移除")
      .accessibilityLabel(pending.phase == .queued ? "移出队列" : "取消并移除")
    }
    .padding(.vertical, 4)
    // 与 HistoryRowView 同一个坑：macOS List 会沿用估算行高把内容压扁，
    // 失败提示换行后第三行就被裁掉。固定纵向 intrinsic 高度 + 内容变化换 identity，
    // 强制按真实内容测量。
    .fixedSize(horizontal: false, vertical: true)
    .id("\(pending.id)-\(pending.phase)")
    .accessibilityIdentifier("pending-capture-row")
  }
}

struct ReadOnlyHistoryCallout: View {
  let reason: RepositoryRecoveryReason?
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock.fill")
        .foregroundStyle(theme.warning)
        .padding(.top, 1)
      Text(message)
        .themedFont(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
  }

  private var message: String {
    switch reason {
    case .futureSchema:
      "这份历史由较新版本创建，当前仅可浏览。原数据未修改；请使用较新版本的 \(ProductDisplay.name) 后再编辑或删除。"
    case .migrationFailed:
      "这份历史的迁移未完成，当前仅可浏览。原数据未修改；请在恢复后重新启动 \(ProductDisplay.name)，再编辑或删除。"
    case .storageUnavailable:
      "本地历史暂时无法以可写方式打开，当前仅可浏览。原数据未修改；请检查本机存储后重新启动 \(ProductDisplay.name)，再编辑或删除。"
    case nil:
      "本地历史当前仅可浏览。原数据未修改；请在恢复后重新启动 \(ProductDisplay.name)，再编辑或删除。"
    }
  }
}
