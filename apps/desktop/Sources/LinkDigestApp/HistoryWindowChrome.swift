import AppKit
import SwiftUI
import LinkDigestCore

struct HistoryInlineState: View {
  let symbol: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?
  /// 工序相关的空状态画一枚大印位代替图标（2026-09-28 工序印）：「待校对」是空的，
  /// 就是「校」这枚章都盖齐了、这里没有等着盖的。
  var seal: (glyph: SealMark.Glyph, color: Color)? = nil
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 10) {
      if let seal {
        SealMark(glyph: seal.glyph, size: 52, color: seal.color, style: .pending)
          .frame(width: 58, height: 58)
      } else {
        Image(systemName: symbol)
          .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 58, height: 58)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
      }
      Text(title).themedFont(.headline)
      Text(message)
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 330)
      if let actionTitle, let action {
        // 和设置、详情里的主按钮同一套样式；系统 borderedProminent 在这里字贴边
        // （2026-09-29 发布前走查）。
        Button(actionTitle, action: action)
          .buttonStyle(.appProminent(theme.accent))
          .padding(.top, 4)
      }
    }
    .padding(20)
  }
}

struct ClipboardSuggestionBanner: View {
  let suggestion: ClipboardLinkSuggestion
  let capture: () -> Void
  let ignore: () -> Void
  @Environment(\.appTheme) private var theme

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
    // 主题强调色，不是 App 级 `Color.accentColor`（默认系统蓝，不跟主题走）。2026-10-01
    .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .accessibilityIdentifier("history-clipboard-suggestion")
  }
}

struct ManualLinkSheet: View {
  // 错误色走主题，理由同其它视图：写死 .red 在低对比与高对比主题上都不成立。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: ManualLinkViewModel
  let modelCallDisclosure: AutomaticModelCallDisclosure
  @FocusState private var focusURL: Bool
  @Environment(\.openSettings) private var openSettings
  // 输入框下的登录提醒跟着这几个平台的登录状态变。
  @ObservedObject private var zhihuSession = SiteSessionController.zhihu
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @State private var showsDifferences = false

  /// 贴的是不登录就抓不全的平台、而汲作里还没登录它时，提交前就说清楚。
  private var loginHint: String? {
    guard let url = ExplicitWebLinkInput.singleURL(from: model.input),
          let platform = CaptureRouteGuidance.loginPlatform(for: url),
          !SiteSessionController.controller(for: platform).isLoggedIn
    else { return nil }
    return CaptureRouteGuidance.loginHint(for: platform)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加网页链接").themedFont(.title3, weight: .semibold)
      // 2026-10-02：App 和扩展用同一套提取，区别只剩登录状态从哪来（Syc：区别要写进 App 让用户看到）。
      Text("粘贴网页或视频链接。\(ProductDisplay.name)会在内置网页里打开它，和浏览器扩展用同一套规则提取正文、图片和字幕。")
        .themedFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("https://example.com/article", text: $model.input)
        .textFieldStyle(.roundedBorder).focused($focusURL)
        .disabled(model.isBusy).accessibilityIdentifier("manual-link-url-input")
      if let loginHint {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label(loginHint, systemImage: "person.crop.circle.badge.exclamationmark")
            .themedFont(.caption)
            .foregroundStyle(appTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("去登录") { openSiteLogin() }
            .controlSize(.small)
        }
        .accessibilityIdentifier("manual-link-login-hint")
      }
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
      DisclosureGroup(isExpanded: $showsDifferences) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(CaptureRouteGuidance.differences, id: \.self) { line in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("·").foregroundStyle(.secondary)
              Text(line).fixedSize(horizontal: false, vertical: true)
            }
          }
          Button("打开站点登录") { openSiteLogin() }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
      } label: {
        Text("和浏览器扩展有什么不同？").themedFont(.caption).foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("manual-link-route-differences")
      if model.isFetching { ProgressView(model.fetchingMessage).accessibilityIdentifier("manual-link-fetching") }
      if model.isSaving { ProgressView("正在保存到资料库…").accessibilityIdentifier("manual-link-saving") }
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
    .onAppear {
      focusURL = true
      Task { await zhihuSession.refreshStatus() }
      Task { await xiaohongshuSession.refreshStatus() }
      Task { await douyinSession.refreshStatus() }
    }
    .alert("这个链接已在库中", isPresented: $model.isDuplicatePromptPresented) {
      Button("取消", role: .cancel) { model.cancelDuplicateSubmit() }
      Button("仍要重新抓取") { model.confirmDuplicateSubmit() }
    } message: {
      Text("重复添加不会多出一条：重新抓取的内容会并入原来那条，成为最新的版本。只想查看的话，直接在列表里打开就行。")
    }
  }

  private func openSiteLogin() {
    SettingsNavigationRequest.request("siteLogin")
    openSettings()
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
  var recoveryHint: String? = nil
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
    let base: String = switch reason {
    case .futureSchema:
      "资料库现在只能看、不能改：它是更新版本的\(ProductDisplay.name)建的。原数据没有改动；升级到最新版\(ProductDisplay.name)就能恢复。"
    case .migrationFailed:
      "资料库现在只能看、不能改：上次升级资料库没有完成。原数据没有改动；重新打开\(ProductDisplay.name)会再试一次。"
    case .storageUnavailable:
      "资料库现在只能看、不能改：这次没能以可写方式打开。原数据没有改动；确认磁盘空间够后重新打开\(ProductDisplay.name)。"
    case nil:
      "资料库现在只能看、不能改。原数据没有改动；重新打开\(ProductDisplay.name)通常就能恢复。"
    }
    if let recoveryHint, !recoveryHint.isEmpty {
      return base + "\n" + recoveryHint
    }
    return base
  }
}
