import SwiftUI
import UniformTypeIdentifiers
import LinkDigestCore

struct HistoryContentView: View {
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel

  var body: some View {
    Group {
      if model.blockingErrorCode != nil {
        blockingError
      } else {
        NavigationSplitView {
          sidebar.navigationSplitViewColumnWidth(min: 340, ideal: 340, max: 340)
        } detail: { detail }
          .alert("删除这条历史记录？", isPresented: $model.isDeleteConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelDeletion() }
            Button("删除", role: .destructive) { model.confirmDeletion(protectedTaskID: activeRunTaskID) }
          } message: { Text("此操作只删除本机的这条记录，无法撤销。") }
          .alert("正在生成结果", isPresented: $model.isProtectedDeletionAlertPresented) {
            Button("好") { model.dismissProtectedDeletionAlert() }
          } message: {
            Text("请先停止当前任务，再删除这条历史记录。")
          }
          .alert("无法删除这条历史记录", isPresented: $model.isDeleteFailurePresented) {
            Button("好") { model.dismissDeleteFailure() }
          } message: { Text("本地历史未发生删除，请稍后重试。") }
          .alert("无法准备导出", isPresented: $model.isExportPreparationFailurePresented) {
            Button("好") { model.dismissExportPreparationFailure() }
          } message: { Text("无法准备导出，请检查历史记录后重试。") }
          .alert("无法保存导出文件", isPresented: $model.isExportSaveFailurePresented) {
            Button("好") { model.dismissExportSaveFailure() }
          } message: { Text("请检查所选文件夹的权限后重试。") }
          .fileExporter(
            isPresented: $model.isExportPanelPresented,
            document: model.exportFile.map(HistoryExportDocument.init),
            contentType: uniformType(for: model.exportFile?.format ?? .plainText),
            defaultFilename: model.exportFile?.suggestedFilename ?? "LinkDigest 历史.1.txt"
          ) { result in
            switch result {
            case .success: model.completeExportSave()
            case let .failure(error) where isUserCancelledExport(error): model.cancelExport()
            case .failure: model.failExportSave()
            }
          }
      }
    }
    .sheet(isPresented: Binding(
      get: { appModel.isDataDestinationDisclosurePresented },
      set: { if !$0 { appModel.cancelDataDestinationDisclosure() } }
    )) {
      if let disclosure = appModel.dataDestinationDisclosure {
        DataDestinationDisclosureView(
          disclosure: disclosure,
          isConfirming: appModel.isConfirmingDataDestinationDisclosure,
          confirm: { Task { await appModel.confirmDataDestinationDisclosure() } },
          cancel: appModel.cancelDataDestinationDisclosure
        )
      }
    }
  }

  private var activeRunTaskID: TaskID? {
    appModel.activeRunTaskID
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("搜索历史", text: .constant(""))
          .textFieldStyle(.plain)
          .disabled(true)
      }
      .padding(.horizontal, 8)
      .frame(width: 320, height: 28)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
      .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityIdentifier("history-search-disabled")
      if model.isReadOnly {
        Label("只读", systemImage: "lock.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.orange.opacity(0.16), in: Capsule())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10).padding(.bottom, 8)
          .accessibilityIdentifier("history-read-only-banner")
      }
      switch model.listState {
      case .idle where model.rows.isEmpty:
        ProgressView("正在载入历史记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loading where model.rows.isEmpty:
        ProgressView("正在载入历史记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        Spacer()
      case .failed where model.rows.isEmpty:
        VStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle").font(.title2)
          Text("无法载入历史记录").font(.headline)
          if model.canRetryList { Button("重试", action: model.retryList) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded, .loading, .failed, .idle:
        List(selection: $model.selectedTaskID) {
          ForEach(model.rows, id: \.taskID) { row in
            HistoryRowView(row: row).tag(row.taskID).onAppear { model.loadNextPageIfNeeded(after: row) }
          }
          if model.isLoadingNextPage { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() } }
          else if model.listErrorCode != nil, model.canRetryList {
            HStack { Text("无法载入更多").foregroundStyle(.secondary); Spacer(); Button("重试", action: model.retryList) }
          }
        }.listStyle(.sidebar)
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch model.detailState {
    case .loading:
      ProgressView("正在载入详情…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.title2); Text("无法载入这条记录").font(.headline); Button("重试", action: model.retryDetail) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      if let detail = model.detail { HistoryDetailView(detail: detail, model: model, appModel: appModel) }
    case .idle:
      emptyDetail
    }
  }

  private var emptyDetail: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
      Text("还没有保存页面").font(.system(size: 17, weight: .semibold))
      Text("在 LinkDigest 中接收浏览器页面后，可在这里总结或翻译。")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button {} label: { Label("添加链接", systemImage: "link.badge.plus") }.disabled(true)
        Button {} label: { Label("从剪贴板添加链接", systemImage: "doc.on.clipboard") }.disabled(true)
      }.padding(.top, 4)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var blockingError: some View {
    VStack(spacing: 14) {
      Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
      Text("无法打开历史记录").font(.title2.weight(.semibold))
      Text("LinkDigest 未对数据进行写入。请检查本机存储后重新启动 LinkDigest。")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(minWidth: 820, minHeight: 560).accessibilityIdentifier("history-blocking-error")
  }
}

private struct HistoryRowView: View {
  let row: HistoryRowProjection
  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "doc.text").foregroundStyle(.secondary).padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title?.trimmedNonEmpty ?? "无标题").font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(row.canonicalURL).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Text("\(historyAction(row.latestRunKind)) · \(historyDate(row.latestRunAtMilliseconds ?? row.updatedAtMilliseconds))")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
    }.padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 68, alignment: .leading)
  }
}

private struct HistoryDetailView: View {
  let detail: HistoryDetailProjection
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  private var newestRun: HistoryDetailProjection.RunDetail? { detail.runs.last }
  private var latestArtifact: HistoryArtifact? { detail.runs.reversed().compactMap(\.artifact).first }
  private var title: String { detail.snapshots.last?.title?.trimmedNonEmpty ?? "无标题" }
  private var sourceURL: String { detail.snapshots.last?.sourceURL ?? detail.task.canonicalURL }
  private var showsCurrentCapture: Bool { appModel.currentCapture?.taskID == detail.task.id }
  private var showsVisibleRun: Bool { appModel.showsVisibleRun(for: detail.task.id) }
  private var activeRunTaskID: TaskID? {
    appModel.activeRunTaskID
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if model.isReadOnly { ReadOnlyHistoryCallout(reason: model.historyReadOnlyReason) }
        Text(title).font(.system(size: 30, weight: .bold)).lineLimit(3)
        Text(sourceURL).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        metadata.padding(.top, 6)
        if showsCurrentCapture || showsVisibleRun { captureAndRunControls }
        Divider().padding(.top, 4).padding(.bottom, 5)
        content
      }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 56).padding(.trailing, 32).padding(.top, 36).padding(.bottom, 40)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Button("导出 Markdown (.md)") { model.requestExport(.markdown) }
          Button("导出纯文本 (.txt)") { model.requestExport(.plainText) }
          Button("导出 JSON (.json)") { model.requestExport(.json) }
        } label: {
          Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.canExport)
        .accessibilityIdentifier("export-history")
        disabledAction("重新运行", image: "arrow.clockwise")
        Button { model.requestDeletion(protectedTaskID: activeRunTaskID) } label: { Label("删除", systemImage: "trash") }
          .disabled(!model.canDelete(protectedTaskID: activeRunTaskID)).accessibilityIdentifier("delete-history")
        disabledAction("格式", image: "textformat")
      }
    }
    .accessibilityIdentifier("history-detail")
  }

  private var metadata: some View {
    VStack(alignment: .leading, spacing: 8) {
      metadataRow {
        MetadataItem(symbol: "wand.and.stars", title: "操作", value: newestRun.map { historyAction($0.run.kind) } ?? "—")
        MetadataItem(symbol: "cpu", title: "模型", value: newestRun?.run.model?.trimmedNonEmpty ?? "—")
        MetadataItem(symbol: "calendar", title: "创建时间", value: historyDate(detail.task.createdAtMilliseconds))
      }
      metadataRow {
        MetadataItem(symbol: "number", title: "Token", value: newestRun?.run.usageCost.totalTokens.map(String.init) ?? "—")
        MetadataItem(symbol: "dollarsign.circle", title: "费用", value: historyCost(newestRun?.run.usageCost))
        MetadataItem(symbol: "checkmark.circle", title: "状态", value: newestRun.map { historyStatus($0.run.status) } ?? "—")
      }
    }
  }

  private func metadataRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var content: some View {
    if let artifact = latestArtifact, !artifact.bodyText.isEmpty {
      if artifact.completeness == .partial { Label("结果不完整", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
      Text(artifact.bodyText).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    } else if let snapshot = detail.snapshots.last, !snapshot.bodyText.isEmpty {
      Text(snapshot.bodyText).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    } else { Text("暂无可显示的结果").foregroundStyle(.secondary) }
  }

  private var captureAndRunControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsCurrentCapture {
        currentCaptureActions
      }
      if showsVisibleRun {
        visibleRunControls
      }
    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  private var currentCaptureActions: some View {
    Group {
      HStack(spacing: 8) {
        Text(appModel.connection)
        Text("·")
        Text(appModel.storageStatusText)
      }
      .font(.caption)
      .foregroundStyle(appModel.storageAvailability.isWriteReady ? Color.secondary : Color.orange)
      .accessibilityIdentifier("storage-availability")
      HStack(spacing: 10) {
        Button("总结") { Task { await appModel.summarize() } }.disabled(!appModel.canStartRun).accessibilityIdentifier("summarize-current-capture")
        Button("翻译") { Task { await appModel.translate() } }.disabled(!appModel.canStartRun).accessibilityIdentifier("translate-current-capture")
      }
      if let notice = appModel.dataDestinationNotice {
        Label(notice, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("data-destination-notice")
      }
    }
  }

  private var visibleRunControls: some View {
    Group {
      if appModel.canStopVisibleRun(for: detail.task.id) {
        Button("停止", role: .cancel) { Task { await appModel.stop() } }.accessibilityIdentifier("stop-model-run")
      }
      Text(appModel.runStatusText).font(.caption).foregroundStyle(appModel.runHasFailure ? .red : .secondary).accessibilityIdentifier("model-run-status")
      if !appModel.runResultText.isEmpty { Text(appModel.runResultText).font(.system(size: 14)).textSelection(.enabled).accessibilityIdentifier("model-run-output") }
    }
  }

  private func disabledAction(_ title: String, image: String) -> some View {
    Button {} label: { Label(title, systemImage: image) }.disabled(true).help("将在后续版本提供")
  }
}

private struct DataDestinationDisclosureView: View {
  let disclosure: DataDestinationDisclosure
  let isConfirming: Bool
  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "arrow.up.doc")
          .font(.system(size: 26))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("发送前确认")
            .font(.title3.weight(.semibold))
          Text(actionText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      Text("本次将把网页标题和正文发送到以下模型目的地：")
        .font(.system(size: 13))

      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("服务") {
          Text(disclosure.identity.host)
            .textSelection(.enabled)
            .accessibilityLabel("模型服务主机 \(disclosure.identity.host)")
        }
        LabeledContent("Base URL") {
          Text(disclosure.identity.normalizedBaseURL)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        LabeledContent("模型", value: disclosure.identity.model)
        LabeledContent("接口", value: "OpenAI-compatible Chat Completions")
      }
      .font(.system(size: 13))
      .padding(12)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 5) {
        Label("API Key 仍只保存在本机 Keychain，不会显示在此处。", systemImage: "key.horizontal")
        Label("历史记录与导出仍只保存在本机。", systemImage: "internaldrive")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("取消", role: .cancel, action: cancel)
          .disabled(isConfirming)
          .accessibilityIdentifier("data-destination-cancel")
        Button("确认并发送", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(isConfirming)
          .accessibilityIdentifier("data-destination-confirm")
      }
      if isConfirming {
        ProgressView("正在确认发送目的地…")
          .controlSize(.small)
      }
    }
    .padding(24)
    .frame(width: 480)
    .accessibilityIdentifier("data-destination-disclosure")
  }

  private var actionText: String {
    disclosure.intent == .translate ? "确认翻译正文的发送目的地。" : "确认总结正文的发送目的地。"
  }
}

private struct HistoryExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { writableContentTypes }
  static var writableContentTypes: [UTType] { [markdownContentType, .plainText, .json] }
  let data: Data

  init(_ file: HistoryExportFile) { data = file.data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private let markdownContentType = UTType(filenameExtension: "md", conformingTo: .plainText)
  ?? UTType(exportedAs: "com.linkdigest.markdown", conformingTo: .plainText)

private func uniformType(for format: HistoryExportFormat) -> UTType {
  switch format {
  case .markdown: markdownContentType
  case .plainText: .plainText
  case .json: .json
  }
}

private func isUserCancelledExport(_ error: Error) -> Bool {
  let cocoa = error as NSError
  return cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.userCancelled.rawValue
}

private struct ReadOnlyHistoryCallout: View {
  let reason: RepositoryRecoveryReason?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock.fill")
        .foregroundStyle(.orange)
        .padding(.top, 1)
      Text(message)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  private var message: String {
    switch reason {
    case .futureSchema:
      "这份历史由较新版本创建，当前仅可浏览。原数据未修改；请使用较新版本的 LinkDigest 后再编辑或删除。"
    case .migrationFailed:
      "这份历史的迁移未完成，当前仅可浏览。原数据未修改；请在恢复后重新启动 LinkDigest，再编辑或删除。"
    case .storageUnavailable:
      "本地历史暂时无法以可写方式打开，当前仅可浏览。原数据未修改；请检查本机存储后重新启动 LinkDigest，再编辑或删除。"
    case nil:
      "本地历史当前仅可浏览。原数据未修改；请在恢复后重新启动 LinkDigest，再编辑或删除。"
    }
  }
}

private struct MetadataItem: View {
  let symbol: String; let title: String; let value: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Image(systemName: symbol).frame(width: 14)
      Text(title)
      Text(value).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
private extension String { var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
private func historyDate(_ milliseconds: Int64?) -> String { guard let milliseconds else { return "—" }; return Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(date: .abbreviated, time: .shortened) }
private func historyAction(_ kind: RunKind?) -> String { kind == .translate ? "翻译" : kind == .summarize ? "总结" : "—" }
private func historyStatus(_ status: RunStatus) -> String { switch status { case .queued: "等待中"; case .running: "处理中"; case .completed: "已完成"; case .stopped: "已停止"; case .failed: "未完成"; case .interrupted: "已中断" } }
private func historyCost(_ usage: RunUsageCost?) -> String { guard let micros = usage?.costAmountMicros, let currency = usage?.costCurrencyCode else { return "—" }; return "\(currency) \(Decimal(micros) / 1_000_000)" }
