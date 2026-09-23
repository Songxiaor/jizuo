import LinkDigestCore
import SwiftUI

extension View {
  /// 把文件拖到主窗口任意位置即可导入。编辑器等自己接收拖放的区域优先，
  /// 这里只接住落在其余地方的文件。
  func localImportDropTarget(_ controller: LocalImportController) -> some View {
    modifier(LocalImportDropTarget(controller: controller))
  }
}

private struct LocalImportDropTarget: ViewModifier {
  @ObservedObject var controller: LocalImportController
  @State private var isTargeted = false
  @Environment(\.appTheme) private var theme

  func body(content: Content) -> some View {
    content
      .dropDestination(for: URL.self) { urls, _ in
        let files = urls.filter(\.isFileURL)
        guard controller.canImport, !files.isEmpty else { return false }
        controller.importFiles(files)
        return true
      } isTargeted: { isTargeted = $0 && controller.canImport }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay {
              Label("松开即可导入到汲作", systemImage: "square.and.arrow.down")
                .themedFont(.headline)
                .padding(.horizontal, DesignTokens.Space.lg)
                .padding(.vertical, DesignTokens.Space.md)
                .background(.regularMaterial, in: Capsule())
            }
            .padding(DesignTokens.Space.md)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
  }
}

/// 同步 / 导入的进度与结果。成功、跳过、未下载、失败分开讲，
/// 权限问题给出能直接点的去处，而不是只说一句「失败」。
struct LocalImportStatusSheet: View {
  @ObservedObject var controller: LocalImportController
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      switch controller.phase {
      case .idle:
        EmptyView()
      case let .running(title, done, total, step):
        Text(title).themedFont(.headline)
        // 只有一项时进度条永远停在 0，看起来像卡死；改成持续转动的指示。
        if total > 1 {
          ProgressView(value: Double(done), total: Double(total))
        } else {
          ProgressView().progressViewStyle(.linear)
        }
        Text([step, total > 1 ? "第 \(min(done + 1, total)) / \(total) 项" : nil].compactMap { $0 }.joined(separator: "  ·  "))
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        HStack {
          Spacer()
          Button("停止") { controller.cancel() }
        }
      case let .finished(title, summary, revealHost):
        Text(title).themedFont(.headline)
        Text(summaryText(summary)).themedFont(.body)
          .fixedSize(horizontal: false, vertical: true)
        if summary.notDownloaded > 0 {
          Text("有 \(summary.notDownloaded) 条录音只在 iCloud 上、还没下载到这台 Mac。在「语音备忘录」App 里点开播放一次即可下载，然后再同步。")
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !summary.failures.isEmpty {
          Text("以下 \(summary.failures.count) 项没有导入：").themedFont(.callout)
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, line in
                Text(line).themedFont(.caption).foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              }
            }
          }
          .frame(maxHeight: 140)
        }
        HStack {
          Spacer()
          Button("关闭") { controller.isPresented = false }
          if let revealHost {
            Button("查看") { controller.reveal(host: revealHost) }
              .keyboardShortcut(.defaultAction)
          }
        }
      case let .failed(title, message, settingsLink):
        Label(title, systemImage: "exclamationmark.triangle")
          .themedFont(.headline)
          .foregroundStyle(theme.danger)
        Text(message).themedFont(.body)
          .fixedSize(horizontal: false, vertical: true)
        if settingsLink != nil {
          Text("授权后如果仍然读不到，请退出并重新打开汲作。")
            .themedFont(.callout)
            .foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("关闭") { controller.isPresented = false }
          if let settingsLink {
            Button("打开系统设置") { controller.open(settingsLink) }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
    }
    .padding(DesignTokens.Space.xl)
    .frame(width: 420)
  }

  private func summaryText(_ summary: LocalImportController.Summary) -> String {
    if summary.added == 0, summary.updated == 0, summary.skipped == 0, summary.notDownloaded == 0,
       summary.locked == 0, summary.sensitiveSkipped == 0, summary.failures.isEmpty {
      return "没有找到可导入的内容。"
    }
    var parts: [String] = []
    if summary.added > 0 { parts.append("新增 \(summary.added) 条") }
    if summary.updated > 0 { parts.append("更新 \(summary.updated) 条有改动的内容") }
    if summary.skipped > 0 { parts.append("\(summary.skipped) 条之前已导入且没有变化，已跳过") }
    if summary.locked > 0 { parts.append("\(summary.locked) 条加了密码的备忘录读不到，已跳过") }
    if summary.sensitiveSkipped > 0 {
      var text = "\(summary.sensitiveSkipped) 条在敏感文件夹里或疑似含密钥、账号密码，没有导入汲作"
      if summary.sensitivePurged > 0 { text += "（其中 \(summary.sensitivePurged) 条之前导入的副本已从汲作彻底删除，备忘录里的原件不受影响）" }
      parts.append(text)
    }
    if parts.isEmpty { return "这次没有新增内容。" }
    let tail = summary.added > 0 ? "。新导入的素材不会自动转写或总结，需要时在条目里点「转写」或「总结」。" : "。"
    return parts.joined(separator: "，") + tail
  }
}
