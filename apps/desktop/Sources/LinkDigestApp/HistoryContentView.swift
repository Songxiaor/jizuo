import AppKit
import AVKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import LinkDigestAdapters
import LinkDigestCore

struct HistoryContentView: View {
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var manualLink: ManualLinkViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  /// 「记一个新灵感」的输入框。
  @State private var isNewSparkPresented = false
  @State private var newSparkText = ""
  // 标签是低频筛选，不该在每次启动时抢走半个导航栏。需要时再展开，
  // 当前已选标签仍由 ViewModel 保留，不会因为折叠而丢失筛选状态。
  @State private var navigationTagsExpanded = false
  @FocusState private var isSearchFocused: Bool
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(ExperimentalFeatures.workbenchKey) private var isWorkbenchUserEnabled = false
  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  @AppStorage("onboarding.capture-v1.dismissed") private var isCaptureOnboardingDismissed = false
  /// 灯箱打开时窗口级分栏细线需要让位，避免画在放大的图片上。
  @ObservedObject private var inlineImageLightbox = InlineImageLightboxController.shared
  @ObservedObject private var videoCinema = VideoCinemaController.shared
  /// 列表选中即可预热远程播放；详情卡与预热共享，快速切换时由 controller 取消上一次 prepare。
  @StateObject private var remotePreviewPlayback = RemotePreviewPlayerController()

  private var appearanceTheme: AppearanceTheme { AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass }
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }
  /// 工作台的四处入口都问它，不各自与开关做 `&&`。
  private var isWorkbenchVisible: Bool {
    ExperimentalFeatures.isWorkbenchVisible(userEnabled: isWorkbenchUserEnabled)
  }

  private func synchronizeRemotePreviewPreheat() {
    // 1) 当前抓取可播
    if let target = RemotePlaybackPreheat.playableTarget(
      selectedTaskID: model.selectedTaskID,
      currentCapture: appModel.currentCapture
    ) {
      let duration = appModel.currentCapture?.mediaDescriptor?.durationSeconds
      remotePreviewPlayback.prepare(
        url: target.url,
        companionAudioURL: target.companionAudioURL,
        durationSeconds: duration
      )
      return
    }
    // 2) 历史会话 LRU 里的 descriptor（切换条目时不要 release 毁掉已就绪播放器）
    if let taskID = model.selectedTaskID,
       let descriptor = sessionMediaPlayback.cachedDescriptor(for: taskID),
       case let .playable(url, _, companion) = CurrentCaptureMediaPreview.resolve(descriptor) {
      remotePreviewPlayback.prepare(
        url: url,
        companionAudioURL: companion,
        durationSeconds: descriptor.durationSeconds
      )
      return
    }
    // 3) 无可播目标：驻留当前 ready 播放器，不销毁（回来可秒开）
    remotePreviewPlayback.parkAndIdle()
  }

  var body: some View {
    themedBody
      .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
      // 图片灯箱盖在整个窗口内容之上；点击图外区域或 Esc 退出。
      .overlay { InlineImageLightboxOverlay() }
      // 「已复制」药丸浮层：任何复制动作的统一视觉确认。
      .overlay { CopyFeedbackOverlay() }
      // 视频影院放大 overlay（任何来源）：自己的框，替代坑多的原生全屏。
      .overlay { VideoCinemaOverlay() }
      .foregroundStyle(theme.primaryText)
      .tint(theme.accent)
      .accentColor(theme.accent)
      .onAppear {
        AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw)
        synchronizeRemotePreviewPreheat()
        appModel.startQueuedMindMap = { [weak model] taskID in
          model?.requestMindMapGeneration(taskID: taskID)
        }
      }
      .onChange(of: model.isBatchSummarizing) { _, summarizing in
        appModel.defersQueuedGeneration = summarizing
        if !summarizing {
          Task { await appModel.startNextQueuedGenerationIfIdle() }
        }
      }
      .task { await browserSupport.load() }
      .onChange(of: firstCaptureIsComplete) { _, completed in
        if completed { isCaptureOnboardingDismissed = true }
      }
      .onChange(of: model.selectedTaskID) { _, _ in
        synchronizeRemotePreviewPreheat()
      }
      // 自动处理管线：新捕获（浏览器/手动链接）到达即按设置勾选步骤串行处理。
      .onChange(of: appModel.currentCapture?.taskID) { _, newTaskID in
        synchronizeRemotePreviewPreheat()
        guard let taskID = newTaskID else { return }
        let settings = providerSettings
        if let requestedAction = appModel.currentCapture?.requestedAction {
          if requestedAction == .save { return }
          if requestedAction == .summarize || requestedAction == .translate {
            model.startRequestedAction(taskID: taskID) { [weak appModel] detail in
              guard let appModel else { return }
              if requestedAction == .translate {
                await appModel.translate(historyDetail: detail, preferences: settings.runPreferences)
              } else {
                await appModel.summarize(historyDetail: detail, preferences: settings.runPreferences)
              }
            }
            return
          }
        }
        let preferences = settings.runPreferences
        model.startAutoPipeline(
          taskID: taskID,
          expectsMedia: appModel.currentCapture?.shouldAutomaticallyPersistLegacyMedia == true,
          transcribe: settings.autoTranscribeNewCaptures,
          tidy: settings.autoTidyTranscription,
          summarize: settings.autoSummarizeNewCaptures,
          mindMap: settings.autoMindMapNewCaptures,
          tidyModel: settings.effectiveTidyModelName,
          summarizeAction: { [weak appModel] detail in
            guard let appModel else { return false }
            return await appModel.startAutomaticSummary(
              historyDetail: detail,
              preferences: preferences
            )
          },
          isSummaryBusy: { [weak appModel] in
            guard let appModel else { return false }
            return appModel.runState.isActive
              || appModel.isDataDestinationDisclosurePresented
              || appModel.isConfirmingDataDestinationDisclosure
          }
        )
      }
      .onChange(of: appearanceThemeRaw) { _, newValue in
        AppearanceTheme.applyApplicationAppearance(newValue)
      }
  }

  private var themedBody: some View {
    Group {
      if model.blockingErrorCode != nil {
        blockingError
      } else {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          navigationRail.navigationSplitViewColumnWidth(
            min: DesignTokens.Layout.sidebarMin,
            ideal: DesignTokens.Layout.sidebarIdeal,
            max: DesignTokens.Layout.sidebarMax
          )
          .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
        } content: {
          // 工作台接管中间列：它列的是「正在做的创作」，和历史条目不是一种东西，
          // 塞进同一个列表只会让两边的排序、筛选、多选互相打架。
          Group {
            if model.isWorkbenchActive, isWorkbenchVisible {
              WorkbenchListView(
                model: model,
                onNewSpark: { isNewSparkPresented = true },
                onTakeTopic: takeTopic
              )
            } else {
              sidebar
            }
          }
          .navigationSplitViewColumnWidth(
            min: DesignTokens.Layout.listMin,
            ideal: DesignTokens.Layout.listIdeal,
            max: DesignTokens.Layout.listIdeal + DesignTokens.Space.xxl
          )
          .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
        } detail: {
          detailColumn
            .modifier(HistoryWindowToolbarThemeModifier(theme: theme, background: theme.card))
        }
          // 窗口级分栏细线：贯通工具栏直达窗口顶；系统玻璃主题走原生外观，
          // 图片灯箱打开时移除，避免细线盖在放大的图片上。
          .background(WindowColumnDividerInstaller(
            lineColor: (theme.isNative || inlineImageLightbox.url != nil || videoCinema.isPresented) ? nil : NSColor(theme.hairline)
          ))
          .alert(model.deletionConfirmationTitle, isPresented: $model.isDeleteConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelDeletion() }
            Button("删除", role: .destructive) { model.confirmDeletion(protectedTaskIDs: protectedTaskIDs) }
          } message: { Text(model.deletionConfirmationMessage) }
          .alert("正在生成结果", isPresented: $model.isProtectedDeletionAlertPresented) {
            Button("好") { model.dismissProtectedDeletionAlert() }
          } message: {
            Text("选中的记录正在执行生成、转写或识别任务。请先取消对应任务，再删除记录。")
          }
          .alert("无法删除这条历史记录", isPresented: $model.isDeleteFailurePresented) {
            Button("好") { model.dismissDeleteFailure() }
          } message: { Text("本地历史未发生删除，请稍后重试。") }
          .alert("删除结果", isPresented: $model.isDeleteOutcomePresented) {
            Button("好") { model.dismissDeleteOutcome() }
          } message: { Text(model.deleteOutcomeMessage) }
          .sheet(isPresented: $isNewSparkPresented) { newSparkSheet }
          .alert("工作台", isPresented: Binding(
            get: { model.workbenchFailure != nil },
            set: { if !$0 { model.dismissWorkbenchFailure() } }
          )) {
            Button("好") { model.dismissWorkbenchFailure() }
          } message: { Text(model.workbenchFailure ?? "") }
          // 批量总结要花钱，确认弹窗里先给出粗估 token 量级再让用户点。
          .alert(
            model.batchSummaryConfirmationTitle,
            isPresented: $model.isBatchSummaryConfirmationPresented
          ) {
            Button("取消", role: .cancel) { model.cancelBatchSummaryRequest() }
            Button("开始总结") {
              let preferences = providerSettings.runPreferences
              model.confirmBatchSummary(
                summarize: { [weak appModel] detail in
                  await appModel?.summarize(historyDetail: detail, preferences: preferences)
                },
                // 数据去向确认弹窗开着也算「忙」：首条常常要等用户确认一次，
                // 不把它算进去就会被误判成「没能开始」而中止整批。
                isBusy: { [weak appModel] in
                  guard let appModel else { return false }
                  return appModel.runState.isActive
                    || appModel.isDataDestinationDisclosurePresented
                    || appModel.isConfirmingDataDestinationDisclosure
                }
              )
            }
          } message: { Text(model.batchSummaryConfirmationMessage) }
          .alert("批量总结结果", isPresented: $model.isBatchSummaryOutcomePresented) {
            Button("好") { model.dismissBatchSummaryOutcome() }
          } message: { Text(model.batchSummaryOutcomeMessage) }
          .alert("无法准备导出", isPresented: $model.isExportPreparationFailurePresented) {
            Button("好") { model.dismissExportPreparationFailure() }
          } message: { Text("无法准备导出，请检查历史记录后重试。") }
          .alert("无法保存导出文件", isPresented: $model.isExportSaveFailurePresented) {
            Button("好") { model.dismissExportSaveFailure() }
          } message: { Text("请检查所选文件夹的权限后重试。") }
          .alert("视频自动保存失败", isPresented: $model.isCapturedMediaAutoSaveFailurePresented) {
            Button("好") { model.dismissCapturedMediaAutoSaveFailure() }
          } message: { Text(model.capturedMediaAutoSaveFailureMessage) }
          .alert("需要下载 Apple 离线听写模型", isPresented: $model.isTranscriptionModelConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelModelDownloadConfirmation() }
            Button("下载并转写") { model.confirmModelDownloadAndTranscribe() }
          } message: {
            Text("Apple 离线听写模型可能需要下载并占用本机空间。会按视频配文判断中文或英文。模型准备完成后，视频音频只在这台 Mac 上处理，不会上传。")
          }
          .alert("将视频音频发送到在线转写服务？", isPresented: $model.isOnlineTranscriptionConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelOnlineTranscriptionConfirmation() }
            Button("同意并在线转写") { model.confirmOnlineTranscription() }
          } message: {
            Text("App 会在本机从视频流提取短音频分片，再发送到你配置的 /audio/transcriptions 服务。完整视频和带签名的视频 URL 不会交给模型商家；文字会保存到本机历史。")
          }
          .alert("将转写文字发送给聊天模型校对？", isPresented: $model.isTranscriptTidyConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelTranscriptTidyConfirmation() }
            Button("同意并校对") { model.confirmTranscriptTidy() }
          } message: {
            Text("App 会发送转写文字，以及标题和配文作为上下文，用来还原听写错误、补标点和分段。不发送视频、音频或链接。看不懂的句子会原样保留。校对稿保存为最新原文，原始转写稿保留在历史中。")
          }
          .fileExporter(
            isPresented: $model.isExportPanelPresented,
            document: model.exportFile.map(HistoryExportDocument.init),
            contentType: uniformType(for: model.exportFile?.format ?? .plainText),
            defaultFilename: model.exportFile?.suggestedFilename ?? "\(ProductDisplay.name) 历史.txt"
          ) { result in
            switch result {
            case .success: model.completeExportSave()
            case let .failure(error) where isUserCancelledExport(error): model.cancelExport()
            case .failure: model.failExportSave()
            }
          }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        // 批量总结进行中：进度和停止按钮必须一直可见，否则「跑了十几分钟、
        // 现在到哪了、能不能停」全靠猜。
        if model.isBatchSummarizing {
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(model.batchSummaryProgressText)
              .lineLimit(1)
              .truncationMode(.middle)
          }
            .themedFont(.callout, weight: .medium)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(theme.info.opacity(0.10), in: Capsule())
            .frame(maxWidth: 300, alignment: .trailing)
            .accessibilityIdentifier("batch-summarize-progress")
          Button("停止") { model.stopBatchSummary() }
            .disabled(model.batchSummaryProgress?.isStopping == true)
            .accessibilityIdentifier("batch-summarize-stop")
        }
        if model.selectedTaskCount > 1 {
          Button { model.requestBatchSummary() } label: {
            Label("总结选中项", systemImage: "text.badge.checkmark")
          }
          .disabled(!model.canBatchSummarize)
          .help("总结选中的历史条目")
          .accessibilityLabel("总结选中项")
          .accessibilityIdentifier("batch-summarize-history")
          Button { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) } label: {
            Label("删除选中项", systemImage: "trash")
          }
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
          .help("删除选中的历史条目")
          .accessibilityLabel("删除选中项")
          .accessibilityIdentifier("delete-selected-history")
        }
        ControlGroup {
          Button(action: { openSettings() }) {
            Label("模型设置", systemImage: "gearshape")
          }
          .help("打开设置")
          .accessibilityLabel("模型设置")
          .accessibilityIdentifier("open-provider-settings")
          Menu {
            Button("添加链接", action: manualLink.open)
            Button("从剪贴板添加链接", action: manualLink.readClipboardAndOpen)
          } label: {
            Label("添加链接", systemImage: "link.badge.plus")
          }
          .disabled(!manualLink.canOpen)
          .help("添加一个或多个链接")
          .accessibilityLabel("添加链接")
          .accessibilityIdentifier("manual-link-add-toolbar")
          Button(action: createNote) {
            Label("新建笔记", systemImage: "square.and.pencil")
          }
          .disabled(!manualLink.canOpen)
          .help("新建笔记")
          .accessibilityLabel("新建笔记")
          .accessibilityIdentifier("create-user-note")
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
    .sheet(isPresented: Binding(get: { manualLink.isPresented }, set: { if !$0 { manualLink.dismiss() } })) {
      ManualLinkSheet(
        model: manualLink,
        modelCallDisclosure: AutomaticModelCallDisclosure(
          autoSummarize: providerSettings.autoSummarizeNewCaptures,
          autoMindMap: providerSettings.autoMindMapNewCaptures,
          mayAutoTidyVideoTranscript: providerSettings.autoTranscribeNewCaptures
            && providerSettings.autoTidyTranscription
        )
      )
    }
  }

  private var protectedTaskIDs: Set<TaskID> {
    var result: Set<TaskID> = []
    if let taskID = appModel.activeRunTaskID { result.insert(taskID) }
    if model.transcriptionState.isActive, let taskID = model.transcriptionTaskID { result.insert(taskID) }
    if model.imageTextRecognitionState == .recognizing,
       let taskID = model.imageTextRecognitionTaskID { result.insert(taskID) }
    return result
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        // 提示语要说清搜的范围。写「搜索历史」时用户不会想到能搜正文，
        // 于是有了这个能力也用不上。
        //
        // 「总结」必须留在这里：能搜总结是仓库里最刻意实现的一条能力
        // （见 GRDBHistoryRepository 里遍历全部 artifacts 的那段 EXISTS），
        // 而这行占位文字是它唯一的曝光入口。要缩短就砍「作者」——作者没有
        // 独立列，本来就只是搜正文时顺带覆盖到的。
        TextField("搜索标题、正文、总结、标签", text: $model.searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity)
      .frame(height: 30)
      // 白底圆角搜索胶囊浮在暖色列表面板上，与参考稿的搜索框一致。
      .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
      .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(theme.hairline, lineWidth: 1))
      .padding(.horizontal, 10).padding(.vertical, 10)
        .accessibilityIdentifier("history-search")
        .background(ReleaseInitialSearchFocus().allowsHitTesting(false))
      if model.isReadOnly {
        Label("只读", systemImage: "lock.fill")
          .themedFont(.caption, weight: .semibold)
          .foregroundStyle(theme.primaryText)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(theme.warning.opacity(0.14), in: Capsule())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10).padding(.bottom, 8)
          .accessibilityIdentifier("history-read-only-banner")
      }
      if let suggestion = manualLink.clipboardSuggestion {
        ClipboardSuggestionBanner(
          suggestion: suggestion,
          capture: manualLink.captureClipboardSuggestion,
          ignore: manualLink.ignoreClipboardSuggestion
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
      switch model.listState {
      case .idle where model.rows.isEmpty:
        HistorySkeletonList(theme: theme)
      case .loading where model.rows.isEmpty:
        HistorySkeletonList(theme: theme)
      case .empty:
        if model.hasActiveFilter {
          HistoryInlineState(
            symbol: "line.3.horizontal.decrease.circle",
            title: model.hasCategoryFilter ? "该分类下暂无内容" : "没有搜索结果",
            message: "调整搜索词或筛选条件后再试。"
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-filter-empty")
        } else {
          // 没有任何内容时也要说话：纯空白分不清「扫完了没有」和「还没加载」。
          // 完整的三步引导在详情列，这里只给一句轻量状态。
          HistoryInlineState(
            symbol: "tray",
            title: "还没有保存的内容",
            message: "粘贴一条公开链接，或用浏览器扩展保存当前页面后，会显示在这里。"
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-empty")
        }
      case .failed where model.rows.isEmpty:
        if model.canRetryList {
          HistoryInlineState(
            symbol: "exclamationmark.triangle",
            title: "无法载入历史记录",
            message: "本机历史没有显示，当前不会写入新的变更。",
            actionTitle: "重试",
            action: { model.retryList() }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          HistoryInlineState(
            symbol: "exclamationmark.triangle",
            title: "无法载入历史记录",
            message: "本机历史没有显示，当前不会写入新的变更。"
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      case .loaded, .loading, .failed, .idle:
        List(selection: $model.selectedTaskIDs) {
          // 排队抓取区：提交链接后立刻回到列表，这里可见进度/失败重试，
          // 不再让用户守着弹窗转圈。
          if !manualLink.pendingCaptures.isEmpty {
            Section {
              ForEach(manualLink.pendingCaptures) { pending in
                PendingCaptureRow(pending: pending, model: manualLink)
              }
            } header: {
              Text("抓取队列").themedFont(.caption).foregroundStyle(.secondary)
            }
          }
          ForEach(model.rows, id: \.taskID) { row in
            HistoryRowView(
              row: row,
              isSelected: model.selectedTaskIDs.contains(row.taskID),
              faviconURL: model.faviconImageURL(for: row),
              theme: theme
            ).equatable().tag(row.taskID).onAppear { model.loadNextPageIfNeeded(after: row) }
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
              .contextMenu {
                Button { openHistoryURL(row.canonicalURL) } label: { Label("在浏览器中打开", systemImage: "safari") }
                Button { copyHistoryURL(row.canonicalURL) } label: { Label("复制链接", systemImage: "doc.on.doc") }
                if model.selectedTaskIDs.contains(row.taskID), model.selectedTaskCount > 1 {
                  Divider()
                  Button { model.requestBatchSummary() } label: {
                    Label("总结选中的 \(model.selectedTaskCount) 条…", systemImage: "text.badge.checkmark")
                  }
                  .disabled(!model.canBatchSummarize)
                  .accessibilityIdentifier("batch-summarize-history-context")
                }
                // 攒素材天然是跨来源的:一篇网页 + 两条笔记 + 一段转写。
                // 所以入口放在每一行上,而不是只在工作台里面找。
                let unfinished = model.pieces.filter { !$0.isFinished }
                // 入口隐藏时这一项也得跟着消失,否则就是「侧边栏没有工作台,
                // 右键却还能往里加素材」——加进去的东西再也打不开。
                if isWorkbenchVisible, !unfinished.isEmpty {
                  Divider()
                  Menu {
                    ForEach(unfinished) { piece in
                      Button(piece.title) { model.addMaterial(taskID: row.taskID, to: piece.id) }
                    }
                  } label: {
                    Label("加入工作台", systemImage: "hammer")
                  }
                  .accessibilityIdentifier("add-material-to-piece")
                }
                Divider()
                Button(role: .destructive) {
                  if !model.selectedTaskIDs.contains(row.taskID) {
                    model.selectedTaskIDs = [row.taskID]
                  }
                  model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
                } label: { Label("删除…", systemImage: "trash") }
                .disabled(model.isReadOnly || model.isDeleting)
              }
          }
          if model.isLoadingNextPage { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() } }
          else if model.listErrorCode != nil, model.canRetryList {
            HStack { Text("无法载入更多").foregroundStyle(.secondary); Spacer(); Button("重试", action: model.retryList) }
          }
        }.listStyle(.sidebar)
          .scrollContentBackground(.hidden)
          .onDeleteCommand { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) }
          // macOS List 对插入行沿用估算行高，新到卡片被压扁；初始构建
          // 的测量始终正确，因此新条目登顶时整表重建（新行本就在顶部，
          // 不损失滚动位置），行高恢复按真实内容计算。
          .id(model.rows.first?.taskID)
      }
    }
    .frame(maxWidth: .infinity)
    .background(theme.listPane.opacity(theme.isNative ? 0 : 1))
    .focusedSceneValue(\.focusHistorySearch, FocusHistorySearchAction { isSearchFocused = true })
    .focusedSceneValue(\.newNote, NewNoteAction { createNote() })
    .focusedSceneValue(\.todayNote, TodayNoteAction { openTodayNote() })
  }

  private var navigationRail: some View {
    List {
      Section {
        navigationButton("全部", systemImage: "tray.full", count: model.navigationCounts.all, selected: model.selectedScope == .all && !model.hasCategoryFilter) {
          model.selectScope(.all)
        }
        .accessibilityIdentifier("history-navigation-all")
        navigationButton("最近", systemImage: "clock", count: model.navigationCounts.recent, selected: model.selectedScope == .recent) {
          model.selectScope(.recent)
        }
        .accessibilityIdentifier("history-navigation-recent")
        navigationButton("未总结", systemImage: "text.badge.xmark", count: model.navigationCounts.unsummarized, selected: model.selectedScope == .unsummarized) {
          model.selectScope(.unsummarized)
        }
        .accessibilityIdentifier("history-navigation-unsummarized")
        navigationButton("收藏", systemImage: "star", count: model.navigationCounts.favorite, selected: model.selectedScope == .favorite) {
          model.selectScope(.favorite)
        }
        .accessibilityIdentifier("history-navigation-favorite")
      }

      // 笔记自成一区，不混进上面那组，也不进「平台」。
      //
      // 上面几项都是在看**抓来的资料**的不同切面；笔记是自己写的东西，是另一种
      // 材料。放在一起会让「全部」这个词失真，也会让找素材和写东西互相打断。
      Section {
        navigationButton(
          "我的笔记",
          systemImage: "square.and.pencil",
          count: model.navigationCounts.notes,
          selected: model.selectedScope == .notes
        ) {
          model.selectScope(.notes)
        }
        .accessibilityIdentifier("history-navigation-notes")
        // 「今天」不是一个筛选项，是一个动作——点它直接进今天那条笔记。
        // 随手记东西最大的摩擦是「这条该记去哪」，给每天一个默认容器就没这个决定了。
        Button(action: openTodayNote) {
          Label("今天", systemImage: "calendar")
            .themedFont(.body)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-navigation-today-note")
      }

      // 输出:已完成的作品。三个模块里的第三个。
      //
      // 它和「我的笔记」并列而不是嵌在工作台里:作品做完就离开车间了,
      // 你回头找它是因为想看「我做过什么」,不是想回到那件创作的过程。
      if model.navigationCounts.works > 0 {
        Section {
          navigationButton(
            "我的作品",
            systemImage: "checkmark.seal",
            count: model.navigationCounts.works,
            selected: model.selectedScope == .works
          ) {
            model.selectScope(.works)
          }
          .accessibilityIdentifier("history-navigation-works")
        }
      }

      // 工作台是第三种东西:上面是「抓来的资料」,笔记是「随手写的」,
      // 这里是「正在做的作品」。它的单位是一件创作,不是一条记录,
      // 所以自成一节而不是混进上面的筛选项。
      //
      // v1 默认藏起来(设置→实验室里可开):它的正文现在直接存成一条笔记,
      // 三模块切开后这个模型要改。默认开放等于给自己攒一堆将来必须迁移的
      // 数据,而当前它还没接 AI,手动建创作的价值抵不上迁移成本。
      if isWorkbenchVisible {
      Section {
        Button { model.enterWorkbench() } label: {
          HStack(spacing: 8) {
            Image(systemName: "hammer")
              .frame(width: 18)
            Text("工作台")
              .themedFont(.body)
            Spacer()
            let active = model.pieces.filter { !$0.isFinished }.count
            if active > 0 {
              countBadge(active, selected: model.isWorkbenchActive)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isWorkbenchActive ? Color.accentColor : Color.primary)
        .accessibilityIdentifier("history-navigation-workbench")
      }
      }

      if !model.navigationCounts.platforms.isEmpty {
        // 公共平台各占一行；杂项来源聚合进"待分类"，避免侧栏被长域名占满。
        let knownPlatforms = model.navigationCounts.platforms.filter { HistoryPlatformDisplay.isWellKnown(host: $0.host) }
        let miscPlatforms = model.navigationCounts.platforms.filter { !HistoryPlatformDisplay.isWellKnown(host: $0.host) }
        // 分区标题同样要显式给字体：`Section("平台")` 那种字符串写法的标题是 List
        // 自己渲染的，和行内容一样收不到环境字体。
        Section(header: Text("平台").themedFont(.subheadline, weight: .semibold)) {
          // 平台名称必须常驻可见。只显示图标虽然省高度，但把理解成本转嫁给
          // tooltip；新的紧凑行仍然只占一行，同时给出图标、名称和数量。
          PlatformGridView(
            items: knownPlatforms.map { platform in
              let favicon = model.platformFavicon(forHost: platform.host)
              return .init(
                host: platform.host,
                count: platform.count,
                faviconURL: favicon?.url,
                faviconTaskID: favicon?.taskID
              )
            }
              + (miscPlatforms.isEmpty ? [] : [
                .init(
                  host: HistoryPlatformDisplay.miscHost,
                  count: miscPlatforms.reduce(0) { $0 + $1.count },
                  faviconURL: nil,
                  faviconTaskID: nil
                )
              ]),
            theme: theme,
            isSelected: { host in
              host == HistoryPlatformDisplay.miscHost
                ? model.selectedHosts == Set(miscPlatforms.map(\.host))
                : model.selectedHosts.contains(host)
            },
            onSelect: { host in
              if host == HistoryPlatformDisplay.miscHost {
                model.selectHosts(miscPlatforms.map(\.host))
              } else {
                model.selectHost(host)
              }
            }
          )
        }
      }

      if model.navigationCounts.tags.isEmpty {
        // 标签是"内容讲什么"：总结后由模型生成，也可在详情里手动添加。
        // 空态保留区块存在感，而不是让整块消失。
        Section(header: Text("标签").themedFont(.subheadline, weight: .semibold)) {
          Text("总结后自动生成，也可在详情中手动添加")
            .themedFont(.caption)
            .foregroundStyle(.tertiary)
        }
      } else {
        Section {
          DisclosureGroup("标签", isExpanded: $navigationTagsExpanded) {
            // 标签是跨内容的分类关键词：按引用数降序的药丸云，
            // 大类自然浮到最前。
            let ordered = model.navigationCounts.tags.sorted { $0.count > $1.count }
            let tags = model.showsAllNavigationTags ? ordered : Array(ordered.prefix(6))
            TagPillFlowLayout(spacing: 6) {
              ForEach(tags) { item in
                let selected = model.selectedTagNormalizedNames.contains(item.tag.normalizedName)
                Button {
                  // 普通点击即叠加（AND 缩小范围），再点取消；⌘点击=只看这个。
                  model.toggleTag(item.tag, additive: !NSEvent.modifierFlags.contains(.command))
                } label: {
                  HStack(spacing: 4) {
                    Text(item.tag.name).lineLimit(1)
                    Text("\(item.count)")
                      .themedFont(.caption2, monospacedDigit: true)
                      .foregroundStyle(selected ? theme.selectionText.opacity(0.8) : .secondary)
                  }
                  .themedFont(.caption)
                  .padding(.vertical, 4).padding(.horizontal, 9)
                  .background(
                    selected ? AnyShapeStyle(theme.selectionFill) : AnyShapeStyle(theme.primaryText.opacity(0.06)),
                    in: Capsule()
                  )
                  .overlay(
                    Capsule().strokeBorder(
                      selected ? Color.clear : theme.primaryText.opacity(0.12),
                      lineWidth: 1
                    )
                  )
                  .foregroundStyle(selected ? theme.selectionText : theme.primaryText)
                  .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-navigation-tag-\(item.tag.normalizedName)")
                .help("单击叠加筛选（同时命中所有已选标签），再次单击取消；按住 Command 单击只看此标签。")
              }
            }
            .padding(.vertical, 2)
            if !model.showsAllNavigationTags, model.navigationCounts.tags.count > 6 {
              Button("全部标签…") { model.showsAllNavigationTags = true }
                .accessibilityIdentifier("history-navigation-tags-all")
            }
            if !model.selectedTagNormalizedNames.isEmpty {
              Button("清空标签筛选（\(model.selectedTagNormalizedNames.count)）") { model.clearTagSelection() }
                .accessibilityIdentifier("history-navigation-tags-clear")
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(theme.isNative ? .automatic : .hidden)
    .background(theme.isNative ? Color.clear : theme.canvas)
    .accessibilityIdentifier("history-navigation-rail")
  }

  private func navigationButton(
    _ title: String,
    systemImage: String,
    count: Int,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        // 字体必须写在这里，不能靠窗口根部注入的环境字体。
        //
        // 这一行是 `List` 的行内容，而 macOS 的 List 是 NSTableView 支撑的：
        // 它会给行套上自己的字体，**盖过 `.environment(\.font,)`**。实测根部
        // 注入对详情列、工具栏、设置页都生效，唯独进不了 List 行——表现就是
        // 整扇窗都换了字体，只有侧栏这一列还是系统字体。
        Label(title, systemImage: systemImage)
          .themedFont(.body)
        Spacer()
        countBadge(count, selected: selected)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // 选中态保留品牌色，但不再整行反白。浅色底 + 左侧锚点比实心色块更安静，
    // 也让平台图标和计数继续保持原本的辨识度。
    .padding(.vertical, DesignTokens.Space.xs)
    .padding(.horizontal, DesignTokens.Space.sm)
    .background(
      selected ? theme.accent.opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if selected {
        Capsule()
          .fill(theme.accent)
          .frame(width: 3, height: 18)
          .padding(.leading, DesignTokens.Space.xxs)
      }
    }
    .foregroundStyle(theme.primaryText)
    .padding(.horizontal, -6)
    .fontWeight(selected ? .semibold : .regular)
  }

  /// 图24 式计数徽章：灰底小胶囊；选中时反白依附在蓝色药丸上。
  ///
  /// 等宽数字：侧栏这排计数常驻可见，抓到新内容时会一起变。比例字体下
  /// 9→10 的宽度跳变会让整列胶囊宽窄不一地抽动一下，等宽把它压成
  /// 只有需要进位时才变宽。
  private func countBadge(_ count: Int, selected: Bool) -> some View {
    Text("\(count)")
      .themedFont(.caption, weight: .medium, monospacedDigit: true)
      .foregroundStyle(selected ? theme.accent : .secondary)
      .padding(.horizontal, 6).padding(.vertical, 1)
      .background(selected ? theme.accent.opacity(0.12) : theme.badge, in: Capsule())
  }

  private func openHistoryURL(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    // Same inert-resolver syntax gate as Markdown links: shape check only,
    // navigation stays in the user's default browser.
    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    guard (try? policy.validateSyntax(url)) != nil else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyHistoryURL(_ raw: String) {
    CopyFeedbackController.shared.copy(raw)
  }

  /// 右侧那一列:工作台激活时是创作台,否则是常规详情页。
  ///
  /// 抽出来是编译期的需要——三个分支塞进 `NavigationSplitView` 的尾随闭包后，
  /// 类型检查会超时。
  @ViewBuilder private var detailColumn: some View {
    if model.isWorkbenchActive, isWorkbenchVisible, let piece = model.selectedPiece {
      PieceDeskView(
        model: model,
        piece: piece,
        onOpenNote: { taskID in
          // 稿子和素材都是记录，打开它们就是回到熟悉的详情页。
          model.leaveWorkbench()
          model.reveal(taskID: taskID)
        },
        onRunSummary: { taskID in
          Task {
            guard let target = model.detailProjection(for: taskID) else { return }
            await appModel.summarize(historyDetail: target, preferences: providerSettings.runPreferences)
          }
        },
        onTidy: { taskID in
          model.requestNoteTidy(taskID: taskID, model: providerSettings.effectiveTidyModelName)
        },
        onDraft: { pieceID in
          model.draftFromMaterials(
            pieceID: pieceID,
            voice: VoiceSettings.decoded(from: voiceSettingsRaw).promptText
          )
        },
        onRewrite: { pieceID, intensity in
          model.rewriteDraft(
            pieceID: pieceID,
            voice: VoiceSettings.decoded(from: voiceSettingsRaw).promptText,
            intensity: intensity
          )
        }
      )
    } else if model.isWorkbenchActive, isWorkbenchVisible {
      workbenchPlaceholder
    } else {
      detail
    }
  }

  /// 工作台里没选中任何一件时的右侧。
  private var workbenchPlaceholder: some View {
    VStack(spacing: 12) {
      Image(systemName: "hammer")
        .font(.system(size: DesignTokens.IconSize.empty))
        .foregroundStyle(.tertiary)
      Text(model.pieces.isEmpty ? "还没有在做的创作" : "从左边选一件")
        .themedFont(.title3, weight: .medium)
      Text(model.pieces.isEmpty
        ? "一个念头写下来就是一件创作。"
        : "打开后能看到它攒了哪些素材、稿子写到哪了。")
        .themedFont(.callout)
        .foregroundStyle(.secondary)
      if model.pieces.isEmpty {
        Button("记一个新灵感") { isNewSparkPresented = true }
          .buttonStyle(.borderedProminent)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 新灵感只要一句话。
  ///
  /// 不在这里问标题、不问素材、不问阶段——念头冒出来的那一刻，多问一个字
  /// 都是在劝人别记。剩下的都可以之后再补。
  private var newSparkSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("记一个新灵感")
        .themedFont(.headline)
      Text("一句话就够，之后可以随时改。")
        .themedFont(.caption)
        .foregroundStyle(.secondary)
      TextField("比如：AI 时代的内容创作是可以偷懒的", text: $newSparkText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(2...5)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).strokeBorder(theme.hairline))
        .onSubmit(commitNewSpark)
      HStack {
        Spacer()
        Button("取消") {
          isNewSparkPresented = false
          newSparkText = ""
        }
        Button("开始") { commitNewSpark() }
          .buttonStyle(.borderedProminent)
          .disabled(newSparkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  /// 从一条选题开始写。
  ///
  /// 和「记一个新灵感」走同一条路:先建正文笔记，再登记创作。差别只在
  /// 灵感那句话是用户敲的还是从候选来的——以及候选会把素材一起带过去。
  private func takeTopic(_ candidate: TopicCandidate) {
    manualLink.createPieceDraft(
      title: PieceDocument.noteTitle(forSpark: candidate.title)
    ) { taskID in
      model.takeTopic(candidate, noteTaskID: taskID)
    }
  }

  /// 建正文笔记 → 登记创作。两步都成了才关掉输入框。
  private func commitNewSpark() {
    let spark = newSparkText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spark.isEmpty else { return }
    manualLink.createPieceDraft(title: PieceDocument.noteTitle(forSpark: spark)) { taskID in
      model.registerPiece(spark: spark, noteTaskID: taskID)
      isNewSparkPresented = false
      newSparkText = ""
    } onFailure: { message in
      model.reportFailure(message)
    }
  }

  @ViewBuilder private var detail: some View {
    // 系统主题保持原生平铺；其余主题让整个详情列就是正文色，铺满到工具栏下沿。
    //
    // 原来这里是一张浮在画布上的圆角卡片，四周留 10/12pt 的画布边。代价是详情列
    // 顶上多出一条 #EFEDE5 的横带——工具栏那一带是画布色，正文卡片从它下面才开始，
    // 于是右上角自成一个灰色块，而白色的工具栏按钮正好浮在上面，成了整扇窗对比
    // 最强的地方；那里装的只是 chrome，不是内容。
    //
    // 列与列的分界不靠这圈留白，靠 `WindowColumnDividerInstaller` 那条贯通工具栏的
    // 细线，它本来就在。
    if theme.isNative {
      detailStateContent
    } else {
      detailStateContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card)
    }
  }

  @ViewBuilder private var detailStateContent: some View {
    if model.selectedTaskCount > 1 {
      VStack(spacing: 12) {
        Image(systemName: "checklist.checked")
          .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
          .foregroundStyle(.secondary)
        Text("已选择 \(model.selectedTaskCount) 项").themedFont(.title2, weight: .semibold)
        Text("可从工具栏、右键菜单或 Delete 键批量删除；导出、标签、识别和转写等单条能力暂不可用。")
          .themedFont(.body)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("history-multi-selection-placeholder")
    } else if let detail = model.detail {
      articleDetail(detail: detail)
    } else {
      switch model.detailState {
    case .loading:
      ProgressView("正在载入详情…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.title2); Text("无法载入这条记录").themedFont(.headline); Button("重试", action: model.retryDetail) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      // 成功路径总是先写 detail 再翻 .loaded，走不到这里；只为 switch 穷尽。
      EmptyView()
    case .idle:
      emptyDetail
      }
    }
  }

  /// 有正文时的详情列内容。载入下一条时这里仍然走同一个分支，SwiftUI 就能
  /// 原地更新这棵详情树；中间插一屏转圈会让它先整棵拆掉、再整棵重建，
  /// 每次切换白白多跑一轮 AppKit 布局递归——那正是切换文章要卡半秒的地方。
  private func articleDetail(detail: HistoryDetailProjection) -> some View {
    VStack(spacing: 0) {
      if !isCaptureOnboardingDismissed && !firstCaptureIsComplete {
        firstCaptureNextStepBanner(detail: detail)
      }
      HistoryDetailView(
        detail: detail,
        model: model,
        appModel: appModel,
        providerSettings: providerSettings,
        appearanceTheme: appearanceTheme,
        localImageURLs: model.localImageURLs,
        localMediaFileURL: model.localMediaFileURL,
        openSettings: { openSettings() },
        openRecapture: { manualLink.openForRecapture($0) },
        remotePreviewPlayback: remotePreviewPlayback,
        sessionMediaPlayback: sessionMediaPlayback
      )
      .equatable()
    }
  }

  private var emptyDetail: some View {
    // 空状态必须跟着当前区域走。
    //
    // 「我的笔记」是自己写东西的地方，在那里显示「还没有保存页面 / 添加链接 /
    // 从剪贴板添加链接」不只是文案不对——它把用户往完全相反的动作上引。
    if model.selectedScope == .notes {
      return AnyView(emptyNotesDetail)
    }
    return AnyView(emptyCaptureDetail)
  }

  /// 笔记区的空状态：只讲写，不讲抓。
  /// 在主窗口内新建一条笔记并选中它。
  ///
  /// 不弹独立窗口：写笔记与看资料共用同一套「左侧选、右侧读写」的动线，弹窗会把
  /// 这条动线打断——刚建完还要在两个窗口之间找焦点。需要专注时，主窗口本来就能
  /// 全屏或收起侧栏。
  private func createNote() {
    manualLink.createNote(
      onCreated: { taskID in
        model.selectScope(.notes)
        model.reveal(taskID: taskID)
      },
      onFailure: { message in
        // 用主界面确定会弹出的通道，别让失败悄无声息。
        model.reportFailure(message)
      }
    )
  }

  /// 打开今天的笔记。重复点只会回到同一条。
  private func openTodayNote() {
    manualLink.openTodayNote(
      onOpened: { taskID in
        model.selectScope(.notes)
        model.reveal(taskID: taskID)
      },
      onFailure: { model.reportFailure($0) }
    )
  }

  private var emptyNotesDetail: some View {
    VStack(spacing: 0) {
      Image(systemName: "square.and.pencil")
        .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 72, height: 72)
        .background(theme.badge, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl).stroke(theme.hairline, lineWidth: 1))
        .padding(.bottom, 18)
      Text("还没有笔记").themedFont(.title2, weight: .semibold)
        .padding(.bottom, 6)
      Text("随手记下想法、灵感或读后感。笔记和抓取的内容一样可以打标签、搜索和导出。")
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        .padding(.bottom, 20)
      Button(action: createNote) { Label("写第一条笔记", systemImage: "square.and.pencil") }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("notes-empty-create")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("notes-empty-detail")
  }

  private var emptyCaptureDetail: some View {
    VStack(spacing: 0) {
      if !isCaptureOnboardingDismissed {
        firstCaptureCard
          .padding(.bottom, 20)
      }
      // 图标放进软底圆角瓦片，参考稿里 Browse channels 卡片的图形语言。
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 72, height: 72)
        .background(theme.badge, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl).stroke(theme.hairline, lineWidth: 1))
        .padding(.bottom, 18)
      Text(isCaptureOnboardingDismissed ? "还没有保存页面" : "直接添加公开链接")
        .themedFont(.title2, weight: .semibold)
        .padding(.bottom, 6)
      Text("粘贴公开网页链接，或从 \(ProductDisplay.extensionName) 接收已打开的页面后，可在这里总结或翻译。")
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        .padding(.bottom, 20)
      HStack(spacing: 10) {
        Button(action: manualLink.open) { Label("添加链接", systemImage: "link.badge.plus") }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(!manualLink.canOpen)
          .accessibilityIdentifier("manual-link-add")
        Button(action: manualLink.readClipboardAndOpen) { Label("从剪贴板添加链接", systemImage: "doc.on.clipboard") }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(!manualLink.canOpen)
          .accessibilityIdentifier("manual-link-clipboard")
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var firstCaptureIsComplete: Bool {
    providerSettings.hasConfiguredAPIKey
      && model.rows.contains { $0.hasSummary == true }
  }

  private var hasInstalledBrowserSupport: Bool {
    browserSupport.statuses.contains { $0.state == .installed || $0.state == .installedAppUpdated }
  }

  private var firstCaptureCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("三步开始使用汲作").themedFont(.headline)
          Text("完成第一条总结后，这张卡会永久消失。")
            .themedFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          isCaptureOnboardingDismissed = true
        } label: {
          Image(systemName: "xmark").font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help("不再显示")
        .accessibilityLabel("不再显示")
      }
      onboardingStep(
        number: 1,
        title: "添加第一条链接",
        completed: !model.rows.isEmpty,
        actionTitle: "添加链接"
      ) {
        manualLink.open()
      }
      onboardingStep(
        number: 2,
        title: "配置一个模型",
        completed: providerSettings.hasConfiguredAPIKey,
        actionTitle: "去配置"
      ) {
        SettingsNavigationRequest.request("service")
        openSettings()
      }
      onboardingStep(
        number: 3,
        title: "生成第一份总结",
        completed: model.rows.contains { $0.hasSummary == true },
        actionTitle: model.rows.isEmpty ? "先添加链接" : "打开内容"
      ) {
        if let row = model.rows.first(where: { $0.hasSummary != true }) ?? model.rows.first {
          model.selectedTaskIDs = [row.taskID]
        } else {
          manualLink.open()
        }
      }
      Divider()
      HStack(spacing: 10) {
        Image(systemName: hasInstalledBrowserSupport ? "checkmark.circle.fill" : "puzzlepiece.extension")
          .foregroundStyle(hasInstalledBrowserSupport ? theme.success : theme.secondaryText)
        Text(hasInstalledBrowserSupport ? "浏览器扩展已安装" : "浏览器扩展可稍后安装，用来保存登录后才能看到的页面。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if !hasInstalledBrowserSupport {
          Button("去安装") {
            SettingsNavigationRequest.request("browserSupport")
            openSettings()
          }
          .buttonStyle(.borderless)
        }
      }
    }
    .padding(18)
    .frame(maxWidth: 470, alignment: .leading)
    .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl).stroke(theme.hairline, lineWidth: 1))
    .accessibilityIdentifier("first-capture-onboarding")
  }

  private func firstCaptureNextStepBanner(detail: HistoryDetailProjection) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .foregroundStyle(theme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("完成首次设置").themedFont(.callout, weight: .semibold)
        Text(firstCaptureNextStepMessage).themedFont(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button(firstCaptureNextStepActionTitle) {
        if !providerSettings.hasConfiguredAPIKey {
          SettingsNavigationRequest.request("service")
          openSettings()
        } else {
          Task { await appModel.summarize(historyDetail: detail, preferences: providerSettings.runPreferences) }
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      Button {
        isCaptureOnboardingDismissed = true
      } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain)
        .help("不再显示")
        .accessibilityLabel("不再显示")
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(theme.accent.opacity(0.08))
    .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 1) }
    .accessibilityIdentifier("first-capture-next-step")
  }

  private var firstCaptureNextStepMessage: String {
    if !providerSettings.hasConfiguredAPIKey { return "还差一步：配置模型后即可总结当前内容。" }
    return "保存已完成，生成第一份总结后引导会自动消失。"
  }

  private var firstCaptureNextStepActionTitle: String {
    return providerSettings.hasConfiguredAPIKey ? "生成总结" : "配置模型"
  }

  private func onboardingStep(
    number: Int,
    title: String,
    completed: Bool,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: completed ? "checkmark.circle.fill" : "\(number).circle")
        .foregroundStyle(completed ? theme.success : theme.secondaryText)
        .font(.title3)
      Text(title).themedFont(.callout, weight: .medium)
      Spacer()
      if !completed {
        Button(actionTitle, action: action).buttonStyle(.borderless)
      }
    }
  }

  private var blockingError: some View {
    HistoryInlineState(
      symbol: "externaldrive.badge.exclamationmark",
      title: "无法打开历史记录",
      message: "\(ProductDisplay.name) 未对数据进行写入。请检查本机存储后重新启动 \(ProductDisplay.name)。"
    )
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityIdentifier("history-blocking-error")
  }
}

/// 窗口工具栏的主题背景。主窗口与设置窗口共用，避免两处各写一份判据再各自漂移
/// ——设置窗口原来自己写了一份且判据是 `== .paper`，深色主题下工具栏没跟上。
///
/// 必须挂在**每一列的内容**上，不能只挂在 NavigationSplitView 外面：macOS 的
/// 统一工具栏按列分段取背景，根部那一份对分栏窗口不生效。实测的表现就是
/// 详情列滚动时，22pt 的标题原样从齿轮和模型按钮底下穿过去。
struct HistoryWindowToolbarThemeModifier: ViewModifier {
  let theme: HistoryThemeTokens
  /// 这一列头顶那段工具栏条的底色。辅助列用画布色；详情列传正文色——
  /// 静止时和内容同色无痕，滚动时是一块不透明的挡板。
  var background: Color? = nil

  @ViewBuilder func body(content: Content) -> some View {
    if theme.isNative {
      content
    } else if #available(macOS 26.0, *) {
      // macOS 26 起工具栏是悬浮 Liquid Glass，不再有可着色的整条背景；
      // 自定义 toolbarBackground 反而会压掉系统的 scroll edge effect，
      // 表现就是正文文字原样从悬浮图标底下穿过去。改用硬边 scroll edge：
      // 滚动内容在工具栏下沿被截断遮挡，主题底色由列自身背景提供。
      content
        .scrollEdgeEffectStyle(.hard, for: .top)
        .toolbarBackground(background ?? theme.canvas, for: .windowToolbar)
    } else {
      content
        .toolbarBackground(background ?? theme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }
  }
}

/// 侧栏与网格共用，所以不是 private。
struct PlatformNavigationIcon: View {
  let host: String
  var faviconURL: URL? = nil
  var faviconTaskID: TaskID? = nil

  var body: some View {
    if host == HistoryPlatformDisplay.miscHost {
      // 杂项来源没有 logo 可取，用收件盘符号——它表达的正是「还没归类」。
      Image(systemName: "tray")
        .font(.system(size: DesignTokens.IconSize.control, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
    } else if let image = PlatformIconCatalog.image(for: host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
    } else if let faviconURL, let faviconTaskID {
      HistoryFaviconDiskImage(url: faviconURL, host: host, taskID: faviconTaskID) {
        fallbackBadge
      }
    } else {
      fallbackBadge
    }
  }

  private var fallbackBadge: some View {
    Text(PlatformIconCatalog.fallbackInitial(for: host))
      .font(.system(size: BadgeTypography.size, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 16, height: 16)
      .background(PlatformIconCatalog.fallbackColor(for: host), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
  }
}

/// The detail header needs a recognizable source, not a wire-format URL.
/// Opening and copying still use the untouched value; this is display-only.
private struct HistoryDetailView: View, Equatable {
  /// 父视图重求值一次，就会新造一个 `HistoryDetailView` 结构体。里面带着两个闭包，
  /// SwiftUI 因此永远判定「变了」，于是整棵详情树连同 `MarkdownContentView` 重画一遍。
  /// 这里只比较真正决定画面的值输入，闭包按「行为不随实例变化」处理，不参与比较。
  ///
  /// 五个 @ObservedObject 不进比较：它们是窗口级单例，实例从不更换，各自的
  /// 订阅仍会在其内容变化时直接触发本视图 body，Equatable 挡不掉也不该挡。
  /// （nonisolated == 也只允许读 Sendable 的存储属性，这四个值输入正好都是。）
  nonisolated static func == (lhs: HistoryDetailView, rhs: HistoryDetailView) -> Bool {
    lhs.detail == rhs.detail
      && lhs.appearanceTheme == rhs.appearanceTheme
      && lhs.localImageURLs == rhs.localImageURLs
      && lhs.localMediaFileURL == rhs.localMediaFileURL
  }

  let detail: HistoryDetailProjection
  @ObservedObject var model: HistoryViewModel
  @ObservedObject var appModel: AppViewModel
  @ObservedObject var providerSettings: ProviderSettingsViewModel
  let appearanceTheme: AppearanceTheme
  let localImageURLs: [URL]
  let localMediaFileURL: URL?
  let openSettings: () -> Void
  let openRecapture: (String) -> Void
  /// 与列表预热共享：选中当前抓取时已开始 prepare，详情卡复用同一 controller。
  @ObservedObject var remotePreviewPlayback: RemotePreviewPlayerController
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isRegeneratePopoverPresented = false
  @State private var isRunPanelExpanded = false
  @State private var showsPlainText = false
  @State private var temporaryModel = ""
  /// Brief completion feedback after summarize/translate finishes.
  @State private var completionBanner: String?
  /// When both a model artifact and the captured source exist, user can switch.
  @State private var readingPane: ReadingPane = .summary
  /// 点了总结/翻译、Run 还没变成可见态时，先把对应页签打开。
  /// 否则抖音图文只有「原文」，生成过程只能再挂一块预览卡片。
  @State private var pendingRunPane: ReadingPane?
  /// 阅读进度独立小模型：进度若放进本视图的 @State，每个滚动事件都会
  /// 重求值整个详情页——那是长文滚动掉帧的来源（见 ReadingProgressModel）。
  @StateObject private var readingProgressModel = ReadingProgressModel()
  /// 已访问过的阅读面板（见 content 的注释）：保活的折叠集合。
  @State private var visitedReadingPanes: Set<ReadingPane> = []
  /// 各阅读面板的实测高度：ZStack 容器按「当前活动面板的高度」定高，
  /// 隐藏面板保持自然尺寸不被折叠——切换因此不触发任何几何重算。
  @State private var paneHeights: [ReadingPane: CGFloat] = [:]
  @State private var pendingSourceCitation: String?
  @State private var measuredTitleHeight: CGFloat = HistoryDetailView.titleLineHeight
  /// 转写校对：编辑态与草稿只属于当前详情页，切换条目即复位。
  /// 长配文 / 长转写默认收起，避免把「重新转写」顶出一屏。
  @State private var isCaptionExpanded = false
  @State private var isTranscriptExpanded = false
  @State private var isSubtitleExpanded = false
  /// 选中的原文层。nil 表示还没手动切过，按 `defaultSourceLayer` 走。
  @State private var selectedSourceLayer: SourceLayer?
  /// 选中的译文层。
  ///
  /// 和 `selectedSourceLayer` 分开存，不共用：两边可选的层不一定一样——译文是
  /// 翻译那一刻的快照，之后新跑出来的字幕/转写不在里面。共用一个状态会出现
  /// 「在原文里选了画面字幕，切到翻译却是空的」。
  @State private var selectedTranslationLayer: SourceLayer?
  @State private var isEditingTranscription = false
  @State private var transcriptionDraft = ""
  /// 从阅读区点进来时对回源码的光标。
  @State private var sourceEditCaretUTF16 = 0
  /// 同一记点击打开编辑器后，系统还会把这次 mouseUp 当成失焦，必须先吞掉。
  @State private var suppressSourceEditFinishUntil: Date?
  /// SwiftUI 空白处不会抢焦点，所以失焦退编辑靠窗口级点击监视。
  @State private var sourceEditClickOutside = SourceEditClickOutsideMonitor()
  @State private var noteTitleDraft = ""
  /// 笔记编辑器排版后的实际高度，由编辑器回报，用来让它长到内容那么高。
  @State private var noteEditorHeight: CGFloat = 320
  @State private var noteAutosaveTask: Task<Void, Never>?
  /// 刚存过的提示，几秒后自行消失。
  @State private var noteSaveIndicator = false
  /// 当前正在编辑的笔记身份。切走时要用它把草稿存回**原来**那条。
  @State private var editingNote: (taskID: TaskID, snapshotID: ContentSnapshotID, storedBody: String)?
  /// 链接到本条的笔记。
  ///
  /// 存成状态而不是在 body 里现查：body 每次重绘都会执行，打字时每敲一个字
  /// 就要扫一遍全部笔记正文。这一份只取决于**别人**的正文，本条怎么编辑都不
  /// 影响它，所以切换记录或改了标题时重载一次就够。
  @State private var noteBacklinks: [NoteBacklink] = []
  /// `[[` 补全的候选标题。和反链一样按需加载，不在 body 里现查。
  @State private var noteLinkTitles: [String] = []
  /// 详情页里可获得键盘焦点的字段。目前只有笔记标题需要感知失焦。
  private enum DetailField: Hashable { case noteTitle }
  @FocusState private var focusedField: DetailField?
  @AppStorage(ReadingFontSelection.storageKey)
  private var readingFontRaw = ReadingFontSelection.defaultStoredValue
  @AppStorage(ReadingFontSize.storageKey)
  private var readingFontSizeRaw = Double(ReadingFontSize.default)
  /// 工具栏快捷打标签的浮层。
  @State private var isTagPopoverPresented = false
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }
  /// 工具栏「小／大」按步进调字号，夹在合法区间内。改的是与设置页同一个
  /// @AppStorage，外观页的滑块会立即跟着动。
  private func adjustReadingFontSize(by delta: CGFloat) {
    let next = readingFontSizeRaw + Double(delta)
    readingFontSizeRaw = min(
      max(next, Double(ReadingFontSize.minimum)),
      Double(ReadingFontSize.maximum))
  }
  /// 用户阅读字体与字号偏好；「跟随主题」回落到主题的编辑排版标记。
  private var readingFont: ResolvedReadingFont {
    ReadingFontSelection(storedValue: readingFontRaw)
      .resolved(
        usesEditorialReadingTypography: appearanceTheme.usesEditorialReadingTypography,
        bodySize: CGFloat(readingFontSizeRaw)
      )
  }
  /// 阅读面板。
  ///
  /// 总结和翻译各占一格，而不是共用一个「结果」格。原来只有 result/source 两格，
  /// result 显示哪一个由「最近产出文本的那次运行」决定——于是先翻译再总结，翻译
  /// 就被挤掉了：那份译文一直在库里，只是没有任何入口能点回去。
  /// 原文里的一层。
  ///
  /// 画面字幕和视频转写是**同一段话的两个版本**，不是先后两段内容——纵向叠着
  /// 意味着要滚过整份字幕才够得着转写稿，而没有人会顺着读完一个再读另一个。
  /// 这里改成一次只显示一层，用和顶上「总结/翻译/原文」相同的分段控件切换。
  private enum SourceLayer: String, CaseIterable, Identifiable {
    case caption
    case subtitles
    case transcript
    var id: String { rawValue }
    var heading: String {
      switch self {
      case .caption: LayeredSourceDocument.captionHeading
      case .subtitles: LayeredSourceDocument.subtitleHeading
      case .transcript: LayeredSourceDocument.transcriptHeading
      }
    }

    /// 从小标题反查是哪一层。
    ///
    /// 翻译是整份文档一次翻完的，回来时只剩 `## 配文` 这样的文本，没有类型信息。
    init?(heading: String) {
      guard let match = Self.allCases.first(where: { $0.heading == heading }) else { return nil }
      self = match
    }
  }

  private enum ReadingPane: String, CaseIterable, Identifiable {
    case summary
    case translation
    case source
    var id: String { rawValue }
  }

  /// 各阅读面板向上上报实测高度：ZStack 容器据此按活动面板定高，
  /// 切换面板不动任何子视图几何（见 content 的注释）。
  private struct ReadingPaneHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [ReadingPane: CGFloat] = [:]

    static func reduce(value: inout [ReadingPane: CGFloat], nextValue: () -> [ReadingPane: CGFloat]) {
      value.merge(nextValue()) { current, _ in current }
    }
  }
  private var newestRun: HistoryDetailProjection.RunDetail? { detail.runs.last }
  /// Newest run that actually produced readable artifact text.
  private var latestArtifactRun: HistoryDetailProjection.RunDetail? {
    detail.runs.reversed().first { run in
      guard let body = run.artifact?.bodyText else { return false }
      return !body.isEmpty
    }
  }
  private var latestArtifact: HistoryArtifact? { latestArtifactRun?.artifact }
  /// 某一类运行最新的、有正文的产物。
  ///
  /// 按类取而不是只取最新一份，是这个面板能同时提供总结和翻译的前提。
  private func artifact(ofKind kind: RunKind) -> HistoryArtifact? {
    detail.runs.reversed().first { run in
      guard run.run.kind == kind, let body = run.artifact?.bodyText else { return false }
      return !body.isEmpty
    }?.artifact
  }
  private var summaryArtifact: HistoryArtifact? { artifact(ofKind: .summarize) }
  private var translationArtifact: HistoryArtifact? { artifact(ofKind: .translate) }
  private func artifact(for pane: ReadingPane) -> HistoryArtifact? {
    switch pane {
    case .summary: summaryArtifact
    case .translation: translationArtifact
    case .source: nil
    }
  }
  private var latestSnapshot: ContentSnapshot? { detail.snapshots.last }
  /// 这条记录是用户自己写的笔记，而非抓取来的网页。
  private var isUserNote: Bool {
    detail.snapshots.last?.sourceKind == CapturedDocument.Origin.userNote.rawValue
  }
  /// 工作台的稿件。
  private var isPieceDraft: Bool {
    detail.snapshots.last?.sourceKind == CapturedDocument.Origin.pieceDraft.rawValue
  }
  /// 已完成的作品。
  private var isFinishedWork: Bool {
    detail.snapshots.last?.sourceKind == CapturedDocument.Origin.work.rawValue
  }
  /// **用户自己写的正文**——笔记、稿件、作品都算。
  ///
  /// 编辑体验(点正文即可写、空笔记仍一打开就写、自动保存、Markdown 着色)
  /// 属于「这是我写的东西」,不属于「这是笔记」。切开三模块时如果继续用
  /// `isUserNote` 判断,稿件会立刻退回只读的抓取详情页——那正是这次重构
  /// 要避免的倒退。
  private var isOwnWriting: Bool { isUserNote || isPieceDraft || isFinishedWork }
  /// 库里那份笔记正文，占位文字归一化成空串。
  ///
  /// 占位文字只是为了让新笔记通过「非空正文」校验，语义上等同于「还没写」，
  /// 所以比对改动和回显草稿都必须先把它折叠掉，否则「没动过」会被判成有改动。
  private func storedNoteBody(_ snapshot: ContentSnapshot) -> String {
    let body = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
    return body == UserNoteDocument.placeholderBody ? "" : body
  }
  /// 草稿相对库里那份是否真的变了。
  private func noteDraftIsDirty(_ snapshot: ContentSnapshot) -> Bool {
    !transcriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && transcriptionDraft != storedNoteBody(snapshot)
  }
  /// 停笔一秒就自动存。
  ///
  /// 手动保存对笔记是错的模型：写的人不会记得按保存，而切到另一条笔记会丢掉
  /// 草稿——写了一整篇、切走、回来只剩占位文字。这件事必须由工具兜住。
  /// 转写点进去改几个字也走同一条：不必再找「保存」。
  private func scheduleNoteAutosave() {
    guard isEditingTranscription else { return }
    noteAutosaveTask?.cancel()
    noteAutosaveTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, let snapshot = latestSnapshot, sourceDraftIsDirty(snapshot) else { return }
      saveTranscriptionDraft(snapshot, exiting: false)
      noteSaveIndicator = true
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      guard !Task.isCancelled else { return }
      noteSaveIndicator = false
    }
  }

  /// 离开这条笔记之前立刻存一次——等不到防抖那一秒。
  ///
  /// 必须用调用方传进来的 id：切换记录时 `detail` 已经指向新的那条了，
  /// 此时读 `latestSnapshot` 会把上一条的草稿写进新笔记。
  private func flushNoteDraft(taskID: TaskID, snapshotID: ContentSnapshotID, storedBody: String) {
    noteAutosaveTask?.cancel()
    let draft = transcriptionDraft
    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft != storedBody else { return }
    model.saveEditedSnapshotText(taskID: taskID, snapshotID: snapshotID, bodyText: draft)
  }

  /// 标题草稿落库。没改动就什么都不做，避免每次失焦都写一次库。
  private func commitNoteTitle() {
    guard isOwnWriting else { return }
    let trimmed = noteTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = trimmed.isEmpty ? UserNoteDocument.untitledTitle : trimmed
    guard resolved != title else {
      noteTitleDraft = resolved
      return
    }
    model.renameNote(taskID: detail.task.id, title: resolved)
    noteTitleDraft = resolved
    // 改了标题就换了链接目标：原先指向旧名字的那些链接现在指不到这条了。
    noteBacklinks = model.backlinks(forTitle: resolved)
  }
  /// Source frontmatter belongs to the newest captured source, not a later
  /// local transcription snapshot that may have become the effective body.
  ///
  /// 走 `captionSnapshot` 而不是自己写「不是听写就行」：派生层不止听写一种，
  /// 画面字幕同样没有作者和发布时间。判据只该有一份，否则每加一种派生来源
  /// 都要记得同步这里，漏了就静默丢掉 frontmatter。
  private var latestSourceSnapshot: ContentSnapshot? {
    LayeredSourceDocument.captionSnapshot(in: detail.snapshots)
  }
  private var latestTranscriptionSnapshot: ContentSnapshot? {
    LayeredSourceDocument.transcriptSnapshot(in: detail.snapshots)
  }
  private var latestSubtitleSnapshot: ContentSnapshot? {
    LayeredSourceDocument.subtitleSnapshot(in: detail.snapshots)
  }
  /// 配文还在、而且不是抖音那种和标题重复的空 caption，才值得单独一层。
  private var hasPresentableCaption: Bool {
    guard let snapshot = latestSourceSnapshot else { return false }
    let body = LayeredSourceDocument.body(of: snapshot)
    guard !body.isEmpty else { return false }
    return !CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: snapshot.platform,
      title: CapturedDocumentTitle.display(snapshot.title, for: snapshot.sourceURL),
      markdown: snapshot.bodyText
    )
  }
  /// 这条记录有哪几层原文可选。
  ///
  /// 顺序与 `LayeredSourceDocument.orderedLayers` 一致：配文 → 画面字幕 → 视频转写。
  /// 三处顺序必须一样，否则切换控件的排列、阅读区的内容、喂给模型的正文各说各话。
  private var availableSourceLayers: [SourceLayer] {
    var layers: [SourceLayer] = []
    if hasPresentableCaption { layers.append(.caption) }
    if latestSubtitleSnapshot != nil { layers.append(.subtitles) }
    if latestTranscriptionSnapshot != nil { layers.append(.transcript) }
    return layers
  }

  /// 当前显示哪一层。
  ///
  /// 选中的层可能因为重新抓取而消失（例如字幕被删掉），此时回落到第一层而不是
  /// 显示空白。
  private var activeSourceLayer: SourceLayer? {
    let available = availableSourceLayers
    if let selected = selectedSourceLayer, available.contains(selected) { return selected }
    return available.first
  }

  /// 只有一层时不出控件：一个没有选择余地的分段控件只是看起来像有。
  private var showsSourceLayerPicker: Bool { availableSourceLayers.count > 1 }

  /// 译文拆出来的各层。
  ///
  /// 翻译是把 `LayeredSourceDocument.modelInput` 拼出的整份文档一次翻完，所以
  /// 译文里同样带着「## 配文 / ## 画面字幕 / ## 视频转写」。不拆就只能纵向叠着
  /// 显示——而那正是原文页当初改掉的形态：字幕和转写是同一段话的两个版本，
  /// 叠着意味着要滚过整份字幕才够得着转写稿。
  private var translationLayers: [(layer: SourceLayer?, body: String)] {
    guard let body = translationArtifact?.bodyText, !body.isEmpty else { return [] }
    return LayeredSourceDocument.split(body).map {
      (layer: $0.heading.flatMap(SourceLayer.init(heading:)), body: $0.body)
    }
  }

  /// 译文开头那段没有小标题的内容——通常是翻译过来的**标题行**。
  ///
  /// 它在第一个 `## 配文` 之前，不属于任何一层。切层时它必须一直在，否则
  /// 每切一次标题就消失一次。
  private var translationPreamble: String? {
    guard let first = translationLayers.first, first.layer == nil else { return nil }
    return first.body
  }

  /// 译文里可切换的层。
  ///
  /// 「开头那段无名内容」要单独拿掉再判断——它是标题，不是一层。第一版忘了这件事，
  /// 结果 `named.count == layers.count` 永远不成立，控件一次都没出现过，而译文
  /// 照旧纵向叠着：一个不报错、只是「功能像没做」的失败。
  private var availableTranslationLayers: [SourceLayer] {
    let layers = translationPreamble == nil ? translationLayers : Array(translationLayers.dropFirst())
    guard layers.count > 1 else { return [] }
    let named = layers.compactMap(\.layer)
    return named.count == layers.count ? named : []
  }

  private var activeTranslationLayer: SourceLayer? {
    let available = availableTranslationLayers
    if let selected = selectedTranslationLayer, available.contains(selected) { return selected }
    return available.first
  }

  private var showsTranslationLayerPicker: Bool { availableTranslationLayers.count > 1 }

  /// 当前该渲染的译文正文：开头那段（标题）+ 当前这一层。没分层时返回 nil，
  /// 调用方退回整篇。
  private var activeTranslationBody: String? {
    guard showsTranslationLayerPicker, let active = activeTranslationLayer,
          let body = translationLayers.first(where: { $0.layer == active })?.body
    else { return nil }
    guard let preamble = translationPreamble else { return body }
    return preamble + "\n\n" + body
  }

  private var showsLayeredSource: Bool {
    // 听写和画面字幕都算派生层，有任意一层就该分层显示。
    //
    // 原来只看听写，于是只读了字幕、没跑听写的记录会退回单层渲染，把刚读出来
    // 的那一层整个藏起来——数据在库里，界面上却什么都看不到。
    //
    // 配文**不是**分层的前提。抖音视频帖的 caption 多半和标题重复，
    // `hasPresentableCaption` 因此是 false；此时只要字幕和听写同时存在，旧判据就
    // 让整条记录退回单层渲染、只画听写稿，把已经读出来的字幕层原地藏掉——上面
    // 那个坑换条路又走了一遍。两条派生层同时在，就必须分层。
    if latestSubtitleSnapshot != nil, latestTranscriptionSnapshot != nil { return true }
    return hasPresentableCaption && (latestTranscriptionSnapshot != nil || latestSubtitleSnapshot != nil)
  }
  private var isDouyinCapture: Bool { latestSourceSnapshot?.platform == "douyin" }
  /// 抖音图文帖：正文本身就是内容（文案 + 图集），不像视频帖那样只是重复标题的
  /// caption。原文面板必须给它抓取正文，否则整篇图集会被空的「尚未转写」顶掉。
  /// 判据与 `RemoteMarkdownImageStagingPolicy.isDouyinImagePost` 保持一致。
  private var isDouyinImagePostCapture: Bool {
    guard isDouyinCapture, detail.media == nil, let snapshot = latestSourceSnapshot else { return false }
    return snapshot.bodyText.range(
      of: #"!\[[^\]]*\]\(https?://[^)]*douyinpic\.com/"#,
      options: .regularExpression
    ) != nil
  }
  private var isWeChatCapture: Bool { latestSourceSnapshot?.platform == "wechat" }
  private func paneLabel(_ pane: ReadingPane) -> String {
    switch pane {
    case .summary: "总结"
    case .translation: "翻译"
    case .source: "原文"
    }
  }
  private var title: String { CapturedDocumentTitle.display(detail.snapshots.last?.title, for: sourceURL) }
  /// 详情头：有总结/翻译一级标题时主标题用产物，原文降副行；标题本地化后副行读 original_title。
  private var readingTitles: (primary: String, original: String?) {
    HistoryReadingTitle.detailTitles(
      captured: title,
      product: HistoryReadingTitle.productTitle(
        summaryBody: summaryArtifact?.bodyText,
        translationBody: translationArtifact?.bodyText
      ),
      preservedOriginalTitle: sourceFrontmatter.originalTitle
    )
  }
  private var readingPrimaryTitle: String { readingTitles.primary }
  private var readingOriginalSubtitle: String? { readingTitles.original }
  private var sourceURL: String { detail.snapshots.last?.sourceURL ?? detail.task.canonicalURL }
  /// Tolaria-style properties from capture frontmatter (author / published / description).
  private var sourceFrontmatter: MarkdownNoteFrontmatter {
    MarkdownNoteFrontmatter.parse(latestSourceSnapshot?.bodyText ?? "")
  }
  private var showsCurrentCapture: Bool { appModel.currentCapture?.taskID == detail.task.id }
  private var showsVisibleRun: Bool { appModel.showsVisibleRun(for: detail.task.id) }
  private var canRunHistory: Bool { appModel.canStartRun(from: detail) }
  private var summarizeUnavailableReason: String? {
    if appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .summarize) {
      return nil
    }
    let reason = appModel.summarizeUnavailableReason(
      usingCurrentCapture: showsCurrentCapture,
      detail: detail,
      preferencesReady: providerSettings.arePreferencesReady
    )
    if reason != nil, appModel.canEnqueueManualGeneration(for: detail.task.id) {
      return nil
    }
    return reason
  }
  private var translateUnavailableReason: String? {
    if appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .translate) {
      return nil
    }
    let reason = appModel.translateUnavailableReason(
      usingCurrentCapture: showsCurrentCapture,
      detail: detail,
      preferences: providerSettings.runPreferences,
      preferencesReady: providerSettings.arePreferencesReady
    )
    if reason != nil, appModel.canEnqueueManualGeneration(for: detail.task.id) {
      return nil
    }
    return reason
  }
  private var mindMapUnavailableReason: String? {
    guard !isOwnWriting, model.mindMapRecord?.taskID != detail.task.id else { return nil }
    if appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap) {
      return nil
    }
    if let reason = model.mindMapUnavailableReason(taskID: detail.task.id) {
      return reason
    }
    return nil
  }
  /// 一行说清为什么灰。两颗钮同一原因只写一次；总结能点、翻译不能时写翻译的原因。
  private var runActionBlockedReason: String? {
    if appModel.hasQueuedGeneration(for: detail.task.id) {
      return "已排队，等当前这条做完"
    }
    if summarizeUnavailableReason != nil, translateUnavailableReason != nil {
      return summarizeUnavailableReason
    }
    return summarizeUnavailableReason ?? translateUnavailableReason ?? mindMapUnavailableReason
  }
  private var showsRunControls: Bool {
    canRunHistory
      || showsCurrentCapture
      || showsVisibleRun
      || appModel.canEnqueueManualGeneration(for: detail.task.id)
      || appModel.hasQueuedGeneration(for: detail.task.id)
  }
  private var presentsArticleBeforeMedia: Bool {
    guard let latestSnapshot else { return false }
    // 有视频时播放器在上、文稿在下：转写按钮和视频在一起，长转写不会把它们顶走。
    // 微信长文没有内嵌播放器，仍旧正文在前。
    return RemoteMarkdownImageStagingPolicy.isSubstantiveWeChatArticle(
      platform: latestSnapshot.platform,
      markdown: latestSnapshot.bodyText
    )
  }
  private var suppressesEmbeddedMedia: Bool { latestSnapshot?.platform == "wechat" }
  private var hasResultBody: Bool {
    guard let artifact = latestArtifact else { return false }
    return !artifact.bodyText.isEmpty
  }
  /// YouTube 是加密流，不落盘；官方 embed 通道在 App 内直接播放，
  /// 无字幕视频提供内嵌播放音频实时转写入口。
  @ViewBuilder private func youTubeCard(videoID: String) -> some View {
    YouTubeEmbedPlayerCard(videoID: videoID, hasCaptions: youTubeHasCaptions)
      .padding(.top, 14)
      .accessibilityIdentifier("history-youtube-embed-card")
  }

  /// YouTube 正文是否已含字幕（抓取时写入的「## 字幕」节）。
  private var youTubeHasCaptions: Bool {
    guard let body = latestSnapshot?.bodyText else { return false }
    return body.contains("## 字幕")
  }

  private var hasSourceBody: Bool {
    guard let snapshot = isDouyinCapture ? latestTranscriptionSnapshot : latestSnapshot else { return false }
    return !snapshot.bodyText.isEmpty
  }
  private var liveTranscriptionState: TranscriptionUIState {
    model.transcriptionState(for: detail.task.id)
  }
  private var liveTranscriptionText: String {
    model.transcriptionText(for: detail.task.id)
  }
  private var hasLiveTranscription: Bool {
    liveTranscriptionState.isActive || (!liveTranscriptionText.isEmpty && latestTranscriptionSnapshot == nil)
  }
  private var hasPresentableSourceBody: Bool {
    guard let snapshot = latestSnapshot, hasSourceBody else { return false }
    return !CapturedSourceBodyPresentation.isRedundantDouyinBody(
      platform: snapshot.platform,
      title: title,
      markdown: snapshot.bodyText
    )
  }
  /// 只列出真正有内容可读的面板，外加必要的空态落脚点。
  ///
  /// 总结和翻译各自独立出现：两者都有就是三格，只有一个就仍是两格——所以这次改动
  /// 不会给「只总结过」的条目凭空多出一个空的翻译页。
  private var availableReadingPanes: [ReadingPane] {
    var panes: [ReadingPane] = []
    if summaryArtifact != nil || liveRunReadingPane == .summary { panes.append(.summary) }
    if translationArtifact != nil || liveRunReadingPane == .translation { panes.append(.translation) }
    // 一份结果都没有时保留一个总结格，「尚未生成总结」的空态提示才有地方落。
    // 抖音例外：它在没有结果时本来就不显示结果格。
    //
    // 笔记也例外：给一条刚写的笔记留一个空的「总结」页签，等于在写作页面上摆一个
    // 常驻的待办。没总结时它就只有正文一件东西，那就不该出现分段控件。
    if panes.isEmpty, !isDouyinCapture, !isOwnWriting { panes.append(.summary) }
    if !isDouyinCapture || hasSourceBody || hasLiveTranscription { panes.append(.source) }
    return panes
  }
  /// For Douyin, source means a saved local transcription—not the duplicate
  /// caption. Other platforms retain their existing source-pane behavior.
  private var showsReadingPanePicker: Bool {
    // 笔记只有一份正文，除非真的跑出了翻译或总结，否则「原文」是个只有一个选项的
    // 分段控件——它不提供任何选择，只是看起来像有。
    if isOwnWriting { return availableReadingPanes.count > 1 }
    return hasResultBody || hasSourceBody || hasLiveTranscription || liveRunReadingPane != nil
  }
  /// 默认停在最近一次跑出来的那份结果上——刚点完翻译就该看到翻译。
  private var defaultReadingPane: ReadingPane {
    if let kind = latestArtifactRun?.run.kind { return pane(for: kind) }
    if hasLiveTranscription { return .source }
    if hasPresentableSourceBody { return .source }
    return hasSourceBody ? .source : (availableReadingPanes.first ?? .summary)
  }
  private func pane(for kind: RunKind) -> ReadingPane {
    kind == .translate ? .translation : .summary
  }
  /// 正在生成、或失败/中断还只有这份草稿时，对应的总结/翻译页就是阅读区。
  /// 完成后正文进页签，这里关掉，避免同一段字出现两次。
  private var liveRunReadingPane: ReadingPane? {
    if let pendingRunPane { return pendingRunPane }
    guard showsVisibleRun else { return nil }
    switch appModel.runState.intent {
    case .summarize: return .summary
    case .translate: return .translation
    case .connectionTest, .none: return nil
    }
  }

  private var showsLiveRunInReadingPane: Bool {
    guard let pane = liveRunReadingPane else { return false }
    if case .completed = appModel.runState, artifact(for: pane) != nil { return false }
    return appModel.runState.isActive
      || !appModel.runResultText.isEmpty
      || appModel.runHasFailure
  }
  private var protectedTaskIDs: Set<TaskID> {
    var result: Set<TaskID> = []
    if let taskID = appModel.activeRunTaskID { result.insert(taskID) }
    if model.transcriptionState.isActive, let taskID = model.transcriptionTaskID { result.insert(taskID) }
    if model.imageTextRecognitionState == .recognizing,
       let taskID = model.imageTextRecognitionTaskID { result.insert(taskID) }
    return result
  }

  var body: some View {
    ScrollView {
      // Title → URL → run/capture metadata (top) → action toolbar → reading → tags.
      VStack(alignment: .leading, spacing: 0) {
        if model.isReadOnly {
          ReadOnlyHistoryCallout(reason: model.historyReadOnlyReason)
            .padding(.bottom, 16)
        }
        if let completionBanner {
          Label(completionBanner, systemImage: "checkmark.circle.fill")
            .themedFont(.callout, weight: .medium)
            .foregroundStyle(theme.success)
            .padding(.bottom, 10)
            .accessibilityIdentifier("history-run-completion-banner")
            .transition(historyBannerTransition(reduceMotion: reduceMotion))
        }
        // 成功有横幅，失败和中断原来什么都不显示——状态只落在详情下方一个被动的
        // 元数据字段上。关 App 时被打断的那次翻译，表现就是「点了没反应」。
        if completionBanner == nil, let notice = UnfinishedRunNotice.latest(in: detail.runs) {
          HStack(spacing: 8) {
            Label(notice.message, systemImage: "exclamationmark.arrow.circlepath")
              .themedFont(.callout, weight: .medium)
              .foregroundStyle(theme.warning)
              .fixedSize(horizontal: false, vertical: true)
            Button("重新\(UnfinishedRunNotice.label(for: notice.kind))") {
              retryUnfinishedRun(notice.kind)
            }
            .controlSize(.small)
            .disabled(!providerSettings.arePreferencesReady)
            .accessibilityIdentifier("history-run-unfinished-retry")
            Spacer(minLength: 0)
          }
          .padding(.bottom, 10)
          .accessibilityIdentifier("history-run-unfinished-banner")
        }
        titleView
        if !isOwnWriting {
          sourceByline
            .padding(.top, DesignTokens.Space.sm)
        }
        if !isWeChatCapture && sourceFrontmatter.hasEngagementStats {
          notePropertiesStrip(sourceFrontmatter)
            .padding(.top, DesignTokens.Space.sm)
        }

        if showsRunControls {
          // 上面是「这条是什么」，这一排是「对它做什么」。
          Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
            .padding(.top, DesignTokens.Space.lg)
          actionToolbar
            .padding(.top, DesignTokens.Space.md)
            .accessibilityIdentifier("history-action-toolbar")
        }

        if presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            .padding(.top, 18)
        }

        if !suppressesEmbeddedMedia {
          // Source properties, run metadata and summarize/translate controls all
          // remain above media; tall portrait video can never hide primary actions.
          if let localMediaFileURL,
             LocalMediaExport.isSupportedLocalFile(localMediaFileURL) {
            HistoryVideoPlayerCard(
              fileURL: localMediaFileURL,
              media: detail.media,
              taskID: detail.task.id,
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              tidyModel: providerSettings.effectiveTidyModelName
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-player-card")
          } else if localMediaFileURL == nil,
                    showsCurrentCapture,
                    let capture = appModel.currentCapture,
                    let captureDescriptor = capture.mediaDescriptor {
            // 手选清晰度后，优先播放本次会话刚刷新的地址；刷新前仍可立即播放
            // 扩展随抓取带回的地址。否则当前抓取分支会一直压在 session cache
            // 前面，菜单虽然能点，播放器却永远还是旧清晰度。
            let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID)
              ?? captureDescriptor
            CurrentCaptureMediaPreviewCard(
              descriptor: descriptor,
              taskID: capture.taskID,
              snapshotID: capture.snapshotID,
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              tidyModel: providerSettings.effectiveTidyModelName,
              playback: remotePreviewPlayback,
              onRefreshStream: {
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: capture.taskID,
                  platform: latestSourceSnapshot?.platform ?? capture.document.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              },
              onSelectQuality: { quality in
                // 旧画面继续播，只换新地址；立刻 release 会黑屏等十几秒。
                sessionMediaPlayback.requestRefresh(
                  taskID: capture.taskID,
                  platform: latestSourceSnapshot?.platform ?? capture.document.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author,
                  qualityOverride: quality
                )
              },
              selectedQuality: sessionMediaPlayback.chosenQuality(for: capture.taskID)
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-preview-card")
            .id(sessionMediaPlayback.generation)
            streamSelectionDiagnostic
          } else if let youTubeVideoID = YouTubeWatchLink.videoID(from: detail.task.canonicalURL) {
            youTubeCard(videoID: youTubeVideoID)
          } else if let failure = model.localMediaResolutionFailure {
            VStack(alignment: .leading, spacing: 8) {
              Label(failure, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(theme.warning)
              Text("请在“设置 → 视频存储”重新选择文件夹，或把已保存的视频移回原位置。")
                .themedFont(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-local-missing")
          } else if localMediaFileURL == nil,
                    let sessionDescriptor = sessionMediaPlayback.cachedDescriptor(for: detail.task.id),
                    case .playable = CurrentCaptureMediaPreview.resolve(sessionDescriptor) {
            // Session LRU hit: restored streaming without re-persisting signed URLs.
            CurrentCaptureMediaPreviewCard(
              descriptor: sessionDescriptor,
              taskID: detail.task.id,
              snapshotID: latestSourceSnapshot?.id ?? detail.snapshots.last?.id ?? ContentSnapshotID(),
              model: model,
              onlineTranscriptionModel: providerSettings.effectiveTranscriptionModelName,
              tidyModel: providerSettings.effectiveTidyModelName,
              playback: remotePreviewPlayback,
              onRefreshStream: {
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              },
              onSelectQuality: { quality in
                // 旧画面继续播；新清晰度就绪后再切。立刻拆播放器会黑屏等十几秒。
                sessionMediaPlayback.requestRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author,
                  qualityOverride: quality
                )
              },
              selectedQuality: sessionMediaPlayback.chosenQuality(for: detail.task.id)
            )
            .padding(.top, 14)
            .accessibilityIdentifier("history-video-session-restored-card")
            // generation is read so cache/refresh updates re-render this branch.
            .id(sessionMediaPlayback.generation)
            streamSelectionDiagnostic
          } else if HistorySessionMediaPresentation.shouldShowSessionOnlyUnavailable(
            hadMediaDescriptor: detail.hadMediaDescriptor,
            hasLocalMediaFile: localMediaFileURL != nil,
            hasLocalMediaRow: detail.media != nil,
            hasLocalMediaResolutionFailure: model.localMediaResolutionFailure != nil,
            isCurrentCaptureWithDescriptor: showsCurrentCapture
              && appModel.currentCapture?.mediaDescriptor != nil,
            isYouTube: YouTubeWatchLink.videoID(from: detail.task.canonicalURL) != nil,
            isDouyinImagePost: isDouyinImagePostCapture,
            legacyPlatformHint: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
          ) {
            HistorySessionMediaUnavailableCard(
              sourceURL: sourceURL,
              phase: sessionMediaPlayback.activeTaskID == detail.task.id
                ? sessionMediaPlayback.phase
                : .idle,
              refreshAttempts: sessionMediaPlayback.refreshAttempts,
              onRefresh: {
                sessionMediaPlayback.requestRefresh(
                  taskID: detail.task.id,
                  platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
                  sourceURL: sourceURL,
                  author: sourceFrontmatter.author
                )
              }
            )
            .padding(.top, 14)
            .id(sessionMediaPlayback.generation)
          }
        }

        // Video-first captures keep playback before their short source text.
        // Substantive WeChat articles already rendered the reading surface above.
        if !presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            .padding(.top, 18)
        }

        // 脑图是正文的衍生输出，不再挡在阅读内容前面。先读总结／翻译／原文，
        // 再按需查看结构；视频条目仍保持「播放器 → 文字 → 脑图」的顺序。
        // 自己写的东西不挂脑图空状态，避免催促用户对刚写的几行字做结构化。
        if !isOwnWriting {
          MindMapSectionView(taskID: detail.task.id, model: model)
            .padding(.top, DesignTokens.Space.xl)
            .id(ReadingAnchor.module("mindmap"))
        }

        if !localImageURLs.isEmpty {
          imageTextRecognitionCard
            .padding(.top, 16)
            .id(ReadingAnchor.module("images"))
        }

        if isUserNote {
          backlinksSection
            .padding(.top, 20)
        }

        // 摘录是「读别人的东西时把话摘出来」。在自己写的东西下面再挂一个
        // 可写的框，等于同一页里两个地方都能写，谁也说不清该写哪个。
        if !isOwnWriting {
          AnnotationSectionView(taskID: detail.task.id, model: model)
            .padding(.top, 20)
            .id(ReadingAnchor.module("annotations"))
        }

        HistoryTagEditor(tags: detail.tags, model: model)
          .padding(.top, 20)
          .id(ReadingAnchor.module("tags"))
      }
      // 行宽随详情列可用宽度增长：SwiftUI 会把实际宽度收在
      // min(可用宽度 − inset, 字号联动上限)，不必把可用宽度写进 State。
      .frame(
        maxWidth: DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: readingFont.bodySize),
        alignment: .leading
      )
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, DesignTokens.Layout.readingHorizontalInset)
      .padding(.top, 32)
      .padding(.bottom, 48)
      .subtleScrollers()
    }
    .background(
      ReadingScrollContinuity(
        identity: detail.task.id.rawValue,
        progress: readingProgressModel
      )
      .frame(width: 0, height: 0)
    )
    // `initial: true` so the first item rendered also lands on the right pane;
    // previously the @State default won and a summary-less item opened on an
    // empty 总结 pane.
    .onChange(of: isEditingTranscription) { _, editing in
      if editing {
        sourceEditClickOutside.suppressUntil = suppressSourceEditFinishUntil
        sourceEditClickOutside.onClickOutside = finishSourceEditing
        sourceEditClickOutside.start()
      } else {
        sourceEditClickOutside.stop()
      }
    }
    .onChange(of: readingPane) { _, pane in
      if pane != .source { finishSourceEditing() }
    }
    .onChange(of: detail.task.id, initial: true) { _, _ in
      // 先把上一条笔记的草稿落库，再重置状态——顺序反了就等于丢掉它。
      if let leaving = editingNote {
        flushNoteDraft(
          taskID: leaving.taskID, snapshotID: leaving.snapshotID, storedBody: leaving.storedBody
        )
      }
      editingNote = nil
      isRunPanelExpanded = false
      showsPlainText = false
      completionBanner = nil
      pendingRunPane = nil
      isCaptionExpanded = false
      isTranscriptExpanded = false
      isSubtitleExpanded = false
      selectedSourceLayer = nil
      selectedTranslationLayer = nil
      readingPane = defaultReadingPane
      // 保活集合不跨条目：上一条访问过哪些面板不该让这一条多付隐藏布局。
      visitedReadingPanes = []
      pendingSourceCitation = nil
      ReadingSelectionRouter.shared.formatter = { selected in
        ReadingCitationFormatter.format(selection: selected, title: readingPrimaryTitle, sourceURL: sourceURL)
      }
      measuredTitleHeight = HistoryDetailView.titleLineHeight
      // 切换条目时丢弃未保存的转写草稿，避免草稿串到别的记录。
      isEditingTranscription = false
      transcriptionDraft = ""
      sourceEditCaretUTF16 = 0
      // 有正文的笔记先看排版，点字再写。空笔记（含刚建的）没有可读的东西，
      // 仍一打开就进编辑，否则多出来一次空击。
      if isOwnWriting, let snapshot = latestSnapshot {
        let body = storedNoteBody(snapshot)
        transcriptionDraft = body
        editingNote = (detail.task.id, snapshot.id, body)
        if body.isEmpty {
          isEditingTranscription = true
        }
      }
      noteTitleDraft = title
      // 清洗规则是后加的，早先存下的标题里还留着 U+FFFC 那类显示成方块的字符。
      // 打开时顺手修掉：它们不是内容，用户也删不掉（光标跳过去像没东西）。
      if isOwnWriting {
        let cleaned = UserNoteDocument.sanitizedTitle(title)
        if !cleaned.isEmpty, cleaned != title {
          model.renameNote(taskID: detail.task.id, title: cleaned)
          noteTitleDraft = cleaned
        }
      }
      noteBacklinks = isUserNote ? model.backlinks(forTitle: noteTitleDraft) : []
      // 排除自己：一条笔记链向自己没有意义，出现在候选里只会误选。
      noteLinkTitles = isUserNote
        ? model.noteTitlesForLinking().filter { $0 != title }
        : []
      sessionMediaPlayback.detailBecameActive(
        taskID: detail.task.id,
        platform: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform,
        sourceURL: sourceURL,
        author: sourceFrontmatter.author,
        hadMediaDescriptor: HistorySessionMediaPresentation.expectsSessionMedia(
          hadMediaDescriptor: detail.hadMediaDescriptor,
          isDouyinImagePost: isDouyinImagePostCapture,
          legacyPlatformHint: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
        ),
        hasLocalMedia: localMediaFileURL != nil || detail.media != nil,
        isCurrentCaptureWithDescriptor: showsCurrentCapture
          && appModel.currentCapture?.mediaDescriptor != nil,
        isYouTube: YouTubeWatchLink.videoID(from: detail.task.canonicalURL) != nil
      )
    }
    .alert("无法保存转写修改", isPresented: Binding(
      get: { model.snapshotEditFailure != nil },
      set: { if !$0 { model.dismissSnapshotEditFailure() } }
    )) {
      Button("好") { model.dismissSnapshotEditFailure() }
    } message: { Text(model.snapshotEditFailure ?? "") }
    .onChange(of: hasResultBody) { _, hasResult in
      // Prefer the fresh result when a run lands, but keep 原文 one tap away.
      if hasResult { readingPane = defaultReadingPane }
    }
    .onDisappear { ReadingSelectionRouter.shared.formatter = nil }
    .onChange(of: showsLiveRunInReadingPane) { wasShown, isShown in
      // 生成过程就在总结/翻译页里。完成后草稿换成落库正文，闪一下横幅。
      // 停止和失败仍留在这一页，把原因说清楚。
      guard wasShown, !isShown, hasResultBody else { return }
      guard case .completed = appModel.runState else { return }
      pendingRunPane = nil
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        readingPane = defaultReadingPane
        completionBanner = latestArtifactRun?.run.kind == .translate ? "翻译已完成" : "总结已完成"
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { completionBanner = nil }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        // 上一条／下一条：在当前队列里连着读，不用回左栏。到列表两端各自禁用。
        // 导航和有没有正文无关，所以放在字号/朗读那组之外、最前面。
        ControlGroup {
          Button {
            model.selectAdjacent(offset: -1)
          } label: {
            Label("上一条", systemImage: "chevron.up")
          }
          .disabled(!model.canSelectPrevious)
          .keyboardShortcut(.upArrow, modifiers: .command)
          .accessibilityIdentifier("reading-previous-item")
          Button {
            model.selectAdjacent(offset: 1)
          } label: {
            Label("下一条", systemImage: "chevron.down")
          }
          .disabled(!model.canSelectNext)
          .keyboardShortcut(.downArrow, modifiers: .command)
          .accessibilityIdentifier("reading-next-item")
        }
        .help("上一条 / 下一条（⌘↑ / ⌘↓）")
        .accessibilityIdentifier("reading-item-navigation")

        // 阅读区字号的快捷调节，省得为改字号专门开设置。只在有正文可读时出现——
        // 纯视频、无正文的详情里字号没有意义。两个按钮到边界各自禁用。
        if hasReadableBody {
          // 用图标而不是「小」「大」两个字：这一排其余全是 SF Symbol，
          // 夹两个汉字进去，工具栏就有了两种视觉语言，一眼看过去像没做完。
          // 图标自带大小语义，也不必再靠字号差别去暗示按钮的作用。
          ControlGroup {
            Button {
              adjustReadingFontSize(by: -ReadingFontSize.step)
            } label: {
              Label("缩小正文字号", systemImage: "textformat.size.smaller")
            }
            .disabled(readingFontSizeRaw <= Double(ReadingFontSize.minimum))
            .accessibilityIdentifier("reading-font-smaller")
            Button {
              adjustReadingFontSize(by: ReadingFontSize.step)
            } label: {
              Label("放大正文字号", systemImage: "textformat.size.larger")
            }
            .disabled(readingFontSizeRaw >= Double(ReadingFontSize.maximum))
            .accessibilityIdentifier("reading-font-larger")
          }
          .help("调整正文字号")
          .accessibilityIdentifier("reading-font-size-control")
        }

        if model.canToggleFavorite || model.canEditTags {
          ControlGroup {
            if model.canToggleFavorite {
              let favorited = model.isSelectedFavorite
              Button { model.toggleFavorite() } label: {
                Label(
                  favorited ? "取消收藏" : "收藏",
                  systemImage: favorited ? "star.fill" : "star")
              }
              .help(favorited ? "取消收藏" : "收藏")
              .accessibilityIdentifier("reading-toggle-favorite")
            }
            if model.canEditTags {
              Button { isTagPopoverPresented = true } label: {
                Label("标签", systemImage: "tag")
              }
              .help("添加标签")
              .accessibilityIdentifier("reading-quick-tag")
              .popover(isPresented: $isTagPopoverPresented, arrowEdge: .bottom) {
                HistoryTagEditor(tags: detail.tags, model: model, autoExpandComposer: true)
                  .padding(DesignTokens.Space.lg)
                  .frame(width: 320)
              }
            }
          }
        }

        // 溢出菜单：分享、重新生成、删除三组低频操作收进这里。
        //
        // 原本它们和「设置」「新建笔记」「上一条」并排成一长条，12 个图标
        // 平铺，用户分不出哪些作用于当前这条、哪些是全局动作。更糟的是
        // **删除就裸露在最右端**，紧挨着刷新——误点的代价是一条内容没了。
        //
        // 导出那一组直接平铺进来，不做二级菜单：它们本来就属于「对这条做点
        // 什么」，多一层嵌套只是多一次点击。
        Menu {
          Button("拷贝全文") { copyFullArticle() }
            .accessibilityIdentifier("history-copy-full-text")
          Divider()
          Button("导出 Markdown (.md)") { exportCleanText(.markdown) }
          Button("导出纯文本 (.txt)") { exportCleanText(.plainText) }
          Button("导出 PDF (.pdf)") { exportStyledDocument(.pdf) }
            .accessibilityIdentifier("history-export-pdf")
          Button("导出 Word (.docx)") { exportStyledDocument(.docx) }
            .accessibilityIdentifier("history-export-docx")
          Button("导出完整数据 (.json)") { model.requestExport(.json) }
          Divider()
          Toggle("以纯文本查看正文", isOn: $showsPlainText)
            .accessibilityIdentifier("history-content-plain-text-toggle")
          Divider()
          if canRecaptureSource {
            Button("重新抓取原文…") { openRecapture(sourceURL) }
              .accessibilityIdentifier("history-recapture-source")
            Divider()
          }
          Button("重新生成…") { isRegeneratePopoverPresented = true }
            .disabled(summarizeUnavailableReason != nil)
            .help(summarizeUnavailableReason ?? "用本机已保存正文重新总结或翻译")
            .accessibilityIdentifier("regenerate-history")
          Divider()
          // `role: .destructive` 让系统把它标红并排在最后，这是 macOS 菜单里
          // 「这一项会毁掉东西」的标准表达，比自己涂色可靠。
          Button("删除", role: .destructive) {
            model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
          }
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
          .accessibilityIdentifier("delete-history")
        } label: {
          Label("更多", systemImage: "ellipsis")
        }
        // popover 锚在这个按钮上——原来它挂在独立的「重新生成」按钮上，
        // 那个按钮现在没了，锚点得跟过来。
        .popover(isPresented: $isRegeneratePopoverPresented) { regeneratePopover }
        .accessibilityIdentifier("export-history")
      }
    }
    .accessibilityIdentifier("history-detail")
  }

  private var hasReadableBody: Bool {
    if let artifact = latestArtifact, !artifact.bodyText.isEmpty { return true }
    if let snapshot = detail.snapshots.last, !snapshot.bodyText.isEmpty { return true }
    return false
  }

  /// User-authored local records have no remote source to refresh. Web sources
  /// reuse ManualLinkViewModel so platform adapters and duplicate confirmation
  /// stay identical to the existing "添加链接" path.
  private var canRecaptureSource: Bool {
    guard !isOwnWriting,
          let components = URLComponents(string: sourceURL),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host?.isEmpty == false
    else { return false }
    return true
  }

  /// 拷贝全文：与阅读区同源的正文 Markdown（不含导出 YAML 头）。
  private func copyFullArticle() {
    guard let composed = model.composeExportMarkdown() else { return }
    let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
    CopyFeedbackController.shared.copy(body.isEmpty ? composed.markdown : body)
  }

  /// 富格式导出：按 App 阅读排版渲染 PDF / Word，NSSavePanel 落盘。
  /// 干净正文导出（md / txt）：与阅读区一致，不含 Core 档案元数据。
  private func exportCleanText(_ format: HistoryExportFormat) {
    guard let composed = model.composeExportMarkdown() else { return }
    let content: String
    let ext: String
    switch format {
    case .plainText:
      // 纯文本：剥 Markdown 标记与 frontmatter，只留可读正文。
      let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
      content = MarkdownPresentation.plainTextPresentation(body.isEmpty ? composed.markdown : body)
      ext = "txt"
    default:
      content = composed.markdown
      ext = "md"
    }
    guard let data = content.data(using: .utf8), !data.isEmpty else { model.failExportSave(); return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(composed.baseFilename).\(ext)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url) } catch { model.failExportSave() }
  }

  private func exportStyledDocument(_ kind: StyledExportKind) {
    guard let composed = model.composeExportMarkdown() else { return }
    let body = MarkdownNoteFrontmatter.parse(composed.markdown).body
    let attributed = ReadingDocumentExport.attributedDocument(
      markdown: body.isEmpty ? composed.markdown : body,
      readingFont: readingFont,
      localImageURLs: localImageURLs
    )
    let data: Data?
    switch kind {
    case .pdf: data = ReadingDocumentExport.pdfData(from: attributed)
    case .docx: data = try? ReadingDocumentExport.docxData(from: attributed)
    }
    guard let data, !data.isEmpty else {
      model.failExportSave()
      return
    }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [kind.contentType]
    panel.nameFieldStringValue = "\(composed.baseFilename).\(kind.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url) } catch { model.failExportSave() }
  }

  /// Capsule tool strip under the title — product control, not system Disclosure.
  /// Captions from short-video platforms are the document title here and can run
  /// to several hundred characters. The title stays visually a title (never the
  /// tallest thing on screen) by capping at three lines and scrolling the rest,
  /// rather than truncating text the reader cannot recover any other way.
  private static let titleFontSize: CGFloat = 22
  private static let titleLineHeight: CGFloat = 28
  private static var titleMaximumHeight: CGFloat { titleLineHeight * 3 }

  private var titleNeedsScrolling: Bool { measuredTitleHeight > Self.titleMaximumHeight }

  /// 选流诊断仍挂在带清晰度菜单的卡片下，方便排障时打开；出货默认不渲染。
  /// Cookie / API 档位 / CDN 白名单不是观看需要的内容。
  private static let showsStreamSelectionDiagnostic =
    ProcessInfo.processInfo.environment["LINKDIGEST_PRINT_CHANGES"] == "1"

  @ViewBuilder private var streamSelectionDiagnostic: some View {
    if Self.showsStreamSelectionDiagnostic,
       let selection = sessionMediaPlayback.selectionDiagnostic {
      Text(selection)
        .themedFont(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
        .accessibilityIdentifier("history-video-selection-diagnostic")
    }
  }

  @ViewBuilder private var titleView: some View {
    if isOwnWriting {
      // 自己写的东西标题就地可改。抓取记录的标题保持只读——那是抓来的事实。
      TextField(UserNoteDocument.untitledTitle, text: $noteTitleDraft)
        .textFieldStyle(.plain)
        .font(readingFont.font(size: Self.titleFontSize, weight: .bold))
        .foregroundStyle(theme.primaryText)
        .tracking(-0.4)
        .lineLimit(1...3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 失焦即存，不给标题单独配一个保存按钮：一页里两个保存按钮，
        // 用户得先判断自己改的算哪一种。
        .onSubmit { commitNoteTitle() }
        .onChange(of: focusedField) { previous, _ in
          if previous == .noteTitle { commitNoteTitle() }
        }
        .focused($focusedField, equals: .noteTitle)
        .accessibilityIdentifier("history-detail-title")
    } else {
      VStack(alignment: .leading, spacing: 4) {
        if titleNeedsScrolling {
          ScrollView(.vertical) {
            measuredTitleText
          }
          .frame(height: Self.titleMaximumHeight)
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.automatic)
          .accessibilityIdentifier("history-detail-title")
        } else {
          measuredTitleText
            .accessibilityIdentifier("history-detail-title")
        }
        if let original = readingOriginalSubtitle {
          Text(original)
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history-detail-original-title")
            .accessibilityLabel("原文标题 \(original)")
        }
      }
    }
  }

  private var measuredTitleText: some View {
    Text(readingPrimaryTitle)
      .font(readingFont.font(size: Self.titleFontSize, weight: .bold))
      .foregroundStyle(theme.primaryText)
      .tracking(-0.4)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: TitleHeightPreferenceKey.self, value: proxy.size.height)
        }
      )
      .onPreferenceChange(TitleHeightPreferenceKey.self) { height in
        guard height > 0 else { return }
        measuredTitleHeight = height
      }
  }

  /// 只有模型通道真的占上（或弹出数据去向确认）时才切阅读页，避免只打开空翻译页。
  private func engageReadingPane(_ pane: ReadingPane, started: Bool) {
    guard started else { return }
    pendingRunPane = pane
    readingPane = pane
  }

  /// 重试没跑完的那一类运行。走的是和工具栏按钮完全相同的入口——
  /// 重试如果另起一条路径，两边的前置校验迟早会漂移。
  private func retryUnfinishedRun(_ kind: RunKind) {
    Task {
      switch kind {
      case .summarize:
        await appModel.summarize(historyDetail: detail, preferences: providerSettings.runPreferences)
      case .translate:
        await appModel.translate(historyDetail: detail, preferences: providerSettings.runPreferences)
      }
    }
  }

  /// 「链接到这条的笔记」。
  ///
  /// 双链的价值一半在反向：正向链接只是省了一次搜索，反向才让关联自己浮现——
  /// 写第三条笔记时才发现前两条都指向它，那个「它」就是个值得单独想的题目。
  ///
  /// 一条都没有时整块不出现。空的「反向链接（0）」每天提醒你还没建立关联，
  /// 是种没有用处的压力。
  @ViewBuilder private var backlinksSection: some View {
    if !noteBacklinks.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("链接到这条的笔记 \(noteBacklinks.count)", systemImage: "arrow.turn.up.left")
          .themedFont(.callout, weight: .medium)
          .foregroundStyle(.secondary)
        ForEach(noteBacklinks) { backlink in
          Button {
            finishSourceEditing()
            model.reveal(taskID: backlink.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "square.and.pencil")
                .font(.system(size: DesignTokens.IconSize.inline))
                .foregroundStyle(.tertiary)
              Text(backlink.title)
                .themedFont(.callout)
                .lineLimit(1)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .linkCursor()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
      )
      .accessibilityIdentifier("note-backlinks")
    }
  }

  /// 整理排版的进行/失败状态。成功不单独报喜——正文当场变了，那就是结果。
  @ViewBuilder private var noteTidyStatus: some View {
    switch model.transcriptTidyState(for: detail.task.id) {
    case .running:
      ProgressView().controlSize(.small)
      Text("正在整理…").themedFont(.caption).foregroundStyle(.secondary)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .themedFont(.caption)
        .foregroundStyle(theme.warning)
        .accessibilityIdentifier("note-tidy-failed")
    default:
      EmptyView()
    }
  }

  private var actionToolbar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        actionPill(
          title: appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .summarize) ? "已排队" : "总结",
          systemImage: "text.alignleft",
          prominent: false,
          disabled: summarizeUnavailableReason != nil,
          identifier: showsCurrentCapture ? "summarize-current-capture" : "summarize-history-detail"
        ) {
          Task {
            let started = await appModel.summarize(
              historyDetail: detail,
              preferences: providerSettings.runPreferences
            )
            engageReadingPane(.summary, started: started)
          }
        }
        actionPill(
          title: appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .translate) ? "已排队" : "翻译",
          systemImage: "character.book.closed",
          prominent: false,
          disabled: translateUnavailableReason != nil,
          identifier: showsCurrentCapture ? "translate-current-capture" : "translate-history-detail"
        ) {
          Task {
            let started = await appModel.translate(
              historyDetail: detail,
              preferences: providerSettings.runPreferences
            )
            engageReadingPane(.translation, started: started)
          }
        }
        .help(
          appModel.translationUnavailableReason(
            snapshots: detail.snapshots,
            outputLanguage: providerSettings.runPreferences.outputLanguage
          ) ?? "把当前正文翻译为\(providerSettings.runPreferences.outputLanguage)"
        )
        // 生成脑图和总结、翻译是同一类动作：都是把正文交给模型换回一份新产物，
        // 前置条件（有正文 + 配好模型）、代价（花 token，必经确认）和结果
        // （一份可保存、可导出的东西）完全一致。原来它却单独待在媒体和正文之间，
        // 是一行很容易滚过去的小按钮——同类不同位。
        //
        // 已经有脑图就不显示：那时候「重新生成」在脑图卡自己的标题行里，
        // 挨着主题切换和导出，和它们是一组。
        if !isOwnWriting, model.mindMapRecord?.taskID != detail.task.id {
          actionPill(
            title: appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap) ? "已排队" : "生成脑图",
            systemImage: "brain",
            prominent: false,
            disabled: mindMapUnavailableReason != nil,
            identifier: "mind-map-generate"
          ) {
            if appModel.canEnqueueManualGeneration(for: detail.task.id)
              || appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap) {
              appModel.enqueueOrCancelMindMapGeneration(taskID: detail.task.id)
            } else {
              model.requestMindMapGeneration(taskID: detail.task.id)
            }
          }
          .help(
            mindMapUnavailableReason
              ?? (appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap)
                ? "再点一次取消排队"
                : "把正文发给模型提取结构")
          )
        }
        if isOwnWriting {
          // 想到哪写到哪的东西需要有人重排结构：标题和正文黏成一段、编号挤在
          // 一行、层级看不出来。这跟「修转写错别字」是两件事，用的是另一套提示词。
          actionPill(
            title: "整理排版",
            systemImage: "text.alignleft",
            prominent: true,
            disabled: !model.canTidyNote(taskID: detail.task.id),
            identifier: "tidy-note"
          ) {
            model.requestNoteTidy(taskID: detail.task.id, model: providerSettings.effectiveTidyModelName)
          }
          .help(model.noteTidyUnavailableReason(taskID: detail.task.id) ?? "把段落、列表与标题层级重排一遍；不改文字内容")
          noteTidyStatus
        }
        Spacer(minLength: 0)
        // 这一行只留状态和停止。生成中的正文在总结/翻译页里长出来。
        if showsVisibleRun {
          if appModel.canStopVisibleRun(for: detail.task.id) {
            Button("停止", role: .cancel) { Task { await appModel.stop() } }
              .controlSize(.small)
              .accessibilityIdentifier("stop-model-run")
          }
          if appModel.runState.isActive {
            ProgressView()
              .controlSize(.small)
          }
          Text(appModel.runStatusText)
            .themedFont(.subheadline, weight: .medium)
            .foregroundStyle(appModel.runHasFailure ? theme.danger : Color.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("model-run-status")
        }
      }
      if let runActionBlockedReason {
        Text(runActionBlockedReason)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("history-run-blocked-reason")
      }

      HStack(spacing: DesignTokens.Space.sm) {
        if !providerSettings.arePreferencesReady {
          Button("设置模型") { openSettings() }
            .buttonStyle(.link)
            .themedFont(.caption, weight: .medium)
            .accessibilityIdentifier("history-open-model-settings")
        } else {
          Label(
            providerSettings.activeSummaryModelName.isEmpty
              ? "模型未命名"
              : providerSettings.activeSummaryModelName,
            systemImage: "cpu"
          )
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        }
        Spacer(minLength: 0)
        if canRunHistory || showsCurrentCapture || isRunPanelExpanded || hasCollapsedRunMetadata {
          Button(isRunPanelExpanded ? "收起运行详情" : "运行详情") {
            withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isRunPanelExpanded.toggle() }
          }
          .buttonStyle(.borderless)
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-run-panel-toggle")
        }
      }

      // Optional model hints only — never dump streaming tokens here.
      if isRunPanelExpanded {
        captureAndRunControlsExtras
          .transition(historyBannerTransition(reduceMotion: reduceMotion))
      }
    }
  }

  @ViewBuilder private func actionPill(
    title: String,
    systemImage: String,
    prominent: Bool,
    disabled: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .themedFont(.callout, weight: prominent ? .semibold : .regular)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(prominent && !disabled ? theme.accent : theme.secondaryText)
    .controlSize(.small)
    .disabled(disabled)
    .accessibilityIdentifier(identifier)
  }

  /// Optional hints only (model names / storage). Streaming body lives in the reading card.
  /// 同时展示从顶部 metadata 移入的运行元数据（操作、模型、Token、状态、视频）。
  private var captureAndRunControlsExtras: some View {
    VStack(alignment: .leading, spacing: 8) {
      collapsedRunMetadata

      if showsCurrentCapture {
        currentCaptureExtras
      } else if canRunHistory {
        Text("使用本机已保存正文生成；结果作为新运行保存。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          settingsModelButton(providerSettings.activeSummaryModelName)
          settingsModelButton(providerSettings.effectiveTranslationModelName)
          Text("输出：\(providerSettings.runPreferences.outputLanguage)")
            .themedFont(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      if showsVisibleRun, appModel.runHasFailure {
        Text(appModel.runStatusText)
          .themedFont(.caption)
          .foregroundStyle(theme.danger)
          .accessibilityIdentifier("model-run-status-detail")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    // 用主题卡面而不是系统材质：材质随「降低透明度」失效且与详情页其余
    // 卡片语言不一致，这里曾是全库唯一一处材质背景。
    .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }

  private var currentCaptureExtras: some View {
    Group {
      HStack(spacing: 8) {
        Text(appModel.connection)
        Text("·")
        Text(appModel.storageStatusText)
      }
      .themedFont(.caption)
      .foregroundStyle(appModel.storageAvailability.isWriteReady ? Color.secondary : theme.warning)
      .accessibilityIdentifier("storage-availability")
      if let notice = appModel.dataDestinationNotice {
        Label(notice, systemImage: "info.circle")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("data-destination-notice")
      }
    }
  }

  /// 正文下方实际存在的模块。
  ///
  /// 按真实存在与否构造，不写死一张表：列出点了跳不到的死链接比不列更糟。
  /// 脑图、标注、标签区永远渲染（本身带空状态与添加入口），所以恒列；
  /// 图片区只在有本地图片时才存在。
  private var navigationModules: [ReadingModuleLink] {
    // 笔记只有正文和标签两件东西，一条「模块 3」的导航条指向的是别人页面的结构。
    if isOwnWriting { return [] }
    var links: [ReadingModuleLink] = [
      .init(anchor: "mindmap", title: "脑图", systemImage: "circle.hexagongrid")
    ]
    if !localImageURLs.isEmpty {
      links.append(.init(
        anchor: "images",
        title: "图片 \(localImageURLs.count)",
        systemImage: "photo.on.rectangle"
      ))
    }
    links.append(.init(anchor: "annotations", title: "标注", systemImage: "highlighter"))
    links.append(.init(anchor: "tags", title: "标签", systemImage: "tag"))
    return links
  }

  private var readingSurface: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      if showsReadingPanePicker {
        readingPanePicker
      }
      content
    }
    .animation(historyUIAnimation(reduceMotion: reduceMotion), value: showsLiveRunInReadingPane)
    // 正文铺满内容列，不再另设一层更窄的上限。
    //
    // 原来阅读区卡在 590pt，而它所在的内容列有 680pt，且左对齐——右边固定空出
    // 680 - 590 - 32 = 58pt，正文实际只有 558pt。那块空白不是留白设计，是两层
    // 上限打架的残留：读起来像卡片右边缺了一块。
    //
    // 行宽由外层内容列封顶（随详情列可用宽度增长，默认字号下绝对上限 960pt；
    // 字号变大时同比放宽）。真正的行宽控制点只应有一个，就是那一层。
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, showsReadingPanePicker ? 12 : 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    // 卡片外壳的意思是「这里装着一份抓回来的东西」。笔记正文不是装进来的，
    // 是当场写的——给它描边，写字的地方就变成了一个被展示的对象。
    //
    // 填充和描边是两件事，别一起处理。
    //
    // 填充在 paper / sepia / ink 下是卡片上再叠一张卡片：量出来底色 #FDFCF9、
    // 这层 #FEFEFC，差 1/255，看不见，只是白搭一层。所以非系统主题不填。
    //
    // 描边不一样——它就是那圈「画框」，是正文和上面那堆元数据之间唯一的分界。
    // 去掉之后正文只剩 10pt 间距托着，直接散开，所以**所有主题都保留**。
    // 非系统主题走 `theme.hairline`，跟窗口里其它分隔线同一个值。
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(isOwnWriting || !theme.isNative ? 0 : 0.55))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous)
        .strokeBorder(
          isOwnWriting ? Color.clear : (theme.isNative ? Color.primary.opacity(0.05) : theme.hairline),
          lineWidth: 1)
    )
  }

  private var showsReadingSurface: Bool {
    showsLiveRunInReadingPane || hasResultBody || hasSourceBody || isDouyinCapture
  }

  /// 原文里的层切换。
  ///
  /// 刻意和顶上「总结/翻译/原文」用同一种控件：两处是同一件事的两级——先选看
  /// 哪种产物，再选看哪一份原文。换成别的样式只会让人以为它们不是一类东西。
  private var sourceLayerPicker: some View {
    layerPicker(
      title: "原文层",
      layers: availableSourceLayers,
      active: activeSourceLayer,
      identifier: "history-source-layer-picker",
      select: { selectedSourceLayer = $0 }
    )
  }

  /// 译文里的层切换。和原文用**同一个**控件，不是长得像的另一个。
  ///
  /// 两处是同一件事：先选看哪种产物（总结/翻译/原文），再选看哪一层内容。
  /// 翻译页原来把各层纵向叠着，读者要滚过整份配文才够得着转写稿的译文。
  private var translationLayerPicker: some View {
    layerPicker(
      title: "译文层",
      layers: availableTranslationLayers,
      active: activeTranslationLayer,
      identifier: "history-translation-layer-picker",
      select: { selectedTranslationLayer = $0 }
    )
  }

  private func layerPicker(
    title: String,
    layers: [SourceLayer],
    active: SourceLayer?,
    identifier: String,
    select: @escaping (SourceLayer) -> Void
  ) -> some View {
    Picker(
      title,
      selection: Binding(
        get: { active ?? layers.first ?? .transcript },
        set: select
      )
    ) {
      ForEach(layers) { layer in
        Text(layer.heading).tag(layer)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .labelsHidden()
    .frame(maxWidth: 264)
    // 居中写在这里、而不是交给各自的父容器。
    //
    // 原文页的父容器是 `VStack(alignment: .leading)`、翻译页的不是，于是同一个
    // 控件在两处一个靠左一个居中——看起来像两个不同的东西。对齐属于「这个控件
    // 长什么样」的一部分，放进构造里才不会再次跑偏。
    .frame(maxWidth: .infinity, alignment: .center)
    .accessibilityIdentifier(identifier)
  }

  private var readingPanePicker: some View {
    HStack(spacing: 12) {
      Picker("阅读内容", selection: $readingPane) {
        ForEach(availableReadingPanes) { pane in
          Text(paneLabel(pane)).tag(pane)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .labelsHidden()
      .frame(maxWidth: 168)
      .accessibilityIdentifier("history-reading-pane-picker")
      Spacer(minLength: 0)
      ReadingProgressBadge(progress: readingProgressModel)
    }
  }

  /// 生成中的总结/翻译正文。就是这一页的内容，不再另挂一张预览卡。
  ///
  /// 单独成叶子视图并观察 `LiveRunTextModel`：流式拍点（正文纯增长）只
  /// 重绘这一小块，外层详情的元数据、工具栏、评论区不再每 250ms 跟着
  /// 重求值——那是生成期间滚动持续卡顿的来源。状态行等低频输入以值
  /// 传入，切换时由父视图整体刷新带过来。
  private var liveRunReadingBody: some View {
    LiveRunReadingBody(
      live: appModel.liveRunText,
      statusText: appModel.runStatusText,
      isActive: appModel.runState.isActive,
      hasFailure: appModel.runHasFailure,
      dangerColor: theme.danger,
      font: readingFont.nsFont(),
      color: NSColor(theme.primaryText),
      lineSpacing: MarkdownPresentation.bodyLineSpacing
    )
  }

  /// 标题下的一行浅字：作者 · 日期 · 站点。打开/复制链在同一行末尾，不再单独占三行表单。
  private var sourceByline: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text(sourceBylineText)
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Button("打开") { openSourceURL() }
        .buttonStyle(.link)
        .themedFont(.callout)
        .linkCursor()
        .accessibilityIdentifier("history-source-url-open")
      Button("复制链接") { CopyFeedbackController.shared.copy(sourceURL) }
        .buttonStyle(.link)
        .themedFont(.callout)
        .linkCursor()
        .accessibilityIdentifier("history-source-url-copy")
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("来源 \(sourceBylineText)")
    .accessibilityIdentifier("history-capture-metadata")
    .help(sourceURL)
  }

  private var sourceBylineText: String {
    var parts: [String] = []
    if let account = sourceFrontmatter.accountName?.trimmedNonEmpty {
      parts.append(account)
    }
    if let author = sourceFrontmatter.author?.trimmedNonEmpty,
       author != sourceFrontmatter.accountName {
      parts.append(author)
    }
    if let published = sourceFrontmatter.published {
      parts.append(historyPublishedDate(published))
    } else {
      parts.append(historyDate(detail.task.createdAtMilliseconds))
    }
    if let host = HistorySourceLinkPresentation.host(sourceURL) {
      parts.append(host)
    }
    return parts.joined(separator: " · ")
  }

  private var hasCollapsedRunMetadata: Bool {
    newestRun != nil || model.taskTokenGrandTotals != nil || videoMetadataValue != nil
  }

  @ViewBuilder
  private var collapsedRunMetadata: some View {
    if let run = newestRun {
      VStack(alignment: .leading, spacing: 6) {
        metadataRow {
          MetadataItem(symbol: "wand.and.stars", title: "操作", value: historyAction(run.run.kind))
          MetadataItem(symbol: "cpu", title: "模型", value: run.run.model?.trimmedNonEmpty ?? "—")
        }
        metadataRow {
          MetadataItem(
            symbol: "number",
            title: "Token",
            value: model.taskTokenGrandTotals.map { String($0.totalTokens) } ?? "—",
            detail: model.taskTokenGrandTotals.map {
              "输入 \($0.promptTokens) / 输出 \($0.completionTokens)"
            }
          )
          MetadataItem(symbol: "checkmark.circle", title: "状态", value: historyStatus(run.run.status))
          if let videoMetadataValue {
            MetadataItem(symbol: "play.rectangle", title: "视频", value: videoMetadataValue)
              .accessibilityIdentifier("history-video-metadata")
          }
        }
      }
      .themedFont(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
    } else if model.taskTokenGrandTotals != nil || videoMetadataValue != nil {
      metadataRow {
        if let totals = model.taskTokenGrandTotals {
          MetadataItem(
            symbol: "number",
            title: "Token",
            value: String(totals.totalTokens),
            detail: "输入 \(totals.promptTokens) / 输出 \(totals.completionTokens)"
          )
        }
        if let videoMetadataValue {
          MetadataItem(symbol: "play.rectangle", title: "视频", value: videoMetadataValue)
            .accessibilityIdentifier("history-video-metadata")
        }
      }
      .themedFont(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
    }
  }

  private func metadataRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var videoMetadataValue: String? {
    guard !suppressesEmbeddedMedia else { return nil }

    func descriptorValue(_ descriptor: MediaDescriptor) -> String {
      var parts = [CurrentCaptureMediaPreview.kindLabel(descriptor.kind)]
      if let duration = descriptor.durationSeconds, duration > 0 {
        parts.append(formatMediaDuration(duration))
      }
      if let format = descriptor.mimeType?.split(separator: "/").last,
         !format.isEmpty {
        parts.append(format.uppercased())
      }
      return parts.joined(separator: " · ")
    }

    if showsCurrentCapture,
       let capture = appModel.currentCapture,
       let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID)
         ?? capture.mediaDescriptor {
      return descriptorValue(descriptor)
    }
    if let descriptor = sessionMediaPlayback.cachedDescriptor(for: detail.task.id),
       case .playable = CurrentCaptureMediaPreview.resolve(descriptor) {
      return descriptorValue(descriptor)
    }
    if let media = detail.media {
      var parts = ["本机视频"]
      if let duration = media.durationSeconds, duration > 0 {
        parts.append(formatMediaDuration(duration))
      }
      if media.byteSize > 0 {
        parts.append(ByteCountFormatter.string(fromByteCount: media.byteSize, countStyle: .file))
      }
      return parts.joined(separator: " · ")
    }
    // 无 schema 迁移：用 V2 抓取事实（或极老 V1 抖音）标出「这是视频记录」，不编造时长。
    if HistorySessionMediaPresentation.expectsSessionMedia(
      hadMediaDescriptor: detail.hadMediaDescriptor,
      isDouyinImagePost: isDouyinImagePostCapture,
      legacyPlatformHint: latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
    ) {
      return "已抓取 · 此处不可播"
    }
    return nil
  }

  private func formatMediaDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// 互动数单独一行。作者/发布/公众号已经收进 byline，这里不再重复。
  @ViewBuilder
  private func notePropertiesStrip(_ note: MarkdownNoteFrontmatter) -> some View {
    HStack(spacing: DesignTokens.Space.lg) {
      if let likes = note.likes {
        Label(likes, systemImage: "heart")
          .accessibilityIdentifier("history-stats-likes")
      }
      if let comments = note.comments {
        Label(comments, systemImage: "bubble.right")
          .accessibilityIdentifier("history-stats-comments")
      }
      if let shares = note.shares {
        Label(shares, systemImage: "arrowshape.turn.up.right")
          .accessibilityIdentifier("history-stats-shares")
      }
      if let collects = note.collects {
        Label(collects, systemImage: "bookmark")
          .accessibilityIdentifier("history-stats-collects")
      }
      if let views = note.views {
        Label(views, systemImage: "eye")
          .accessibilityIdentifier("history-stats-views")
      }
    }
    .themedFont(.callout)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("history-engagement-stats")
  }

  private func localImageURL(forRemoteURL remoteURL: String) -> URL? {
    let digest = SHA256.hash(data: Data(remoteURL.utf8)).map { String(format: "%02x", $0) }.joined()
    return localImageURLs.first { $0.lastPathComponent == digest }
  }

  private var exactSummaryCitations: [String] {
    guard let summary = summaryArtifact?.bodyText, let source = latestSourceSnapshot?.bodyText else { return [] }
    // 走备忘缓存：原来每次 body 求值都要把原文整篇重建纯文本再逐条匹配，
    // 巨型 ViewModel 的任何无关变化都会触发一遍。
    return ReadingRenderCache.summaryCitations(summary: summary, source: source)
  }

  private func openSourceCitation(_ quote: String) {
    readingPane = .source
    pendingSourceCitation = nil
    DispatchQueue.main.async { pendingSourceCitation = quote }
  }

  @ViewBuilder private var sourceCitationLinks: some View {
    if !exactSummaryCitations.isEmpty {
      HStack(spacing: 8) {
        Label("原文依据", systemImage: "quote.opening")
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(.secondary)
        ForEach(Array(exactSummaryCitations.enumerated()), id: \.offset) { index, quote in
          Button("依据 \(index + 1)") { openSourceCitation(quote) }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        Spacer(minLength: 0)
      }
      .accessibilityIdentifier("history-summary-citations")
    }
  }

  /// 阅读面板：首次访问后保活，切换页签只翻透明度，不动几何。
  ///
  /// 原来的 `switch effectiveReadingPane` 每切一次页签就把整棵面板视图树
  /// 销毁重建：7 万字长文的一次冷渲染实测约 220ms（块解析 41ms + 富文本
  /// 组装 75ms + TextKit 全文排版 103ms），全部发生在主线程。保活的第一版
  /// 用「高度归零」折叠隐藏面板，真机采样又证明高度 0↔自然高度的切换本身
  /// 会驱动整个巨型文档的 SwiftUI 布局重算（每切一次约 320ms，2/3 走动画
  /// 上下文、1/3 走尺寸协商）。
  ///
  /// 所以这里改成：面板全部保持自然尺寸（布局零扰动），ZStack 容器高度
  /// 锁定为「当前活动面板的实测高度」——切换只是换一个已测好的数字加
  /// 两次透明度翻转。未访问过的面板不挂载（惰性）。各面板高度由
  /// GeometryReader 上报，只随内容变化，与切换无关。
  @ViewBuilder private var content: some View {
    ZStack(alignment: .top) {
      mountedReadingPane(.summary)
      mountedReadingPane(.translation)
      mountedReadingPane(.source)
    }
    .frame(height: paneHeights[effectiveReadingPane], alignment: .top)
    .clipped()
    // 初始面板由 `pane == effectiveReadingPane` 条件挂载（visited 起始为空，
    // 惰性成立）；这里只负责把后续切换过的面板记入保活集合。
    .onChange(of: effectiveReadingPane) { _, pane in
      visitedReadingPanes.insert(pane)
    }
  }

  @ViewBuilder
  private func mountedReadingPane(_ pane: ReadingPane) -> some View {
    if pane == effectiveReadingPane || visitedReadingPanes.contains(pane) {
      let isActive = pane == effectiveReadingPane
      readingPaneBody(pane)
        // 面板始终取理想高度，无视容器按「当前活动面板」定高的提议：
        // 否则切到矮面板时隐藏的高面板会被压缩重排，高度反馈环就此成形。
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: ReadingPaneHeightPreferenceKey.self,
              value: [pane: proxy.size.height]
            )
          }
        )
        .onPreferenceChange(ReadingPaneHeightPreferenceKey.self) { reported in
          for (reportedPane, height) in reported {
            // 高度只在内容变化时更新；同值重复写 @State 也会触发无效重求值。
            if paneHeights[reportedPane] != height {
              paneHeights[reportedPane] = height
            }
          }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
    }
  }

  @ViewBuilder
  private func readingPaneBody(_ pane: ReadingPane) -> some View {
    switch pane {
    case .summary, .translation:
      if showsLiveRunInReadingPane, liveRunReadingPane == pane {
        liveRunReadingBody
      } else if let artifact = artifact(for: pane), !artifact.bodyText.isEmpty {
        if artifact.completeness == .partial {
          Label("\(paneLabel(pane))不完整", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
        }
        if pane == .summary { sourceCitationLinks }
        // 译文和原文一样，一次只显示一层。控件放在正文之上，位置与原文页一致。
        if pane == .translation, showsTranslationLayerPicker {
          translationLayerPicker
            .padding(.bottom, 10)
        }
        // 旧版翻译把元数据块也翻了一遍，块卡在译文中段（前面是翻译后的标题），
        // 开头剥离对它无效。显示时按白名单再清一次；只清翻译——总结里出现
        // 同构块的可能性低，且误删的代价是丢正文。
        // 剥离与清理都是整篇扫描，走备忘缓存，正文没变不重付。
        // Summaries rarely carry images; still allow local map if present.
        MarkdownContentView(
          source: ReadingRenderCache.paneBody(
            // 分层时只喂当前那一层，元数据清理仍按整篇的规则走。
            source: (pane == .translation ? activeTranslationBody : nil) ?? artifact.bodyText,
            strippingEchoedMetadata: pane == .translation
          ),
          sourceURL: URL(string: sourceURL),
          localImageURLs: localImageURLs,
          appendsUnusedLocalImages: !isWeChatCapture,
          groupsConsecutiveImages: !isWeChatCapture,
          readingFont: readingFont,
          primaryTextColor: theme.primaryText,
          secondaryTextColor: theme.secondaryText,
          accentColor: theme.accent,
          showsPlainText: $showsPlainText,
          showsInlinePlainTextToggle: false,
          navigationModules: navigationModules,
          anchorScope: anchorScope(for: pane),
          onFollowWikiLink: { title in model.followWikiLink(toTitle: title) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-reading-result")
      } else {
        missingPaneNotice(for: pane)
      }
    case .source:
      sourcePaneBody
    }
  }

  /// 配文和转写是两层：转写完成后配文仍留在原文里，不再被转写稿盖掉。
  @ViewBuilder private var sourcePaneBody: some View {
    if hasLiveTranscription {
      VStack(alignment: .leading, spacing: 18) {
        if hasPresentableCaption, let caption = latestSourceSnapshot {
          sourceLayer(heading: LayeredSourceDocument.captionHeading, snapshot: caption)
        }
        // 已经读到的画面字幕，在实时转写进行时也必须留在页面上。
        //
        // 这一分支只画「配文 + 正在转写的文字」，漏掉字幕层的后果是：一条已经
        // 读出字幕的记录，只要走进这个分支，那一层就整个消失——数据在库里，
        // 界面上什么都看不到，和没保存完全一样。
        if let subtitles = latestSubtitleSnapshot {
          collapsibleSourceSection(
            heading: LayeredSourceDocument.subtitleHeading,
            snapshot: subtitles,
            isExpanded: $isSubtitleExpanded
          )
        }
        sourceLayerHeading(LayeredSourceDocument.transcriptHeading)
        LiveTranscriptionReadingBody(
          live: model.liveTranscriptionText,
          font: readingFont.nsFont(),
          color: NSColor(theme.primaryText),
          lineSpacing: MarkdownPresentation.bodyLineSpacing
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("history-reading-source")
    } else if showsLayeredSource {
      VStack(alignment: .leading, spacing: 14) {
        if showsSourceLayerPicker { sourceLayerPicker }
        switch activeSourceLayer {
        case .caption:
          if let caption = latestSourceSnapshot {
            collapsibleSourceSection(
              heading: LayeredSourceDocument.captionHeading,
              snapshot: caption,
              isExpanded: $isCaptionExpanded
            )
          }
        case .subtitles:
          if let subtitles = latestSubtitleSnapshot {
            collapsibleSourceSection(
              heading: LayeredSourceDocument.subtitleHeading,
              snapshot: subtitles,
              isExpanded: $isSubtitleExpanded
            )
          }
        case .transcript:
          if let transcript = latestTranscriptionSnapshot {
            collapsibleSourceSection(
              heading: LayeredSourceDocument.transcriptHeading,
              snapshot: transcript,
              isExpanded: $isTranscriptExpanded
            )
          }
        case nil:
          EmptyView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("history-reading-source")
    } else if let snapshot = (isDouyinCapture && !isDouyinImagePostCapture)
      ? latestTranscriptionSnapshot
      : latestSnapshot, !snapshot.bodyText.isEmpty {
      if snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue {
        collapsibleSourceSection(
          heading: LayeredSourceDocument.transcriptHeading,
          snapshot: snapshot,
          isExpanded: $isTranscriptExpanded
        )
          .accessibilityIdentifier("history-reading-source")
      } else if snapshot.sourceKind == CapturedDocument.Origin.burnedInSubtitles.rawValue {
        // 没有配文可分层时（抖音那类 caption 与标题重复的记录），字幕仍要带上
        // 自己的标题，否则它看起来就像抓来的原文。
        collapsibleSourceSection(
          heading: LayeredSourceDocument.subtitleHeading,
          snapshot: snapshot,
          isExpanded: $isSubtitleExpanded
        )
          .accessibilityIdentifier("history-reading-source")
      } else {
        sourceLayer(heading: nil, snapshot: snapshot)
          .accessibilityIdentifier("history-reading-source")
      }
    } else {
      missingPaneNotice(for: .source)
    }
  }

  private static let sourceCollapseCharacterLimit = 800

  private func isLongSource(_ snapshot: ContentSnapshot) -> Bool {
    LayeredSourceDocument.body(of: snapshot).count > Self.sourceCollapseCharacterLimit
  }

  private func sourcePreview(_ text: String) -> String {
    guard text.count > Self.sourceCollapseCharacterLimit else { return text }
    let prefix = String(text.prefix(Self.sourceCollapseCharacterLimit))
    if let lastBreak = prefix.lastIndex(where: \.isNewline) {
      let trimmed = String(prefix[..<lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @ViewBuilder
  private func collapsibleSourceSection(
    heading: String,
    snapshot: ContentSnapshot,
    isExpanded: Binding<Bool>
  ) -> some View {
    let body = LayeredSourceDocument.body(of: snapshot)
    let long = isLongSource(snapshot)
    let collapsed = long && !isExpanded.wrappedValue && !isEditingTranscription
    // 有切换控件时不再重复一遍层名：控件上就写着「配文 / 视频转写」，
    // 底下再来一行同样的字只是多占一行高度。没有控件的路径（只有一层、
    // 或者非分层来源）仍然要这个标题，否则那段正文就没有名字了。
    let showsHeading = !showsSourceLayerPicker
    let showsExpandControl = long && !isEditingTranscription
    VStack(alignment: .leading, spacing: 8) {
      if showsHeading || showsExpandControl {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if showsHeading { sourceLayerHeading(heading) }
          Spacer(minLength: 8)
          if showsExpandControl {
            Button(isExpanded.wrappedValue ? "收起" : "展开全文") {
              isExpanded.wrappedValue.toggle()
            }
            .controlSize(.small)
            .accessibilityIdentifier("history-source-expand")
          }
        }
      }
      if collapsed {
        sourceSnapshotReader(snapshot, bodyOverride: sourcePreview(body))
        Button("展开全文") { isExpanded.wrappedValue = true }
          .buttonStyle(.link)
          .themedFont(.callout, weight: .medium)
          .padding(.top, 4)
          .accessibilityIdentifier("history-source-expand-inline")
      } else {
        sourceSnapshotReader(snapshot)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sourceLayerHeading(_ title: String) -> some View {
    Text(title)
      .themedFont(.caption, weight: .semibold)
      .foregroundStyle(.secondary)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func sourceLayer(heading: String?, snapshot: ContentSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let heading {
        sourceLayerHeading(heading)
      }
      sourceSnapshotReader(snapshot)
    }
  }

  /// 阅读卡里不再重复印标题。笔记是用户自己写的，开头的标题要留着。
  private func displayedSourceMarkdown(_ snapshot: ContentSnapshot, bodyOverride: String?) -> String {
    let cleaned = bodyOverride ?? ReadingRenderCache.paneBody(
      source: snapshot.bodyText,
      strippingEchoedMetadata: false
    )
    guard !isOwnWriting else { return cleaned }
    return CapturedSourceBodyPresentation.strippingEchoedOpening(title: title, from: cleaned)
  }

  @ViewBuilder
  private func sourceSnapshotReader(_ snapshot: ContentSnapshot, bodyOverride: String? = nil) -> some View {
        if captureWasTruncated(snapshot.completeness) {
          Label("捕获内容已截断，生成结果可能不完整。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .accessibilityIdentifier("capture-truncated-notice")
        }
        // 可写正文：本机转写、笔记、稿、作品。网页捕获保持只读。
        // 默认看排版，单击进源码；空笔记仍一打开就写。
        if bodyOverride == nil, canEditSource(snapshot), isEditingTranscription {
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(sourceDraftIsDirty(snapshot) ? "正在保存…" : (noteSaveIndicator ? "已保存" : ""))
              .themedFont(.caption)
              .foregroundStyle(.tertiary)
              .animation(historyUIAnimation(reduceMotion: reduceMotion), value: noteSaveIndicator)
              .accessibilityIdentifier("history-note-save-state")
            Button("保存") { saveTranscriptionDraft(snapshot, exiting: false) }
              .keyboardShortcut("s", modifiers: .command)
              .hidden()
              .frame(width: 0)
              .accessibilityIdentifier("history-transcription-edit-save")
          }
          .padding(.bottom, 8)
        }
        if bodyOverride == nil, canEditSource(snapshot), isEditingTranscription {
          // 裸 TextEditor 把标题、代码、引用一律画成同一片灰字，写超过几行就看不出
          // 结构。换成带 Markdown 着色的 NSTextView，排版参数取自阅读区同一套偏好。
          MarkdownEditorView(
            text: $transcriptionDraft,
            font: readingFont.nsFont(),
            palette: .init(
              primary: NSColor(theme.primaryText),
              secondary: NSColor(theme.secondaryText),
              accent: NSColor(theme.accent),
              code: NSColor(theme.secondaryText)
            ),
            lineSpacing: 6,
            placeholder: isPieceDraft
              ? PieceDraftDocument.placeholderBody
              : (isUserNote ? UserNoteDocument.placeholderBody : ""),
            contentHeight: isOwnWriting ? $noteEditorHeight : nil,
            onFollowWikiLink: { title in
              // 先把手上这条存了再跳，否则刚写的内容会随着切换被丢掉。
              finishSourceEditing()
              model.followWikiLink(toTitle: title)
            },
            linkableTitles: isUserNote ? noteLinkTitles : [],
            initialCaretUTF16: sourceEditCaretUTF16,
            onFinishEditing: finishSourceEditing
          )
          .frame(
            minHeight: isOwnWriting ? max(noteEditorHeight, 320) : 320,
            maxHeight: isOwnWriting ? max(noteEditorHeight, 320) : .infinity
          )
          .onChange(of: transcriptionDraft) { _, _ in scheduleNoteAutosave() }
          // 笔记的编辑区就是这一页的正文，不再套一层描边的输入框——那层框是给
          // 「在只读页面上临时改一段」用的，笔记没有那个「临时」。
          .background(
            isOwnWriting
              ? Color.clear
              : (theme.isNative ? Color(nsColor: .textBackgroundColor) : theme.listPane)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
              .stroke(isOwnWriting ? Color.clear : theme.hairline, lineWidth: 1)
          )
          .accessibilityIdentifier("history-transcription-editor")
        } else {
          MarkdownContentView(
            // 链接化放在**最外层**：先让 paneBody 做完它的清理，再把时间码变成
            // 链接，免得清理步骤把刚生成的链接语法拆掉。
            source: timestampLinked(displayedSourceMarkdown(snapshot, bodyOverride: bodyOverride)),
            sourceURL: URL(string: sourceURL),
            localImageURLs: localImageURLs,
            appendsUnusedLocalImages: !isWeChatCapture,
            groupsConsecutiveImages: !isWeChatCapture,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            accentColor: theme.accent,
            showsPlainText: $showsPlainText,
            showsInlinePlainTextToggle: false,
            navigationModules: navigationModules,
            anchorScope: anchorScope(for: .source) + ".\(snapshot.id.rawValue)",
            revealText: pendingSourceCitation,
            onFollowWikiLink: { title in
              if sourceDraftIsDirty(snapshot) {
                saveTranscriptionDraft(snapshot, exiting: false)
              }
              model.followWikiLink(toTitle: title)
            },
            onSeekMedia: { seconds in model.requestMediaSeek(toSeconds: seconds) },
            onRequestEdit: bodyOverride == nil && canEditSource(snapshot) && !model.isReadOnly
              ? { snippet in beginSourceEditing(snapshot, displayedSnippet: snippet) }
              : nil
          )
          .simultaneousGesture(
            TapGesture().onEnded {
              guard bodyOverride == nil, canEditSource(snapshot), !model.isReadOnly else { return }
              beginSourceEditing(snapshot, displayedSnippet: nil)
            }
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
  }

  /// 哪些层允许就地校对。
  ///
  /// 画面字幕和听写稿一样是机器识别的结果，一样会有错字（实测出现过
  /// 「还有 个想法」这种断字），凭什么听写能改而它不能。抓来的原始配文
  /// 不在此列——那是来源的原话，不该被改写。
  /// 这条记录有没有可跳转的视频。
  ///
  /// 没有视频时不做链接化：纯文章里的 `00:00` 点了无处可去，把它渲染成链接
  /// 只会让人以为坏了。
  private var hasSeekableMedia: Bool {
    detail.media != nil || localMediaFileURL != nil
  }

  /// 有视频才把段首时间码变成可点击链接。
  private func timestampLinked(_ text: String) -> String {
    guard hasSeekableMedia else { return text }
    return MediaSeekLink.linkifyingTimestamps(in: text)
  }

  private func canEditSource(_ snapshot: ContentSnapshot) -> Bool {
    snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
      || snapshot.sourceKind == CapturedDocument.Origin.burnedInSubtitles.rawValue
      || snapshot.sourceKind == CapturedDocument.Origin.userNote.rawValue
      || snapshot.sourceKind == CapturedDocument.Origin.pieceDraft.rawValue
      || snapshot.sourceKind == CapturedDocument.Origin.work.rawValue
  }

  private func sourceDraftIsDirty(_ snapshot: ContentSnapshot) -> Bool {
    if isOwnWriting { return noteDraftIsDirty(snapshot) }
    return transcriptionDraft != MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
  }

  private func beginSourceEditing(_ snapshot: ContentSnapshot, displayedSnippet: String?) {
    guard !model.isReadOnly, !isEditingTranscription else { return }
    let body = isOwnWriting
      ? storedNoteBody(snapshot)
      : MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
    transcriptionDraft = body
    sourceEditCaretUTF16 = ReadingEditLocator.caretUTF16Offset(
      in: body, displayedSnippet: displayedSnippet
    )
    // 打开编辑器用的就是这次点击。编辑器成为第一响应者之后，同一次
    // mouseUp 还会让它立刻失焦，textDidEndEditing 会把编辑态关回去。
    suppressSourceEditFinishUntil = Date().addingTimeInterval(0.6)
    sourceEditClickOutside.suppressUntil = suppressSourceEditFinishUntil
    isEditingTranscription = true
    if isOwnWriting {
      editingNote = (detail.task.id, snapshot.id, body)
    }
  }

  private func finishSourceEditing() {
    guard isEditingTranscription else { return }
    if let until = suppressSourceEditFinishUntil, Date() < until { return }
    sourceEditClickOutside.stop()
    noteAutosaveTask?.cancel()
    if let snapshot = latestSnapshot, sourceDraftIsDirty(snapshot) {
      saveTranscriptionDraft(snapshot, exiting: true)
      return
    }
    isEditingTranscription = false
    if !isOwnWriting { transcriptionDraft = "" }
  }

  /// 保留原 frontmatter，只把正文替换为校对稿；无 frontmatter 时整体替换。
  private func saveTranscriptionDraft(_ snapshot: ContentSnapshot, exiting: Bool) {
    let original = snapshot.bodyText
    let body = MarkdownNoteFrontmatter.parse(original).body
    let newText: String
    if !body.isEmpty, let range = original.range(of: body) {
      newText = original.replacingCharacters(in: range, with: transcriptionDraft)
    } else {
      newText = transcriptionDraft
    }
    let savedDraft = transcriptionDraft
    model.saveEditedSnapshotText(taskID: detail.task.id, snapshotID: snapshot.id, bodyText: newText)
    if isOwnWriting {
      // 存过之后这条笔记的「库里那份」就是刚写的内容了，切走时不该再存一遍。
      editingNote = (detail.task.id, snapshot.id, savedDraft)
      // 标题还是默认值时，用正文首个一级标题补上：写笔记的人极少先想标题。
      if title == UserNoteDocument.untitledTitle,
         let derived = UserNoteDocument.derivedTitle(fromBody: savedDraft) {
        model.renameNote(taskID: detail.task.id, title: derived)
        noteTitleDraft = derived
      }
    }
    if exiting {
      isEditingTranscription = false
      if !isOwnWriting { transcriptionDraft = "" }
    }
  }

  private var effectiveReadingPane: ReadingPane {
    // With neither summary nor transcription, keep the Douyin empty-state in
    // the reading surface without reintroducing an unavailable 原文 segment.
    if isDouyinCapture,
       !hasResultBody,
       !hasSourceBody,
       !hasLiveTranscription,
       liveRunReadingPane == nil {
      return .source
    }
    // 选中的格子消失了就退回默认，否则会停在一个已经不在分段控件里的面板上。
    // 这个兜底原来只对抖音生效；拆出翻译格后，任何条目都可能出现选中格不可用
    // （例如切到另一条只总结过的记录时，选中的还是翻译）。
    if !availableReadingPanes.contains(readingPane) { return defaultReadingPane }
    return readingPane
  }

  /// 面板保活后总结/翻译/原文会同时挂载，各自 MarkdownContentView 的
  /// 章节锚点（block 序号）必须按面板隔离，否则目录跳转会撞到隐藏面板
  /// 的同名锚点上。模块锚点（tags 等）只在详情页注册一份，不受影响。
  private func anchorScope(for pane: ReadingPane) -> String {
    "\(detail.task.id.rawValue)#\(pane.rawValue)"
  }

  /// Selecting an empty pane explains itself instead of showing a bare
  /// "暂无可显示的内容", which read as a failure rather than a pending action.
  @ViewBuilder private func missingPaneNotice(for pane: ReadingPane) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch pane {
      case .summary, .translation:
        Text(pane == .translation ? "尚未生成翻译" : "尚未生成总结").foregroundStyle(.secondary)
        if canRunHistory || showsCurrentCapture {
          Text(pane == .translation ? "点击上方「翻译」开始" : "点击上方「生成总结」开始")
            .themedFont(.callout)
            .foregroundStyle(.tertiary)
        }
      case .source:
        Text(isDouyinCapture && !isDouyinImagePostCapture ? "尚未转写" : "本条没有抓取到正文")
          .foregroundStyle(.secondary)
        if isDouyinCapture, !isDouyinImagePostCapture,
           model.canTranscribeVideo || (showsCurrentCapture && appModel.currentCapture?.mediaDescriptor.map {
             model.canTranscribeCurrentCapture($0, taskID: detail.task.id)
           } == true) {
          Text("点击上方的『转写』开始")
            .themedFont(.callout)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 24)
    .accessibilityIdentifier(pane == .source ? "history-reading-source-empty" : "history-reading-result-empty")
  }

  private var imageTextRecognitionCard: some View {
    let recognitionState = model.imageTextRecognitionState(for: detail.task.id)
    let recognizedText = model.recognizedImageText(for: detail.task.id)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .fill(theme.info.opacity(0.12))
          Image(systemName: "text.viewfinder")
            .foregroundStyle(theme.info)
        }
        .frame(width: 34, height: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text("图片文字识别").themedFont(.headline)
          Text("Apple Vision 本机处理，图片不会上传。")
            .themedFont(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if recognitionState == .recognizing {
          Button("取消", role: .cancel, action: model.cancelImageTextRecognition)
            .controlSize(.small)
        } else {
          Button(recognitionState == .completed ? "重新识别" : "识别文字", action: model.recognizeImageText)
            .controlSize(.small)
            .disabled(!model.canRecognizeImageText)
            .accessibilityIdentifier("history-image-ocr-start")
        }
      }
      switch recognitionState {
      case .idle:
        Text("从正文缓存的 \(localImageURLs.count) 张图片提取可复制文字。")
          .themedFont(.caption).foregroundStyle(.secondary)
      case .recognizing:
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机识别…") }
          .themedFont(.caption).foregroundStyle(.secondary)
      case .completed:
        HStack {
          Label("识别完成", systemImage: "checkmark.circle.fill").foregroundStyle(theme.success)
          Spacer()
          Button("复制文字") {
            CopyFeedbackController.shared.copy(recognizedText)
          }
          .controlSize(.small)
        }
        .themedFont(.caption)
      case .cancelled:
        Text(LocalImageTextRecognitionError.cancelled.userMessage)
          .themedFont(.caption).foregroundStyle(.secondary)
      case let .failed(message):
        Text(message).themedFont(.caption).foregroundStyle(theme.danger)
      }
      if !recognizedText.isEmpty {
        ScrollView {
          Text(recognizedText)
            // 用完整的阅读字体（含字体族），不能只继承字号丢掉家族。
            .font(readingFont.body())
            .lineSpacing(MarkdownPresentation.bodyLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .accessibilityIdentifier("history-image-ocr-text")
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
  }

  private func settingsModelButton(_ modelName: String) -> some View {
    Button(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未选择模型" : modelName) {
      openSettings()
    }
    .buttonStyle(.link)
    .themedFont(.caption)
    .help("打开模型设置")
  }

  private var regeneratePopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("重新生成").themedFont(.headline)
      Text("直接使用本机保存的正文，不会重新抓取网页。可只为本次运行临时换模型。")
        .themedFont(.caption).foregroundStyle(.secondary)
      // 从已添加的模型里选，不让人手打——模型名拼错不会当场报错，
      // 只会在真正调用时失败，而失败信息未必说得清是名字错了。
      Picker("临时模型", selection: $temporaryModel) {
        Text("使用当前模型").tag("")
        let options = providerSettings.summaryEntryDisplays
        if !options.isEmpty {
          Divider()
          ForEach(options) { option in
            Text("\(option.modelName)（\(option.title)）").tag(option.modelName)
          }
        }
      }
      .labelsHidden()
      .accessibilityIdentifier("regenerate-temporary-model")
      HStack {
        Button("总结") {
          let override = temporaryModel.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
          isRegeneratePopoverPresented = false
          Task {
            await appModel.summarize(
              historyDetail: detail,
              preferences: providerSettings.runPreferences,
              modelOverride: override
            )
          }
        }
        .disabled(summarizeUnavailableReason != nil)
        Button("翻译") {
          let override = temporaryModel.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
          isRegeneratePopoverPresented = false
          Task {
            await appModel.translate(
              historyDetail: detail,
              preferences: providerSettings.runPreferences,
              modelOverride: override
            )
          }
        }
        .disabled(translateUnavailableReason != nil)
      }
      if let reason = summarizeUnavailableReason ?? translateUnavailableReason {
        Text(reason)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("regenerate-blocked-reason")
      }
    }
    .padding(16)
    .frame(width: 340)
  }

  private func captureWasTruncated(_ completeness: String) -> Bool {
    ["visible_only", "selection_only"].contains(completeness.lowercased())
  }

  private func openSourceURL() {
    guard let url = URL(string: sourceURL) else { return }
    let policy = PublicWebURLPolicy(resolver: { _ in [] })
    guard (try? policy.validateSyntax(url)) != nil else { return }
    NSWorkspace.shared.open(url)
  }
}

/// 点在源码编辑器外面就结束编辑。
///
/// SwiftUI 的脑图、工具栏、侧栏大多不会成为第一响应者，NSTextView 的
/// textDidEndEditing 因此不会来。这里听窗口级 mouseDown，点到编辑器
/// 自己的 NSScrollView 之外就收工。
@MainActor
final class SourceEditClickOutsideMonitor {
  var suppressUntil: Date?
  var onClickOutside: (() -> Void)?
  private var monitor: Any?

  func start() {
    stop()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  func stop() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
  }

  private func handle(_ event: NSEvent) {
    if let until = suppressUntil, Date() < until { return }
    guard let window = event.window else { return }
    guard let hit = window.contentView?.hitTest(event.locationInWindow) else {
      onClickOutside?()
      return
    }
    if Self.hitIsInsideSourceEditor(hit, window: window) { return }
    onClickOutside?()
  }

  private static func hitIsInsideSourceEditor(_ hit: NSView, window: NSWindow) -> Bool {
    guard let text = window.firstResponder as? NSTextView else {
      // 编辑器还在抢焦点的那几十毫秒，当成点在里面，避免打开用的那次点击把编辑关掉。
      return true
    }
    let editor: NSView = text.enclosingScrollView ?? text
    return hit === editor || hit.isDescendant(of: editor)
  }
}

private struct TitleHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct HistoryTagEditor: View {
  let tags: [HistoryTag]
  @ObservedObject var model: HistoryViewModel
  /// 从工具栏快捷入口打开时直接展开输入框，点开即可打字；内联在详情里时保持收起。
  var autoExpandComposer = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var input = ""
  @State private var isComposerExpanded = false

  private var canAdd: Bool {
    model.canEditTags
      && tags.count < HistoryTagNormalizer.maximumTagsPerTask
      && HistoryTagNormalizer.normalized(input) != nil
  }

  private var canOpenComposer: Bool {
    model.canEditTags && tags.count < HistoryTagNormalizer.maximumTagsPerTask
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Chips-first: tags sit on the metadata density row, not a heavy form.
      if !tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(tags) { tag in
              HStack(spacing: 4) {
                Text(tag.name).lineLimit(1)
                if model.canEditTags {
                  Button { model.removeTag(tag) } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("移除标签 \(tag.name)")
                }
              }
              .themedFont(.caption)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
            }
            if canOpenComposer {
              addTagControl
            }
          }
        }
        .accessibilityIdentifier("history-tag-chips")
      } else if model.canEditTags {
        // Minimal empty state — no long grey instructional line.
        HStack(spacing: 6) {
          if canOpenComposer {
            addTagControl
          }
        }
        .accessibilityIdentifier("history-tag-empty-hint")
      }

      if isComposerExpanded && model.canEditTags {
        HStack(spacing: 8) {
          TextField("标签名", text: $input)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            .onSubmit(add)
            .accessibilityIdentifier("history-tag-input")
          Button("添加", action: add)
            .disabled(!canAdd)
            .accessibilityIdentifier("history-tag-add")
          Button("取消") {
            isComposerExpanded = false
            input = ""
          }
          .buttonStyle(.borderless)
        }
        let suggestions = model.suggestedTags(matching: input, excluding: tags)
        if !suggestions.isEmpty {
          HStack(spacing: 6) {
            ForEach(suggestions.prefix(5)) { tag in
              Button(tag.name) {
                input = tag.name
                add()
              }
              .buttonStyle(.link)
              .themedFont(.caption)
              .accessibilityIdentifier("history-tag-suggestion-\(tag.normalizedName)")
            }
          }
          .accessibilityIdentifier("history-tag-suggestions")
        }
      }

      if model.tagErrorCode != nil {
        Text("无法更新标签；历史记录未发生更改。")
          .themedFont(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("history-tag-error")
      }
    }
    .accessibilityIdentifier("history-tag-editor")
    .onAppear {
      if autoExpandComposer && canOpenComposer { isComposerExpanded = true }
    }
  }

  @ViewBuilder private var addTagControl: some View {
    Button {
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        isComposerExpanded.toggle()
        if !isComposerExpanded { input = "" }
      }
    } label: {
      Label(isComposerExpanded ? "收起" : "添加标签", systemImage: isComposerExpanded ? "xmark" : "plus")
        .themedFont(.caption)
        .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("history-tag-add-toggle")
  }

  private func add() {
    guard canAdd else { return }
    model.addTag(input)
    input = ""
    isComposerExpanded = false
  }
}

private struct DataDestinationDisclosureView: View {
  let disclosure: DataDestinationDisclosure
  let isConfirming: Bool
  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("发送前确认")
        .themedFont(.headline)

      // 这一屏只回答一个问题：正文发给谁。答案就是「服务 + 模型」，其余都不是
      // 决定依据——Base URL 是 host 的展开写法，接口名是实现细节，两者收进默认
      // 收起的详情；原来那两条脚注（API Key 在 Keychain、历史只在本机）讲的是
      // 产品的常态边界，和「这一次要不要发」无关，属于文档而不是拦路弹窗。
      destinationSentence
        .themedFont(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("data-destination-summary")

      DisclosureGroup("详情") {
        VStack(alignment: .leading, spacing: 8) {
          LabeledContent("Base URL") {
            Text(disclosure.identity.normalizedBaseURL)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          LabeledContent("接口", value: "OpenAI-compatible Chat Completions")
        }
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
      }
      .themedFont(.callout)

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
    .padding(20)
    .frame(width: 420)
    .accessibilityIdentifier("data-destination-disclosure")
  }

  /// 服务和模型加粗：这两个词是全部的决定依据，其余是把它们连成一句话的连接词。
  private var destinationSentence: Text {
    let verb = disclosure.intent == .translate ? "翻译" : "总结"
    // 本机端点必须如实标出——`http://127.0.0.1` 发出去的正文没有离开这台机器，
    // 和发往第三方服务是两件事，不标会让人以为一样。
    let suffix = disclosure.identity.isLocalEndpoint ? Text("（本机端点）").foregroundStyle(.secondary) : Text("")
    return Text("\(verb)正文将发送到 ")
      + Text(disclosure.identity.host).bold()
      + Text(" 的 ")
      + Text(disclosure.identity.model).bold()
      + suffix
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

private struct MetadataItem: View {
  let symbol: String; let title: String; let value: String; let detail: String?
  init(symbol: String, title: String, value: String, detail: String? = nil) {
    self.symbol = symbol; self.title = title; self.value = value; self.detail = detail
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: symbol).frame(width: 14)
        Text(title)
        // 等宽数字：这一行里全是会变的量（Token 累计、时间、视频时长）。
        // 比例字体下 1 比 0 窄一截，流式产出时数字每跳一次整行就左右晃，
        // 读起来像界面在抖。等宽让位数变化只往右长，不推挤前面的字。
        Text(value)
          .foregroundStyle(.primary)
          .monospacedDigit()
          .lineLimit(2)
          .truncationMode(.middle)
      }
      if let detail {
        Text(detail).themedFont(.caption, monospacedDigit: true).padding(.leading, 19)
      }
    }
    .themedFont(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
private func historyDate(_ milliseconds: Int64?) -> String { HistoryTimestampFormatter.text(milliseconds) }
private func historyPublishedDate(_ value: String?) -> String { HistoryPublishedTimestampFormatter.text(value) }
/// 列表行的时间：近的说"多久以前"，远的说日期。
///
/// 列表行原本占两排——"发布 2026年8月5日 14:37" 和 "创建 2026年8月5日"，
/// 加起来吃掉近一半行高，而它们是整行最次要的信息。合成一排的前提是
/// 把精度降下来：扫列表时"3 天前"就够判断新鲜度了，具体到分钟只有
/// 打开详情才有意义（详情页仍显示完整时间）。
///
/// 七天是分界：一周内人对"几天前"有直觉，超过一周就只剩"很久以前"，
/// 那时候日期反而更有用。
private let historyDayOnlyFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "zh_CN")
  formatter.dateStyle = .medium
  formatter.timeStyle = .none
  return formatter
}()
private func historyUpdatedDate(_ milliseconds: Int64) -> String {
  historyDayOnlyFormatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
}
/// 列表行的创建时间：与更新时间同一套 zh_CN 日期样式。
private func historyCreatedDate(_ milliseconds: Int64) -> String { historyUpdatedDate(milliseconds) }
private func historyAction(_ kind: RunKind?) -> String { kind == .translate ? "翻译" : kind == .summarize ? "总结" : "—" }
private func historyStatus(_ status: RunStatus) -> String { switch status { case .queued: "等待中"; case .running: "处理中"; case .completed: "已完成"; case .stopped: "已停止"; case .failed: "未完成"; case .interrupted: "已中断" } }
private func historyTokenBreakdown(_ usage: RunUsageCost?) -> String? {
  guard let usage, usage.inputTokens != nil || usage.outputTokens != nil else { return nil }
  return "输入 \(usage.inputTokens.map(String.init) ?? "—") / 输出 \(usage.outputTokens.map(String.init) ?? "—")"
}

/// Menu-command handle for focusing the sidebar search field (⌘F). Always
/// compares equal so re-rendering does not churn the focused-value registry.
struct FocusHistorySearchAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct FocusHistorySearchKey: FocusedValueKey { typealias Value = FocusHistorySearchAction }

extension FocusedValues {
  var focusHistorySearch: FocusHistorySearchAction? {
    get { self[FocusHistorySearchKey.self] }
    set { self[FocusHistorySearchKey.self] = newValue }
  }
}

/// 菜单命令句柄：新建笔记（⌘⇧N）。与搜索那个同构——总是相等，避免重渲染时
/// 反复churn 焦点值注册表。
struct NewNoteAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct NewNoteKey: FocusedValueKey { typealias Value = NewNoteAction }

/// 菜单命令句柄：打开今天的笔记（⌘⇧T）。
struct TodayNoteAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct TodayNoteKey: FocusedValueKey { typealias Value = TodayNoteAction }

extension FocusedValues {
  var newNote: NewNoteAction? {
    get { self[NewNoteKey.self] }
    set { self[NewNoteKey.self] = newValue }
  }
  var todayNote: TodayNoteAction? {
    get { self[TodayNoteKey.self] }
    set { self[TodayNoteKey.self] = newValue }
  }
}

func historyUIAnimation(reduceMotion: Bool) -> Animation {
  // 保留这个函数名——三十多处调用点在用它，而且它的语义（"历史界面的
  // 默认过渡"）比 token 名更贴调用现场。只把取值交给 token，免得同一条
  // 曲线在两个地方各写一份然后慢慢漂开。
  DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)
}

/// Banner enter/exit slides from its top anchor; Reduce Motion falls back to a
/// plain cross-fade instead of positional movement.
func historyBannerTransition(reduceMotion: Bool) -> AnyTransition {
  reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
}

private struct PointingHandOnHover: ViewModifier {
  func body(content: Content) -> some View {
    content.onHover { inside in
      (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
  }
}

/// 生成中总结/翻译的叶子视图：观察 `LiveRunTextModel`，流式增长拍点只
/// 重绘这里（见 HistoryDetailView.liveRunReadingBody）。
private struct LiveRunReadingBody: View {
  @ObservedObject var live: LiveRunTextModel
  let statusText: String
  let isActive: Bool
  let hasFailure: Bool
  let dangerColor: Color
  let font: NSFont
  let color: NSColor
  let lineSpacing: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if live.text.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if isActive {
            ProgressView().controlSize(.small)
          }
          Text(statusText)
            .themedFont(.body)
            .foregroundStyle(hasFailure ? dangerColor : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
      } else {
        if hasFailure || !isActive {
          Text(statusText)
            .themedFont(.callout)
            .foregroundStyle(hasFailure ? dangerColor : Color.secondary)
        }
        // 外层详情已经是 ScrollView。这里只长正文，不再套一层限高预览框。
        // 流式阶段不渲染 Markdown：逐 token 重排太贵；完成后换成富文本。
        StreamingReadingTextView(
          text: live.text,
          font: font,
          color: color,
          lineSpacing: lineSpacing
        )
          .frame(minHeight: StreamingViewport.minHeight, maxHeight: .infinity)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("model-run-output")
  }
}

/// 转写进行中的叶子视图：观察 `LiveRunTextModel`，partial 增长拍点只
/// 重绘这里，其余详情内容不受影响。
private struct LiveTranscriptionReadingBody: View {
  @ObservedObject var live: LiveRunTextModel
  let font: NSFont
  let color: NSColor
  let lineSpacing: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if live.text.isEmpty {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("正在准备转写内容…").foregroundStyle(.secondary)
        }
      } else {
        StreamingReadingTextView(
          text: live.text,
          font: font,
          color: color,
          lineSpacing: lineSpacing
        )
        .frame(minHeight: StreamingViewport.minHeight, maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-reading-source-live-transcription")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 阅读进度标签的叶子视图：观察 ReadingProgressModel，滚动事件只重绘
/// 这一小块（见 ReadingProgressModel 的注释）。
private struct ReadingProgressBadge: View {
  @ObservedObject var progress: ReadingProgressModel

  var body: some View {
    Label("阅读 \(progress.percent)%", systemImage: "book.pages")
      .themedFont(.caption)
      .foregroundStyle(.tertiary)
      .monospacedDigit()
      .accessibilityIdentifier("history-reading-progress")
  }
}

extension View {
  /// Desktop pointer affordance for link-styled buttons.
  func linkCursor() -> some View { modifier(PointingHandOnHover()) }
}
