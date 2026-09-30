import LinkDigestAdapters
import LinkDigestCore
import SwiftUI

extension View {
  /// 把文件拖到主窗口任意位置即可导入。编辑器等自己接收拖放的区域优先，
  /// 这里只接住落在其余地方的文件。
  func localImportDropTarget(_ controller: LocalImportController) -> some View {
    modifier(LocalImportDropTarget(controller: controller))
  }
}

/// 不能是 private：理由同 `AppThemeInjector`（它也在主窗口根视图的类型里）。
struct LocalImportDropTarget: ViewModifier {
  @ObservedObject var controller: LocalImportController
  @State private var isTargeted = false
  @Environment(\.appTheme) private var theme

  func body(content: Content) -> some View {
    content
      // 「导入后转写」可能要转很久：进度放在窗口右下角一条不挡操作的小胶囊里，
      // 不用弹窗把整个 App 占住。关掉导入结果也照常往下转。
      .overlay(alignment: .bottomTrailing) {
        if controller.transcriptionQueue != nil {
          LocalImportTranscriptionBadge(controller: controller)
            .padding(DesignTokens.Space.lg)
            .transition(.opacity)
        }
      }
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
      case let .confirming(plan):
        LocalImportConfirmationView(controller: controller, plan: plan)
      case let .finished(title, summary, revealHost):
        Text(title).themedFont(.headline)
        Text(summaryText(summary)).themedFont(.body)
          .fixedSize(horizontal: false, vertical: true)
        if !summary.ownership.isEmpty {
          LocalImportOwnershipList(controller: controller, items: summary.ownership)
        }
        if summary.queuedForTranscription > 0 {
          Label(
            "\(summary.queuedForTranscription) 个音视频正在本机逐个转写（免费、不上传），进度在窗口右下角，关掉这个窗口也会继续。",
            systemImage: "waveform"
          )
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if summary.notDownloaded > 0 {
          Text("有 \(summary.notDownloaded) 条录音只在 iCloud 上、还没下载到这台 Mac。在「语音备忘录」App 里点开播放一次即可下载，然后再同步。")
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !summary.failures.isEmpty {
          Text(summary.added + summary.skipped > 0
            ? "以下 \(summary.failures.count) 项没有导入（其余照常导入了）："
            : "以下 \(summary.failures.count) 项没有导入：").themedFont(.callout)
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
    .frame(width: 460)
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
    let tail: String
    if summary.added == 0 {
      tail = "。"
    } else if summary.queuedForTranscription > 0 {
      tail = "。音视频只记住了原文件的位置，没有复制一份；不会自动总结。"
    } else if summary.ownership.isEmpty {
      tail = "。新导入的素材不会自动转写或总结，需要时在条目里点「转写」或「总结」。"
    } else {
      tail = "。音视频只记住了原文件的位置，没有复制一份；不会自动转写或总结，需要时在条目里点「转写」或「总结」。"
    }
    return parts.joined(separator: "，") + tail
  }
}

/// 导入前的确认：「找到 N 个文件（视频 a 个、音频 b 个、文档 c 个），共 X GB」+ 要不要导入后转写。
struct LocalImportConfirmationView: View {
  @ObservedObject var controller: LocalImportController
  let plan: LocalImportController.ImportPlan
  @State private var transcribe = true
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      Text(title).themedFont(.headline)
      Text(Self.countsText(plan.scan)).themedFont(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("local-import-confirm-counts")
      if plan.scan.skippedCount > 0 {
        Text("另有 \(plan.scan.skippedCount) 个文件格式不支持（如 \(Self.sampleExtensions(plan.scan))），不会导入，结果里会逐个说明。")
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if plan.scan.truncated {
        Text("文件太多：这次只导入按顺序的前 \(LocalFileImportReader.scanFileLimit) 个，其余请分批导入。")
          .themedFont(.callout)
          .foregroundStyle(theme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      if plan.scan.mediaCount > 0 {
        Text("音视频只记住原文件的位置，不会复制进汲作；原文件挪走后可以在条目里重新定位。")
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if plan.offersTranscription {
        Toggle(isOn: $transcribe) {
          VStack(alignment: .leading, spacing: 2) {
            Text("导入后转写")
            Text("用本机听写把 \(plan.scan.mediaCount) 个音视频逐个转成文字，免费、不上传，不会自动总结。")
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("local-import-confirm-transcribe")
      }
      HStack {
        Spacer()
        Button("取消") { controller.cancelConfirmation() }
          .keyboardShortcut(.cancelAction)
        Button("导入") { controller.confirmImport(transcribe: transcribe) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("local-import-confirm-import")
      }
    }
  }

  private var title: String {
    let folders = plan.scan.folders
    if folders.count == 1 { return "导入文件夹「\(folders[0].name)」" }
    if folders.count > 1 { return "导入 \(folders.count) 个文件夹" }
    return "导入本地文件"
  }

  /// 「找到 12 个文件（视频 5 个、音频 3 个、文档 4 个），共 3.2 GB」。
  static func countsText(_ scan: LocalImportScan) -> String {
    let parts: [String] = [
      (LocalFileKind.video, "视频"), (.audio, "音频"), (.document, "文档"), (.image, "图片"),
    ].compactMap { kind, name in
      let count = scan.count(kind)
      return count > 0 ? "\(name) \(count) 个" : nil
    }
    let size = ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file)
    return "找到 \(scan.entries.count) 个文件（\(parts.joined(separator: "、"))），共 \(size)。"
  }

  static func sampleExtensions(_ scan: LocalImportScan) -> String {
    var seen: [String] = []
    for item in scan.skipped {
      let ext = item.url.pathExtension.lowercased()
      if !ext.isEmpty, !seen.contains(".\(ext)") { seen.append(".\(ext)") }
      if seen.count == 3 { break }
    }
    return seen.isEmpty ? "文件夹里的其它文件" : seen.joined(separator: "、")
  }
}

/// 导入结果里逐个列出归属判断，每条都能「改」。多于 6 条时默认收起。
struct LocalImportOwnershipList: View {
  @ObservedObject var controller: LocalImportController
  let items: [LocalImportController.OwnershipItem]
  @State private var isExpanded: Bool?
  @Environment(\.appTheme) private var theme

  var body: some View {
    DisclosureGroup(isExpanded: Binding(
      get: { isExpanded ?? (items.count <= 6) },
      set: { isExpanded = $0 }
    )) {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(items) { item in
            row(item)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(maxHeight: 200)
    } label: {
      Text(Self.summaryLine(items)).themedFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("local-import-ownership")
  }

  private func row(_ item: LocalImportController.OwnershipItem) -> some View {
    HStack(spacing: DesignTokens.Space.sm) {
      SealMark(glyph: item.ownership == .own ? .own : .external, size: 16, color: SealMark.stampInk, showsInnerFrame: false)
        .frame(width: 18)
      Text(item.name)
        .themedFont(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(item.name)
      Spacer(minLength: DesignTokens.Space.sm)
      Text(item.ownership == .own ? "自有" : (item.source.map { "外部 · \($0)" } ?? "外部"))
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button("改") { controller.toggleOwnership(item.id) }
        .buttonStyle(.link)
        .themedFont(.caption)
        .help(item.ownership == .own ? "改成外部" : "改成自有")
        .accessibilityLabel("把「\(item.name)」改成\(item.ownership == .own ? "外部" : "自有")")
    }
  }

  /// 「3 个判为外部（微信下载）、2 个判为自有」。
  static func summaryLine(_ items: [LocalImportController.OwnershipItem]) -> String {
    let external = items.filter { $0.ownership == .external }
    let own = items.count - external.count
    var parts: [String] = []
    if !external.isEmpty {
      var sources: [String] = []
      for source in external.compactMap(\.source) where !sources.contains(source) { sources.append(source) }
      let shown = sources.prefix(3).joined(separator: "、") + (sources.count > 3 ? "等" : "")
      parts.append(sources.isEmpty ? "\(external.count) 个判为外部" : "\(external.count) 个判为外部（\(shown)）")
    }
    if own > 0 { parts.append("\(own) 个判为自有") }
    return parts.joined(separator: "、") + "。判错了可以点「改」。"
  }
}

/// 窗口右下角的「转写中 3/12 · 停止」。转完变成汇总，失败的可以点开看原因。
struct LocalImportTranscriptionBadge: View {
  @ObservedObject var controller: LocalImportController
  @State private var showsFailures = false
  @Environment(\.appTheme) private var theme

  var body: some View {
    if let status = controller.transcriptionQueue {
      HStack(spacing: DesignTokens.Space.sm) {
        if status.isRunning {
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 1) {
            Text("转写中 \(status.position)/\(status.total)").themedFont(.callout, weight: .medium)
            if let name = status.currentName {
              Text(name).themedFont(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            }
          }
          Button("停止") { controller.stopTranscriptionQueue() }
            .buttonStyle(.appNormal)
            .help("停下正在转的这一条，后面排着的也不转了；已经转好的都留着")
            .accessibilityIdentifier("local-import-transcription-stop")
        } else {
          Image(systemName: status.failures.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundStyle(status.failures.isEmpty ? theme.accent : theme.warning)
          Text(Self.finishedText(status)).themedFont(.callout)
          if !status.failures.isEmpty {
            Button("看原因") { showsFailures = true }
              .buttonStyle(.link)
              .popover(isPresented: $showsFailures, arrowEdge: .top) { failureList(status) }
          }
          Button {
            controller.dismissTranscriptionQueue()
          } label: {
            Image(systemName: "xmark").imageScale(.small)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("关闭")
        }
      }
      .padding(.horizontal, DesignTokens.Space.md)
      .padding(.vertical, DesignTokens.Space.sm)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(theme.hairline))
      .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("local-import-transcription-badge")
    }
  }

  static func finishedText(_ status: LocalImportController.TranscriptionQueueStatus) -> String {
    var text = status.wasStopped ? "已停止转写，完成 \(status.succeeded)/\(status.total)" : "转写完成 \(status.succeeded)/\(status.total)"
    if status.alreadyTranscribed > 0 { text += "，\(status.alreadyTranscribed) 个之前已转写" }
    if !status.failures.isEmpty { text += "，\(status.failures.count) 个失败" }
    return text
  }

  private func failureList(_ status: LocalImportController.TranscriptionQueueStatus) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      Text("\(status.failures.count) 个没有转写成功").themedFont(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(status.failures.enumerated()), id: \.offset) { _, line in
            Text(line).themedFont(.caption).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
        }
      }
      .frame(maxHeight: 220)
      Text("可以打开对应条目再点「转写」重试。").themedFont(.caption).foregroundStyle(.secondary)
    }
    .padding(DesignTokens.Space.lg)
    .frame(width: 360)
  }
}
