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
          .alert("需要下载 Apple 中文离线模型", isPresented: $model.isTranscriptionModelConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelModelDownloadConfirmation() }
            Button("下载并转写") { model.confirmModelDownloadAndTranscribe() }
          } message: {
            Text("Apple 中文离线模型可能需要下载并占用本机空间。模型准备完成后，视频音频只在这台 Mac 上处理，不会上传。")
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
            Text("App 只发送转写文字本身，用于修正标点、分段和明显错别字，不发送视频、音频或链接。校对稿保存为最新原文，原始转写稿保留在历史中。")
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
            .font(.callout.weight(.medium))
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

        // 写笔记是一等动作，不是「添加链接」的附属项，所以独立成钮。
        // 它打开一个独立窗口而不是往列表塞一条记录——写东西和找资料是两种心智。
        Button(action: createNote) {
          Label("新建笔记", systemImage: "square.and.pencil")
        }
        .disabled(!manualLink.canOpen)
        .help("新建笔记")
        .accessibilityLabel("新建笔记")
        .accessibilityIdentifier("create-user-note")
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
          .font(.caption.weight(.semibold))
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
            message: "从浏览器扩展保存第一条链接后，会显示在这里。"
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
              Text("抓取队列").font(.caption).foregroundStyle(.secondary)
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
        Section("平台") {
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
        Section("标签") {
          Text("总结后自动生成，也可在详情中手动添加")
            .font(.caption)
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
                      .font(.caption2.monospacedDigit())
                      .foregroundStyle(selected ? theme.selectionText.opacity(0.8) : .secondary)
                  }
                  .font(.caption)
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
        Label(title, systemImage: systemImage)
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
      .font(.caption.weight(.medium).monospacedDigit())
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
        .font(.title3.weight(.medium))
      Text(model.pieces.isEmpty
        ? "一个念头写下来就是一件创作。"
        : "打开后能看到它攒了哪些素材、稿子写到哪了。")
        .font(.callout)
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
        .font(.headline)
      Text("一句话就够，之后可以随时改。")
        .font(.caption)
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
        Text("已选择 \(model.selectedTaskCount) 项").font(.title2.weight(.semibold))
        Text("可从工具栏、右键菜单或 Delete 键批量删除；导出、标签、识别和转写等单条能力暂不可用。")
          .font(.body)
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
      VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.title2); Text("无法载入这条记录").font(.headline); Button("重试", action: model.retryDetail) }
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
      Text("还没有笔记").font(.title2.weight(.semibold))
        .padding(.bottom, 6)
      Text("随手记下想法、灵感或读后感。笔记和抓取的内容一样可以打标签、搜索和导出。")
        .font(.callout)
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
      Text(isCaptureOnboardingDismissed ? "还没有保存页面" : "也可以直接添加公开链接")
        .font(.title2.weight(.semibold))
        .padding(.bottom, 6)
      Text("粘贴公开网页链接，或从 \(ProductDisplay.extensionName) 接收已打开的页面后，可在这里总结或翻译。")
        .font(.callout)
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
    hasInstalledBrowserSupport
      && providerSettings.hasConfiguredAPIKey
      && model.rows.contains { $0.hasSummary == true }
  }

  private var hasInstalledBrowserSupport: Bool {
    browserSupport.statuses.contains { $0.state == .installed || $0.state == .installedAppUpdated }
  }

  private var firstCaptureCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("三步开始使用汲作").font(.headline)
          Text("完成第一条总结后，这张卡会永久消失。")
            .font(.caption).foregroundStyle(.secondary)
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
        title: "安装浏览器支持",
        completed: hasInstalledBrowserSupport,
        actionTitle: "去安装"
      ) {
        SettingsNavigationRequest.request("browserSupport")
        openSettings()
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
        title: "保存并总结第一条内容",
        completed: model.rows.contains { $0.hasSummary == true },
        actionTitle: "打开浏览器扩展"
      ) {
        SettingsNavigationRequest.request("browserSupport")
        openSettings()
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
        Text("完成首次设置").font(.callout.weight(.semibold))
        Text(firstCaptureNextStepMessage).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button(firstCaptureNextStepActionTitle) {
        if !hasInstalledBrowserSupport {
          SettingsNavigationRequest.request("browserSupport")
          openSettings()
        } else if !providerSettings.hasConfiguredAPIKey {
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
    if !hasInstalledBrowserSupport { return "先安装浏览器支持，之后可从当前页面直接保存。" }
    if !providerSettings.hasConfiguredAPIKey { return "还差一步：配置模型后即可总结当前内容。" }
    return "保存已完成，生成第一份总结后引导会自动消失。"
  }

  private var firstCaptureNextStepActionTitle: String {
    if !hasInstalledBrowserSupport { return "安装支持" }
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
      Text(title).font(.callout.weight(.medium))
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

private struct HistoryInlineState: View {
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
      Text(title).font(.headline)
      Text(message)
        .font(.callout)
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

private struct ClipboardSuggestionBanner: View {
  let suggestion: ClipboardLinkSuggestion
  let capture: () -> Void
  let ignore: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("检测到剪贴板链接：\(suggestion.host)")
        .font(.callout.weight(.semibold))
      Text(suggestion.displayURL)
        .font(.caption)
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

private struct ManualLinkSheet: View {
  // 错误色走主题，理由同其它视图：写死 .red 在低对比与高对比主题上都不成立。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: ManualLinkViewModel
  let modelCallDisclosure: AutomaticModelCallDisclosure
  @FocusState private var focusURL: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加网页链接").font(.title3.weight(.semibold))
      Text("只读取你主动提交的公开 HTML 页面；登录页面请使用 \(ProductDisplay.extensionName)。")
        .font(.callout).foregroundStyle(.secondary)
      TextField("https://example.com/article", text: $model.input)
        .textFieldStyle(.roundedBorder).focused($focusURL)
        .disabled(model.isBusy).accessibilityIdentifier("manual-link-url-input")
      if let validation = model.inputValidationMessage {
        Label(validation, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(appTheme.danger)
          .accessibilityIdentifier("manual-link-validation")
      }
      if let disclosure = modelCallDisclosure.message {
        Text(disclosure)
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("manual-link-model-call-hint")
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(appTheme.danger).accessibilityIdentifier("manual-link-error")
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
private struct PendingCaptureRow: View {
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
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        switch pending.phase {
        case .queued: Text("排队中").font(.caption2).foregroundStyle(.tertiary)
        case .fetching: Text("正在抓取…").font(.caption2).foregroundStyle(.tertiary)
        case .saving: Text("正在保存…").font(.caption2).foregroundStyle(.tertiary)
        case let .failed(message):
          // 失败原因必须完整可读。`lineLimit(2)` 会把「网页暂时无法打开，
          // 请检查链接后重试」截掉尾巴——而尾巴恰恰是那句可执行的建议。
          Text(message)
            .font(.caption2)
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

private struct HistoryRowView: View {
  // 只收值输入，不再整体观察 ViewModel：以前每行都挂着 @ObservedObject，
  // 任何无关的 @Published 变化（转写流式输出、图标到货、导航计数……）
  // 都会让列表逐行整体重算。现在行体只在自己的输入变化时才重算（见文件
  // 下方的 Equatable 扩展），选中/图标由父层算好传进来。
  let row: HistoryRowProjection
  let isSelected: Bool
  let faviconURL: URL?
  let theme: HistoryThemeTokens
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 图24 式状态点：已有总结产物为绿色，未总结为橙色。
  private var isSummarized: Bool {
    row.artifactPreview?.trimmedNonEmpty != nil
  }

  /// 高对比主题改用形状编码：实心 = 已总结，空心 = 未总结。
  /// 尺寸和其它主题保持一致，换主题时行内文字不会跟着挪位。
  @ViewBuilder private var statusIndicator: some View {
    if theme.encodesStatusByShape {
      if isSummarized {
        Circle().fill(theme.primaryText)
      } else {
        Circle().strokeBorder(theme.primaryText, lineWidth: 1.5)
      }
    } else {
      Circle().fill(isSummarized ? theme.success : theme.warning)
    }
  }

  /// 这一行显示哪个时间。
  ///
  /// 发布时间优先——判断"这条素材新不新鲜"看的是它。抓不到发布时间
  /// （很多网页没有可靠的时间标记）才回落到入库时间，并标明是"存于"，
  /// 免得让人误以为原文是那天发的。
  private var rowTimeText: String {
    if let published = row.published?.trimmedNonEmpty {
      return historyPublishedDate(published)
    }
    return "存于 \(HistoryRelativeTime.text(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))"
  }

  /// 整行作为一个可访问元素，读屏只报标题、来源、时间和处理状态；正文预览
  /// 留在视觉层，不再把几百字摘要当作列表项 value 一口气念完。
  private var rowAccessibilityLabel: String {
    CapturedDocumentTitle.display(row.title, for: row.canonicalURL)
  }

  private var rowAccessibilityValue: String {
    var values = [
      "来源：\(HistoryPlatformDisplay.name(forHost: row.host))",
      rowTimeText,
      isSummarized ? "已总结" : "未总结",
    ]
    if row.hasTranscript == true {
      values.append("已转写")
    } else if row.hasMedia == true {
      values.append("有视频，还没转写")
    }
    if row.hasMindMap == true { values.append("已生成脑图") }
    return values.joined(separator: "，")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // 左侧锚点：状态点 + 平台标记竖排。
      //
      // 平台标记从标题右侧挪过来。放在右边有两个问题：位置和「关闭按钮」
      // 撞车，语义容易误解；而且列表纯文字堆叠时扫视没有落点——眼睛需要
      // 一个每行都在同一位置、且颜色各不相同的东西来定位。
      //
      // 没有用缩略图：36 条里只有 22 条正文带图（61%），而且那些图是远程
      // URL——列表里加载等于每次开 App 就朝各平台发几十个请求，既违背
      // local-first，也把「我在看这条」暴露给了内容平台。平台色块零网络、
      // 100% 覆盖，扫视效果反而更稳定。
      VStack(spacing: 6) {
        statusIndicator
          .frame(width: 7, height: 7)
          .help(isSummarized ? "已总结" : "未总结")
          // label 说「这是什么」，value 说「现在是什么值」。
          // 把状态塞进 label（原来的写法）时，VoiceOver 只念一句「已总结」，
          // 听不出这是一个状态指示器；分开之后念的是「总结状态，已总结」。
          .accessibilityLabel("总结状态")
          .accessibilityValue(isSummarized ? "已总结" : "未总结")
        favicon
      }
      .padding(.top, 4)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 8) {
          Text(CapturedDocumentTitle.display(row.title, for: row.canonicalURL))
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 4)
        }
        if let preview = row.artifactPreview?.trimmedNonEmpty ?? row.author?.trimmedNonEmpty {
          Text(preview)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        // 时间合成一排。
        //
        // 原本是两排——"发布 2026年8月5日 14:37" 和 "创建 2026年8月5日"，
        // 吃掉近一半行高，而这是整行最次要的信息。而且"创建"时间对用户
        // 几乎没有意义（他知道自己什么时候存的），判断素材新不新鲜看的是
        // 发布时间。所以只留发布时间，没抓到才回落到入库时间。
        HStack(alignment: .bottom, spacing: 6) {
          Text(rowTimeText)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          Spacer(minLength: 4)
          // 处理状态徽标：一眼分清生料和成品，自动管线跑完什么立刻可见。
          // 这一排是裸 Image，不是 Label——`.help()` 只喂给鼠标悬停的 tooltip，
          // VoiceOver 读不到，所以每个都要自己声明可访问名称。工具栏那些按钮
          // 用的是 `Label(文字, systemImage:)`，文字本身就是名称，不用补。
          HStack(spacing: 4) {
            if row.hasTranscript == true {
              Image(systemName: "waveform")
                .help("已转写")
                .accessibilityLabel("已转写")
            } else if row.hasMedia == true {
              // 只标异常，不标常态：有视频却还没转写的条目，正文往往只有一百来字的
              // 站点描述，在列表里和几千字的长文长得一模一样，点进去才发现是空的。
              // 不判「字数少」这类阈值——「有视频且无转写稿」是可判定的事实。
              Image(systemName: "waveform.slash")
                .foregroundStyle(theme.warning)
                .help("有视频，还没转写")
                .accessibilityLabel("有视频，还没转写")
                .accessibilityIdentifier("history-row-needs-transcript")
            }
            if row.hasSummary == true {
              Image(systemName: "text.alignleft")
                .help("已总结")
                .accessibilityLabel("已总结")
            }
            if row.hasMindMap == true {
              Image(systemName: "brain")
                .help("已生成脑图")
                .accessibilityLabel("已生成脑图")
            }
          }
          .font(.system(size: BadgeTypography.size))
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("history-row-status-badges")
        }
      }
    }
    .padding(.horizontal, DesignTokens.Space.md)
    .padding(.vertical, DesignTokens.Space.sm)
    .frame(minHeight: 68, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(rowBackground)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(theme.accent)
          .frame(width: 3, height: 30)
          .padding(.leading, DesignTokens.Space.xxs)
      }
    }
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
    // 新到行在 macOS List 里可能沿用估算行高并把内容压扁；
    // 固定纵向 intrinsic 高度 + 内容变化换 identity，强制按真实内容测量。
    .fixedSize(horizontal: false, vertical: true)
    .id("\(row.taskID.rawValue)-\(row.updatedAtMilliseconds)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityValue(rowAccessibilityValue)
  }

  private var rowBackground: Color {
    if isSelected { return theme.accent.opacity(0.10) }
    if isHovering { return theme.primaryText.opacity(0.035) }
    return .clear
  }

  @ViewBuilder private var favicon: some View {
    if row.host == HistoryPlatformDisplay.noteHost {
      // 笔记没有站点图标可取。给它侧边栏同一个符号，一眼能和抓来的东西分开。
      Image(systemName: "square.and.pencil")
        .font(.system(size: DesignTokens.IconSize.inline, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 18, height: 18)
        .accessibilityLabel("笔记")
    } else if let image = PlatformIconCatalog.image(for: row.host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        .accessibilityLabel("\(row.host) 图标")
    } else if let url = faviconURL {
      HistoryFaviconDiskImage(url: url, host: row.host, taskID: row.taskID) {
        fallbackBadge
      }
    } else {
      fallbackBadge
    }
  }

  /// Deterministic initial mark. A source with neither a bundled icon nor a
  /// reachable favicon still gets a stable, identifiable badge.
  private var fallbackBadge: some View {
    Text(PlatformIconCatalog.fallbackInitial(for: row.host))
      .font(.system(size: BadgeTypography.size, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 16, height: 16)
      .background(PlatformIconCatalog.fallbackColor(for: row.host), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
      .padding(.top, 1)
      .accessibilityLabel("\(row.host) 图标")
  }
}

/// 行体只随自己的输入变化重算。theme 参与比较：主题切换时行必须换色，
/// 而行拿的是传值不是环境，比较里漏掉它会让旧配色滞留到下一次输入变化。
extension HistoryRowView: Equatable {
  // nonisolated：Equatable 是非隔离协议，比较的又都是传值的存储属性，
  // 不碰主线程状态；不标的话 Swift 6 视为跨隔离一致性拒绝编译。
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.isSelected == rhs.isSelected
      && lhs.faviconURL == rhs.faviconURL
      && lhs.theme == rhs.theme
  }
}

/// 磁盘上的站点图标：内存缓存命中就直接画；未命中先画占位徽标，文件读取
/// 放到后台，读完入缓存再切换。以前是在行 body 里同步读盘构造图像——
/// 列表滚动或整表重建时，几十行图标的磁盘读取全部压在主线程上。
private struct HistoryFaviconDiskImage<Fallback: View>: View {
  let url: URL
  let host: String
  let taskID: TaskID
  @ViewBuilder var fallback: () -> Fallback
  @State private var loaded: NSImage?

  var body: some View {
    if let image = HistoryFaviconImageMemoryCache.cachedImage(host: host, taskID: taskID, url: url) ?? loaded {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        .accessibilityHidden(true)
    } else {
      fallback()
        .task(id: url) {
          loaded = await HistoryFaviconImageMemoryCache.decodeImage(at: url, host: host, taskID: taskID)
        }
    }
  }
}

/// SwiftUI can recompute a row's body many times while selection, scrolling,
/// or favicon callbacks change. This process-local cache keeps disk image
/// decoding out of that hot path. `NSCache` is thread-safe and bounded, so it
/// remains safe when AppKit asks for a view from a different rendering thread.
///
/// body 里只允许查内存（`cachedImage`）；磁盘读取一律走 `decodeImage`——
/// 文件 I/O 在后台完成，只把字节变成 NSImage 这一步留在主线程（小图标
/// 的解码本身是微秒级，贵的是读盘）。
private enum HistoryFaviconImageMemoryCache {
  nonisolated(unsafe) private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    return cache
  }()

  private static func keys(url: URL, host: String, taskID: TaskID) -> (host: NSString, task: NSString) {
    (
      "host:\(PlatformIconCatalog.normalizedHost(host))" as NSString,
      "task:\(taskID.rawValue):\(url.absoluteString)" as NSString
    )
  }

  static func cachedImage(host: String, taskID: TaskID, url: URL) -> NSImage? {
    let keys = keys(url: url, host: host, taskID: taskID)
    return images.object(forKey: keys.task) ?? images.object(forKey: keys.host)
  }

  @MainActor
  static func decodeImage(at url: URL, host: String, taskID: TaskID) async -> NSImage? {
    if let cached = cachedImage(host: host, taskID: taskID, url: url) { return cached }
    let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
    guard let bytes, let decoded = NSImage(data: bytes) else { return nil }
    let keys = keys(url: url, host: host, taskID: taskID)
    images.setObject(decoded, forKey: keys.host)
    images.setObject(decoded, forKey: keys.task)
    return decoded
  }
}

/// The detail header needs a recognizable source, not a wire-format URL.
/// Opening and copying still use the untouched value; this is display-only.
enum HistorySourceLinkPresentation {
  static func text(_ rawURL: String) -> String {
    guard let components = URLComponents(string: rawURL),
          var host = components.host?.lowercased(),
          !host.isEmpty
    else { return rawURL }

    if host.hasPrefix("www.") {
      host.removeFirst(4)
    }

    let segments = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).removingPercentEncoding ?? String($0) }

    if (host == "x.com" || host == "twitter.com"),
       segments.count >= 3,
       segments[1].lowercased() == "status" {
      return "\(host) · @\(segments[0]) 的帖子"
    }

    if host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
       segments.count >= 2,
       segments[0].lowercased() == "video" {
      return "\(host) · 视频 \(shortened(segments[1], limit: 18))"
    }

    guard !segments.isEmpty else { return host }
    let path = segments.joined(separator: "/")
    return "\(host) · /\(shortened(path, limit: 32))"
  }

  private static func shortened(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return "\(value.prefix(limit))…"
  }
}

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
  private var latestSourceSnapshot: ContentSnapshot? {
    detail.snapshots.reversed().first { $0.sourceKind != CapturedDocument.Origin.localTranscription.rawValue }
  }
  private var latestTranscriptionSnapshot: ContentSnapshot? {
    detail.snapshots.reversed().first {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue && !$0.bodyText.isEmpty
    }
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
  private var sourceURL: String { detail.snapshots.last?.sourceURL ?? detail.task.canonicalURL }
  private var sourceURLDisplay: String { HistorySourceLinkPresentation.text(sourceURL) }
  /// Tolaria-style properties from capture frontmatter (author / published / description).
  private var sourceFrontmatter: MarkdownNoteFrontmatter {
    MarkdownNoteFrontmatter.parse(latestSourceSnapshot?.bodyText ?? "")
  }
  private var showsCurrentCapture: Bool { appModel.currentCapture?.taskID == detail.task.id }
  private var showsVisibleRun: Bool { appModel.showsVisibleRun(for: detail.task.id) }
  private var canRunHistory: Bool { appModel.canStartRun(from: detail) }
  private var showsRunControls: Bool { canRunHistory || showsCurrentCapture || showsVisibleRun }
  private var presentsArticleBeforeMedia: Bool {
    guard let latestSnapshot else { return false }
    // X 帖子的正文就是帖子本身，视频是它的附件——按原帖的顺序读才对：文字在上、
    // 视频在下。抖音那类视频帖正好相反（正文只是一句 caption），仍旧视频在前。
    if latestSnapshot.platform == "x" { return true }
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
            .font(.callout.weight(.medium))
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
              .font(.callout.weight(.medium))
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
        // 自己写的东西没有来源网页：显示 `linkdigest-*:<uuid>` 并配「打开/复制链接」
        // 只会让人困惑——那不是一个能打开的地址，也没有复制的意义。
        if !isOwnWriting {
        HStack(spacing: 10) {
          Text(sourceURLDisplay)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .textSelection(.enabled)
            .help(sourceURL)
            .accessibilityLabel("来源链接 \(sourceURL)")
          Button("打开") { openSourceURL() }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .linkCursor()
            .accessibilityIdentifier("history-source-url-open")
          Button("复制链接") { CopyFeedbackController.shared.copy(sourceURL) }
            .buttonStyle(.link)
            .font(.callout.weight(.medium))
            .linkCursor()
            .accessibilityIdentifier("history-source-url-copy")
        }
        .padding(.top, 8)
        }

        if sourceFrontmatter.hasProperties || (!isWeChatCapture && sourceFrontmatter.hasEngagementStats) {
          notePropertiesStrip(sourceFrontmatter)
            .padding(.top, 10)
        }

        // Keep run stats under the title (not after the body). Capture-only
        // items show creation time only — never a wall of empty dashes.
        metadata
          .padding(.top, 12)

        if showsRunControls {
          // 上面是「这条是什么」（标题、来源、作者、时间），这一排是「对它做什么」。
          // 原来两者只隔 14pt，按钮读起来像元数据的第五行。
          //
          // 用一条横线而不是给上半块描边：横线只说「这里换段」，描边会说「这是一个
          // 盒子」。详情列刚从四个色块收成两个，不该再添一个分块。
          Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
            .padding(.top, 16)
          actionToolbar
            .padding(.top, 14)
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
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
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
                .font(.caption)
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
                // 换档必须丢掉当前播放器：驻留的是旧清晰度那一份，留着会切不过去。
                remotePreviewPlayback.release()
                sessionMediaPlayback.invalidateAndRefresh(
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
      readingPane = defaultReadingPane
      // 保活集合不跨条目：上一条访问过哪些面板不该让这一条多付隐藏布局。
      visitedReadingPanes = []
      // 临时诊断：验证完整体撤除
      reportMountedReadingPaneCount()
      pendingSourceCitation = nil
      ReadingSelectionRouter.shared.formatter = { selected in
        ReadingCitationFormatter.format(selection: selected, title: title, sourceURL: sourceURL)
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
        hadMediaDescriptor: detail.hadMediaDescriptor,
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

        // 收藏／取消收藏当前条目。左栏「收藏」分类按此筛选。
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

        // 快速打标签：复用底部那个标签编辑器，省得滚到最下面。打开即展开输入框。
        if model.canEditTags {
          Button { isTagPopoverPresented = true } label: {
            Label("标签", systemImage: "tag")
          }
          .help("添加标签")
          .accessibilityIdentifier("reading-quick-tag")
          .popover(isPresented: $isTagPopoverPresented, arrowEdge: .bottom) {
            HistoryTagEditor(tags: detail.tags, model: model, autoExpandComposer: true)
              .padding(16)
              .frame(width: 320)
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
            .disabled(!canRunHistory || !providerSettings.arePreferencesReady)
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

  /// 「登录了为什么还是 720P」只能由这行回答：API 给了哪些档、我们最后选了哪条。
  /// 读代码查不出来，每一环读起来都是通的。
  ///
  /// 必须挂在**每一个**带清晰度菜单的播放卡片下面。之前只有「会话恢复」分支有，
  /// 当前抓取分支没有——于是手选高清后拿不到更高档时，那条分支只是重新加载一遍，
  /// 不给任何说明，表现就是「点了尽量高清没反应」。
  @ViewBuilder private var streamSelectionDiagnostic: some View {
    if let selection = sessionMediaPlayback.selectionDiagnostic {
      Text(selection)
        .font(.caption2)
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
    } else if titleNeedsScrolling {
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
  }

  private var measuredTitleText: some View {
    Text(title)
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
          .font(.callout.weight(.medium))
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
                .font(.callout)
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
      Text("正在整理…").font(.caption).foregroundStyle(.secondary)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
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
          title: "总结",
          systemImage: "text.alignleft",
          prominent: !isOwnWriting && summaryArtifact == nil,
          disabled: !providerSettings.arePreferencesReady || !(showsCurrentCapture ? appModel.canStartRun : appModel.canStartRun(from: detail)),
          identifier: showsCurrentCapture ? "summarize-current-capture" : "summarize-history-detail"
        ) {
          pendingRunPane = .summary
          readingPane = .summary
          Task {
            if showsCurrentCapture {
              await appModel.summarize(preferences: providerSettings.runPreferences)
            } else {
              await appModel.summarize(historyDetail: detail, preferences: providerSettings.runPreferences)
            }
          }
        }
        actionPill(
          title: "翻译",
          systemImage: "character.book.closed",
          prominent: !isOwnWriting && summaryArtifact != nil && translationArtifact == nil,
          disabled: !providerSettings.arePreferencesReady || !(
            showsCurrentCapture
              ? appModel.canTranslate(preferences: providerSettings.runPreferences)
              : appModel.canTranslate(from: detail, preferences: providerSettings.runPreferences)
          ),
          identifier: showsCurrentCapture ? "translate-current-capture" : "translate-history-detail"
        ) {
          pendingRunPane = .translation
          readingPane = .translation
          Task {
            if showsCurrentCapture {
              await appModel.translate(preferences: providerSettings.runPreferences)
            } else {
              await appModel.translate(historyDetail: detail, preferences: providerSettings.runPreferences)
            }
          }
        }
        // 生成脑图和总结、翻译是同一类动作：都是把正文交给模型换回一份新产物，
        // 前置条件（有正文 + 配好模型）、代价（花 token，必经确认）和结果
        // （一份可保存、可导出的东西）完全一致。原来它却单独待在媒体和正文之间，
        // 是一行很容易滚过去的小按钮——同类不同位。
        //
        // 已经有脑图就不显示：那时候「重新生成」在脑图卡自己的标题行里，
        // 挨着主题切换和导出，和它们是一组。
        if !isOwnWriting, model.mindMapRecord?.taskID != detail.task.id {
          actionPill(
            title: "生成脑图",
            systemImage: "brain",
            prominent: false,
            disabled: !model.canGenerateMindMap(taskID: detail.task.id),
            identifier: "mind-map-generate"
          ) {
            model.requestMindMapGeneration(taskID: detail.task.id)
          }
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(appModel.runHasFailure ? theme.danger : Color.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("model-run-status")
        }
      }

      HStack(spacing: DesignTokens.Space.sm) {
        if !providerSettings.arePreferencesReady {
          Button("设置模型") { openSettings() }
            .buttonStyle(.link)
            .font(.caption.weight(.medium))
            .accessibilityIdentifier("history-open-model-settings")
        } else {
          Label(
            providerSettings.activeSummaryModelName.isEmpty
              ? "模型未命名"
              : providerSettings.activeSummaryModelName,
            systemImage: "cpu"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        }
        Spacer(minLength: 0)
        if canRunHistory || showsCurrentCapture || isRunPanelExpanded {
          Button(isRunPanelExpanded ? "收起运行详情" : "运行详情") {
            withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isRunPanelExpanded.toggle() }
          }
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
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
    let button = Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    .controlSize(.small)
    .disabled(disabled)
    .accessibilityIdentifier(identifier)

    // 禁用时一律退回普通描边样式：`.borderedProminent` 的禁用态是一块
    // 去饱和的橙色死板——它既不像能点，也不像装饰，只像坏了。
    if prominent, !disabled {
      button
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
    } else {
      button.buttonStyle(.bordered)
    }
  }

  /// Optional hints only (model names / storage). Streaming body lives in the reading card.
  private var captureAndRunControlsExtras: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsCurrentCapture {
        currentCaptureExtras
      } else if canRunHistory {
        Text("使用本机已保存正文生成；结果作为新运行保存。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          settingsModelButton(providerSettings.activeSummaryModelName)
          settingsModelButton(providerSettings.effectiveTranslationModelName)
          Text("输出：\(providerSettings.runPreferences.outputLanguage)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      if showsVisibleRun, appModel.runHasFailure {
        Text(appModel.runStatusText)
          .font(.caption)
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
      .font(.caption)
      .foregroundStyle(appModel.storageAvailability.isWriteReady ? Color.secondary : theme.warning)
      .accessibilityIdentifier("storage-availability")
      if let notice = appModel.dataDestinationNotice {
        Label(notice, systemImage: "info.circle")
          .font(.caption)
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
    VStack(alignment: .leading, spacing: 10) {
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

  @ViewBuilder
  private var metadata: some View {
    if let run = newestRun {
      // Full run strip: only after summarize/translate has produced a Run.
      VStack(alignment: .leading, spacing: 6) {
        metadataRow {
          MetadataItem(symbol: "wand.and.stars", title: "操作", value: historyAction(run.run.kind))
          MetadataItem(symbol: "cpu", title: "模型", value: run.run.model?.trimmedNonEmpty ?? "—")
          MetadataItem(symbol: "calendar", title: "创建时间", value: historyDate(detail.task.createdAtMilliseconds))
        }
        metadataRow {
          // 全文总账：总结/翻译 Run + 整理/脑图台账的累计花费；
          // 各功能的单次用量在各自状态行单独显示。
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
      .font(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
      .accessibilityIdentifier("history-run-metadata")
    } else {
      // Capture-only: real creation time, no fake 操作/模型 dashes；
      // 但整理/脑图已产生花费时，Token 总账照样显示。
      metadataRow {
        MetadataItem(
          symbol: "calendar",
          title: "创建时间",
          value: historyDate(detail.task.createdAtMilliseconds)
        )
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
      .font(.caption)
      .foregroundStyle(.secondary)
      .opacity(0.95)
      .accessibilityIdentifier("history-capture-metadata")
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

  /// Lightweight properties strip (Tolaria/Obsidian frontmatter fields), not a full editor.
  @ViewBuilder
  private func notePropertiesStrip(_ note: MarkdownNoteFrontmatter) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let accountName = note.accountName {
        propertyRow(symbol: "building.2", title: "公众号", value: accountName)
      }
      if let author = note.author {
        propertyRow(symbol: "person", title: "作者", value: author)
      }
      if let published = note.published {
        // Raw frontmatter values are often ISO 8601 ("2026-07-21T19:47:07.000Z");
        // present them in the same localized style as the list rows.
        propertyRow(symbol: "calendar", title: "发布", value: historyPublishedDate(published))
      }
      // No cover thumbnail here. The article body already carries its images in
      // the author's own order, and a WeChat cover is usually either a repeat of
      // the first body image or a promotional card that was never part of the
      // reading flow — showing it above the text displaced the actual opening.
      // Do not show meta/og description: often promotional and not article-faithful.
      if !isWeChatCapture && note.hasEngagementStats {
        HStack(spacing: 16) {
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .accessibilityIdentifier("history-engagement-stats")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("history-note-properties")
  }

  private func propertyRow(symbol: String, title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).frame(width: 14)
      Text(title).frame(width: 36, alignment: .leading)
      Text(value)
        .foregroundStyle(theme.primaryText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
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
          .font(.caption.weight(.medium))
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
      // 临时诊断：验证完整体撤除
      reportMountedReadingPaneCount()
    }
    // 临时诊断：验证完整体撤除。初始挂载不走 onChange，这里补一次。
    .onAppear { reportMountedReadingPaneCount() }
  }

  /// 临时诊断：验证完整体撤除。
  /// 实际挂载数 = visitedReadingPanes ∪ {effectiveReadingPane}。
  private func reportMountedReadingPaneCount() {
    var mounted = visitedReadingPanes
    mounted.insert(effectiveReadingPane)
    ReadingLayoutProbe.setMountedPaneCount(mounted.count)
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
        // 旧版翻译把元数据块也翻了一遍，块卡在译文中段（前面是翻译后的标题），
        // 开头剥离对它无效。显示时按白名单再清一次；只清翻译——总结里出现
        // 同构块的可能性低，且误删的代价是丢正文。
        // 剥离与清理都是整篇扫描，走备忘缓存，正文没变不重付。
        // Summaries rarely carry images; still allow local map if present.
        MarkdownContentView(
          source: ReadingRenderCache.paneBody(
            source: artifact.bodyText,
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
      // 转写进行中时无条件走流式视图：重新转写要立即清掉旧文本并流式
      // 上屏，而不是等落库后整体替换（旧条件只在首次无 snapshot 时流式）。
      // 叶子视图观察 LiveRunTextModel：partial 拍点只重绘这一块。
      if isDouyinCapture, hasLiveTranscription {
        LiveTranscriptionReadingBody(
          live: model.liveTranscriptionText,
          font: readingFont.nsFont(),
          color: NSColor(theme.primaryText),
          lineSpacing: MarkdownPresentation.bodyLineSpacing
        )
      } else if let snapshot = (isDouyinCapture && !isDouyinImagePostCapture)
        ? latestTranscriptionSnapshot
        : latestSnapshot, !snapshot.bodyText.isEmpty {
        if captureWasTruncated(snapshot.completeness) {
          Label("捕获内容已截断，生成结果可能不完整。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .accessibilityIdentifier("capture-truncated-notice")
        }
        // 可写正文：本机转写、笔记、稿、作品。网页捕获保持只读。
        // 默认看排版，单击进源码；空笔记仍一打开就写。
        if canEditSource(snapshot), isEditingTranscription {
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(sourceDraftIsDirty(snapshot) ? "正在保存…" : (noteSaveIndicator ? "已保存" : ""))
              .font(.caption)
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
        if canEditSource(snapshot), isEditingTranscription {
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
            source: MarkdownNoteFrontmatter.parse(snapshot.bodyText).body,
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
            anchorScope: anchorScope(for: .source),
            revealText: pendingSourceCitation,
            onFollowWikiLink: { title in
              if let snapshot = latestSnapshot, sourceDraftIsDirty(snapshot) {
                saveTranscriptionDraft(snapshot, exiting: false)
              }
              model.followWikiLink(toTitle: title)
            },
            onRequestEdit: canEditSource(snapshot) && !model.isReadOnly
              ? { snippet in beginSourceEditing(snapshot, displayedSnippet: snippet) }
              : nil
          )
          .simultaneousGesture(
            TapGesture().onEnded {
              guard canEditSource(snapshot), !model.isReadOnly else { return }
              beginSourceEditing(snapshot, displayedSnippet: nil)
            }
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-reading-source")
        }
      } else {
        missingPaneNotice(for: .source)
      }
    }
  }

  private func canEditSource(_ snapshot: ContentSnapshot) -> Bool {
    snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
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
            .font(.callout)
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
            .font(.callout)
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
          Text("图片文字识别").font(.headline)
          Text("Apple Vision 本机处理，图片不会上传。")
            .font(.caption).foregroundStyle(.secondary)
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
          .font(.caption).foregroundStyle(.secondary)
      case .recognizing:
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在本机识别…") }
          .font(.caption).foregroundStyle(.secondary)
      case .completed:
        HStack {
          Label("识别完成", systemImage: "checkmark.circle.fill").foregroundStyle(theme.success)
          Spacer()
          Button("复制文字") {
            CopyFeedbackController.shared.copy(recognizedText)
          }
          .controlSize(.small)
        }
        .font(.caption)
      case .cancelled:
        Text(LocalImageTextRecognitionError.cancelled.userMessage)
          .font(.caption).foregroundStyle(.secondary)
      case let .failed(message):
        Text(message).font(.caption).foregroundStyle(theme.danger)
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
    .font(.caption)
    .help("打开模型设置")
  }

  private var regeneratePopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("重新生成").font(.headline)
      Text("直接使用本机保存的正文，不会重新抓取网页。可只为本次运行临时换模型。")
        .font(.caption).foregroundStyle(.secondary)
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
        .disabled(!appModel.canTranslate(from: detail, preferences: providerSettings.runPreferences))
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
              .font(.caption)
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
              .font(.caption)
              .accessibilityIdentifier("history-tag-suggestion-\(tag.normalizedName)")
            }
          }
          .accessibilityIdentifier("history-tag-suggestions")
        }
      }

      if model.tagErrorCode != nil {
        Text("无法更新标签；历史记录未发生更改。")
          .font(.caption).foregroundStyle(.secondary)
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
        .font(.caption)
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
        .font(.headline)

      // 这一屏只回答一个问题：正文发给谁。答案就是「服务 + 模型」，其余都不是
      // 决定依据——Base URL 是 host 的展开写法，接口名是实现细节，两者收进默认
      // 收起的详情；原来那两条脚注（API Key 在 Keychain、历史只在本机）讲的是
      // 产品的常态边界，和「这一次要不要发」无关，属于文档而不是拦路弹窗。
      destinationSentence
        .font(.body)
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
      }
      .font(.callout)

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

private struct ReadOnlyHistoryCallout: View {
  let reason: RepositoryRecoveryReason?
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock.fill")
        .foregroundStyle(theme.warning)
        .padding(.top, 1)
      Text(message)
        .font(.body)
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
        Text(detail).font(.caption.monospacedDigit()).padding(.leading, 19)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
// 列表行与播放卡片都在用；拆分后不能再是 file-private。
extension String {
  var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
  var emptyToNil: String? { trimmedNonEmpty }
}
enum HistoryTimestampFormatter {
  // DateFormatter 的创建是毫秒级开销，而这条路在列表行和详情页反复走。
  // 配好即只读（只调 string(from:)），只读用法下 DateFormatter 线程安全。
  // 两档样式各缓存一份；测试注入自定义历法/时区时仍走现建路径。
  private static let sameDayFormatter = makeDefault(dateStyle: .none)
  private static let otherDayFormatter = makeDefault(dateStyle: .medium)

  private static func makeDefault(dateStyle: DateFormatter.Style) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = dateStyle
    formatter.timeStyle = .short
    return formatter
  }

  static func text(
    _ milliseconds: Int64?,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    // 和 `HistoryPublishedTimestampFormatter` 同一个理由，这里之前漏了：
    // 界面通篇中文但 App 没有本地化资源，`.autoupdatingCurrent` 会回退成英文，
    // 于是详情页同一屏里出现「发布 2026年8月5日 14:37」和
    // 「创建时间 Aug 5, 2026 at 18:13」两种写法。钉住 zh_CN。
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    guard let milliseconds else { return "—" }
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    var localCalendar = calendar
    localCalendar.timeZone = timeZone
    let sameDay = localCalendar.isDate(date, inSameDayAs: now)
    if calendar == Calendar.autoupdatingCurrent,
       timeZone == TimeZone.autoupdatingCurrent,
       locale.identifier == "zh_CN" {
      return (sameDay ? sameDayFormatter : otherDayFormatter).string(from: date)
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = localCalendar
    formatter.timeZone = timeZone
    formatter.dateStyle = sameDay ? .none : .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}
private func historyDate(_ milliseconds: Int64?) -> String { HistoryTimestampFormatter.text(milliseconds) }
enum HistoryPublishedTimestampFormatter {
  // ISO8601 解析器与 zh_CN 展示格式化器都缓存：列表每一行都要走这里，
  // 原来一次调用现建 2~3 个 formatter。ISO8601DateFormatter 线程安全；
  // DateFormatter 只读用法（只调 string(from:)）同样安全。
  private nonisolated(unsafe) static let standardISO = ISO8601DateFormatter()
  private nonisolated(unsafe) static let fractionalISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter
  }()
  private static let defaultLocalized: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  static func text(
    _ value: String?,
    calendar: Calendar = .autoupdatingCurrent,
    // The app's entire UI is Simplified Chinese but ships unlocalized, so an
    // autoupdating locale falls back to English ("Jul 22, 2026 at 03:47").
    // Pin zh_CN so dates read like the rest of the interface.
    locale: Locale = Locale(identifier: "zh_CN"),
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    // 旧抓取可能存有抖音 DOM 的「· 」装饰前缀；展示层剥掉它兜底。
    let cleanedValue = value?
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "^[·•|｜,，\\s]+|[·•|｜,，\\s]+$", with: "", options: .regularExpression)
    guard let value = cleanedValue?.trimmedNonEmpty else { return "发布时间未获取" }
    guard let date = standardISO.date(from: value) ?? fractionalISO.date(from: value) else { return value }
    if calendar == Calendar.autoupdatingCurrent,
       timeZone == TimeZone.autoupdatingCurrent,
       locale.identifier == "zh_CN" {
      return defaultLocalized.string(from: date)
    }
    let localized = DateFormatter()
    localized.locale = locale
    localized.calendar = calendar
    localized.timeZone = timeZone
    localized.dateStyle = .medium
    localized.timeStyle = .short
    return localized.string(from: date)
  }
}
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
enum HistoryRelativeTime {
  // 列表滚动路径，formatter 缓存理由同 `HistoryTimestampFormatter`。
  private static let defaultTimeOfDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
  private static let defaultDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static func isDefault(_ locale: Locale, _ calendar: Calendar) -> Bool {
    locale.identifier == "zh_CN" && calendar == Calendar.autoupdatingCurrent
  }

  static func text(
    _ milliseconds: Int64,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = Locale(identifier: "zh_CN")
  ) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    // 按"日历天"算而不是按 24 小时：昨晚 23:00 和今早 08:00 差 9 小时，
    // 但人会说"昨天"，不会说"9 小时前"。
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                       to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case ..<0:
      // 未来时间通常是源站时区解析出的偏差，别显示"-2 天前"这种。
      return dayText(date, locale: locale, calendar: calendar)
    case 0:
      if isDefault(locale, calendar) { return "今天 \(defaultTimeOfDay.string(from: date))" }
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.dateFormat = "HH:mm"
      return "今天 \(formatter.string(from: date))"
    case 1: return "昨天"
    case 2...6: return "\(days) 天前"
    default: return dayText(date, locale: locale, calendar: calendar)
    }
  }

  private static func dayText(_ date: Date, locale: Locale, calendar: Calendar) -> String {
    if isDefault(locale, calendar) { return defaultDay.string(from: date) }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}

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

enum CapturedSourceBodyPresentation {
  static func isRedundantDouyinBody(
    platform: String?,
    title: String,
    markdown: String
  ) -> Bool {
    guard platform == "douyin" else { return false }
    let titleKey = canonicalText(title)
    var remainder = canonicalText(MarkdownNoteFrontmatter.parse(markdown).body)
    guard !titleKey.isEmpty, !remainder.isEmpty else { return false }
    while remainder.hasPrefix(titleKey) {
      remainder.removeFirst(titleKey.count)
    }
    return remainder.isEmpty
  }

  private static func canonicalText(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
  }
}

struct RemoteMediaDegradationPresentation: Equatable {
  let kindLabel: String
  let message: String
  let nextAction: String
}

enum CurrentCaptureMediaPreviewState: Equatable {
  case playable(url: URL, kind: MediaKind, companionAudioURL: URL?)
  case expired
  case degraded(RemoteMediaDegradationPresentation)
}

/// 远程预览准备阶段：双轨 `loadTracks` 可能要数秒拉 moov，期间必须有文案。
enum RemotePreviewPreparePhase: Equatable {
  case idle
  case preparing
  case ready
  case failed(RemotePreviewPlaybackFailure)
}

/// 可区分的远程播放失败：断网 vs 地址/播放器问题。
enum RemotePreviewPlaybackFailure: Equatable {
  case networkUnavailable
  case generic
  /// 长片仍带着 DASH 双轨地址：应改拉 progressive mp4，不要卡在合成。
  case longFormDualNeedsRefresh

  var message: String {
    switch self {
    case .networkUnavailable:
      return "网络似乎不可用，暂时无法读取视频流。"
    case .generic:
      return "高清流连接失败（可能是杜比视界/编码不兼容或地址失效）。请点「重新获取可播地址」拉取 AVPlayer 能播的最高清档。"
    case .longFormDualNeedsRefresh:
      return "长视频不适合双轨合成。请点「重新获取可播地址」拉取整段可播 MP4。"
    }
  }
}

/// 历史条目在「没有可播放 descriptor」时的展示决策。
/// descriptor / 签名 URL 只在当前抓取内存中有效，从不写入历史——这是设计，不是故障。
enum HistorySessionMediaPresentation {
  /// 是否应把这条历史当作「曾有会话媒体」。
  ///
  /// 优先用抓取事实，而不是平台白名单：
  /// - `hadMediaDescriptor`：来自 `capture_deliveries.capture_contract_version == 2`。
  ///   扩展侧只有存在 `MediaDescriptor` 时才发 V2（见 `captureEnvelopeForPage`），
  ///   因此覆盖 x / bilibili / xiaohongshu / github / generic 等所有会带媒体的抓取，
  ///   而不会把纯文字的 X 帖误判成视频。
  /// - `wechat` 在扩展 `attachDetectedMedia` 里被显式丢弃 media，不会进 V2，不受影响。
  /// - 抖音图文帖不带 mediaDescriptor，也不是 V2 视频路径；若正文仍命中图文启发式则排除。
  /// - `legacyPlatformHint` 仅兜底极老的 V1 抖音视频（无 V2 合同行）；新平台不要往这里加白名单。
  static func expectsSessionMedia(
    hadMediaDescriptor: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    if isDouyinImagePost { return false }
    if hadMediaDescriptor { return true }
    // Legacy V1 douyin video-only path (optional CaptureMedia, not MediaDescriptor).
    return legacyPlatformHint == "douyin"
  }

  /// 是否应显示「有视频但此处不可播」卡片，而不是整块消失。
  static func shouldShowSessionOnlyUnavailable(
    hadMediaDescriptor: Bool,
    hasLocalMediaFile: Bool,
    hasLocalMediaRow: Bool,
    hasLocalMediaResolutionFailure: Bool,
    isCurrentCaptureWithDescriptor: Bool,
    isYouTube: Bool,
    isDouyinImagePost: Bool = false,
    legacyPlatformHint: String? = nil
  ) -> Bool {
    guard !hasLocalMediaFile,
          !hasLocalMediaRow,
          !hasLocalMediaResolutionFailure,
          !isCurrentCaptureWithDescriptor,
          !isYouTube else { return false }
    return expectsSessionMedia(
      hadMediaDescriptor: hadMediaDescriptor,
      isDouyinImagePost: isDouyinImagePost,
      legacyPlatformHint: legacyPlatformHint
    )
  }

  static let title = "此记录包含视频"
  static let explanation =
    "临时播放地址只在抓取当次有效，从不写入历史。这是设计行为，不是故障；换到其它条目后，这里不能继续在线播放。"
  static let openSourceActionTitle = "回到原页面观看"
  static let refreshActionTitle = "重新获取播放"
}

/// 否则界面会永远停在转圈上。读取失败同理：给它一个明确出口，而不是无限等待。
enum PlaybackSurfaceGeometry: Equatable {
  case loading
  case video(CGSize)
  case audioOnly
  case unavailable

  var displaySize: CGSize? {
    if case let .video(size) = self { return size }
    return nil
  }
}

struct VideoDisplayGeometry {
  /// 内联播放器高度上限。竖屏视频按它算出的宽度约 292，横屏先撞阅读区宽度。
  static let inlineMaximumHeight: CGFloat = 520

  /// 由已读到的轨道信息判定播放面状态。抽成纯函数是为了能脱离 AVFoundation 资源
  /// 直接测：有画面就给尺寸，没画面但有声音就是纯音频，两者都没有才是读不出。
  static func surfaceGeometry(
    videoTrack: (naturalSize: CGSize, preferredTransform: CGAffineTransform)?,
    hasAudioTrack: Bool
  ) -> PlaybackSurfaceGeometry {
    if let videoTrack {
      let size = displaySize(
        naturalSize: videoTrack.naturalSize,
        preferredTransform: videoTrack.preferredTransform
      )
      if size.width > 0, size.height > 0 { return .video(size) }
    }
    return hasAudioTrack ? .audioOnly : .unavailable
  }

  /// 内联播放器的宽度上限：让黑底收到视频自身宽度，竖屏才不会挂着两条死黑边。
  /// 单给 `maxHeight` 不够——弹性 frame 会把整块可用宽度占满，比例只作用在内部。
  static func inlineMaximumWidth(displaySize: CGSize?) -> CGFloat {
    let ratio = displaySize.map(aspectRatio(displaySize:)) ?? (16.0 / 9.0)
    return inlineMaximumHeight * ratio
  }

  static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    return CGSize(width: abs(transformed.width), height: abs(transformed.height))
  }

  static func aspectRatio(displaySize: CGSize) -> CGFloat {
    guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
    return displaySize.width / displaySize.height
  }

  static func fittedSize(displaySize: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
    guard displaySize.width > 0, displaySize.height > 0, maxWidth > 0, maxHeight > 0 else { return .zero }
    let scale = min(maxWidth / displaySize.width, maxHeight / displaySize.height)
    return CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
  }
}


/// UI state changes use a critically damped spring; Reduce Motion keeps a
/// short non-spatial fade so state changes stay visible without movement.
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
            .font(.body)
            .foregroundStyle(hasFailure ? dangerColor : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
      } else {
        if hasFailure || !isActive {
          Text(statusText)
            .font(.callout)
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
      .font(.caption)
      .foregroundStyle(.tertiary)
      .monospacedDigit()
      .accessibilityIdentifier("history-reading-progress")
  }
}

extension View {
  /// Desktop pointer affordance for link-styled buttons.
  func linkCursor() -> some View { modifier(PointingHandOnHover()) }
}
