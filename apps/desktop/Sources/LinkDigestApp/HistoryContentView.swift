import AppKit
import AVKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import LinkDigestAdapters
import LinkDigestCore

struct HistoryContentView: View {
  @Bindable var model: HistoryViewModel
  var appModel: AppViewModel
  @ObservedObject var manualLink: ManualLinkViewModel
  var providerSettings: ProviderSettingsViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @EnvironmentObject private var localImport: LocalImportController
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  /// 「记一个新灵感」的输入框。
  @State private var isNewSparkPresented = false
  @State private var newSparkText = ""
  /// 「待转写 → 全部转写」确认前读出的全部条目；非 nil 时弹确认框。
  @State private var untranscribedBacklogToConfirm: [(taskID: TaskID, name: String)]?
  @State private var isLoadingUntranscribedBacklog = false
  @State private var douyinProfileImportRequest: DouyinProfileImportRequest?
  /// 有作品的博主删除前先确认；没作品的直接删。
  @State private var creatorPendingDeletion: CreatorSummary?
  @AppStorage(ProfileImportQueuePresentation.dismissedKey) private var dismissedImportNotices = ""
  /// 来源平台是否全部展开。默认只露出条数最多的 5 家。
  // v2（2026-09-25）：来源默认只露前 5 家。旧键里记着「全部展开」，换键让所有人回到默认折叠。
  @AppStorage("history.navigation.platforms-show-all.v2") private var navigationPlatformsShowsAll = false
  @State private var isReadingPlatformGalleryItem = false
  @State private var platformGalleryScrollTarget: TaskID?
  @State private var showsCreatorDirectoryCatalog = true
  @State private var creatorDirectoryScrollTarget: CreatorID?
  @State private var collapsedCreatorPlatforms: Set<String> = []
  @State private var creatorWorkSort: WorkSortOrder = .original
  /// 瀑布流里每张卡钉在哪一列（键：卡片 id）。换博主、换排序、列数变化时整体重算。
  @State private var creatorMasonryPins: [AnyHashable: Int] = [:]
  @State private var creatorMasonryPinsKey = ""
  @State private var creatorMasonryHeightBox = CreatorMasonryHeightBox()
  @State private var creatorMasonryMeasuredRevision = 0
  @State private var creatorSortReferenceDate = Date()
  @State private var creatorWorkScrollTarget: TaskID?
  // 2026-09-23 侧栏分层（对标应用）：顶部四个固定入口常驻，视图 / 博主 / 来源平台 / 标签
  // 这些次要分组默认收起，展开状态跨启动记住。折叠只影响显示，不改任何筛选状态。
  @AppStorage("history.navigation.views-expanded") private var navigationViewsExpanded = false
  // 「形式」2026-09-24 新加时默认展开；2026-10-01 走查：侧栏七组看同一批资料，一打开全摊开
  // 太多，改回和「标签」「来源」一样默认收起。用户展开过就按 AppStorage 记住的来。
  @AppStorage("history.navigation.forms-expanded") private var navigationFormsExpanded = false
  @AppStorage("history.navigation.creators-expanded") private var navigationCreatorsExpanded = false
  @AppStorage("history.navigation.platforms-expanded") private var navigationPlatformsExpanded = false
  @AppStorage("history.navigation.tags-expanded") private var navigationTagsExpanded = false
  /// 「视图」里「工序状态」那一组，默认收起（2026-10-04 侧栏去重）。
  @AppStorage("history.navigation.step-status-expanded") private var navigationStepStatusExpanded = false
  // 「合集」2026-09-29 新加，默认展开：新分组第一次出现时要让人看见（同「形式」）。
  @AppStorage("history.navigation.collections-expanded") private var navigationCollectionsExpanded = true
  @State private var didRevealInitialNavigationPlatform = false
  /// 分组展开 / 收起会重建整张侧栏（见 `navigationSectionsLayoutKey`），重建后滚动回到顶上。
  @State private var sidebarScrollMemory = SidebarScrollMemory()
  @AppStorage(DesignTokens.Layout.sidebarWidthStorageKey) private var storedSidebarWidth: Double = 0
  @AppStorage(DesignTokens.Layout.listWidthStorageKey) private var storedListWidthRaw: Double = 0
  /// 三栏的起始宽度只在三栏建立时取一次。直接绑 `storedSidebarWidth` 的话，拖动中
  /// 每记一次，系统分栏就按新的 ideal 重新分配一次宽度，几栏会互相推挤。
  @State private var threeColumnWidths = ThreeColumnWidths.stored()
  /// 列表列的搜索框平时收成列头的一个放大镜图标；点开、⌘F 或已有搜索词时才展开。
  @State private var isListSearchExpanded = false
  /// 点平台默认留在三栏列表里按平台筛选（2026-09-23），和侧栏其他入口一个样子；
  /// 想看卡片墙时从列头「卡片视图」进。换平台或返回后自动回到列表。
  @State private var isPlatformGalleryRequested = false
  @State private var isEmptyTrashConfirmPresented = false
  @FocusState private var isSearchFocused: Bool
  @AppStorage(AppearanceTheme.storageKey) private var appearanceThemeRaw = AppearanceTheme.glass.rawValue
  @AppStorage(ExperimentalFeatures.workbenchKey) private var isWorkbenchUserEnabled = false
  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  @AppStorage("onboarding.capture-v1.dismissed") private var isCaptureOnboardingDismissed = false
  /// 三步卡「看个示例」打开的只读示例（2026-10-01）。
  @State private var isSamplePreviewPresented = false
  /// 灯箱打开时窗口级分栏细线需要让位，避免画在放大的图片上。
  @ObservedObject private var inlineImageLightbox = InlineImageLightboxController.shared
  @ObservedObject private var videoCinema = VideoCinemaController.shared
  /// 列表选中即可预热远程播放；详情卡与预热共享，快速切换时由 controller 取消上一次 prepare。
  @StateObject private var remotePreviewPlayback = RemotePreviewPlayerController()

  private var appearanceTheme: AppearanceTheme { AppearanceTheme(rawValue: appearanceThemeRaw) ?? .glass }
  /// 「跟随系统」靠 SwiftUI 的 colorScheme 环境值在系统翻转时刷新。
  @Environment(\.colorScheme) private var systemColorScheme
  private var theme: HistoryThemeTokens { appearanceTheme.tokens(systemColorScheme: systemColorScheme) }
  /// 主列表的分组。标题为 nil 时不画组头（回收站：按删除时间排，按存入日分组会乱序）。
  private var historyListSections: [HistoryListSectionModel] {
    // 合集按合集里的顺序排，按存入日分组会把顺序切碎。
    if model.selectedScope.isTrashOnly || model.isBrowsingCollection {
      return [.init(title: nil, entries: Array(model.rows.enumerated()).map { ($0.offset, $0.element) })]
    }
    return HistoryListFinding.sections(for: model.rows).map {
      .init(title: $0.group.title(), entries: $0.entries)
    }
  }

  private var ordinaryPendingCaptures: [ManualLinkViewModel.PendingCapture] {
    manualLink.pendingCaptures.filter { $0.profileImportBatchID == nil }
  }
  private var visibleProfileImportBatches: [ProfileImportBatch] {
    manualLink.profileImportBatches.filter {
      ProfileImportQueuePresentation.visible($0, dismissed: dismissedImportNotices)
    }
  }
  private var hasInProgressProfileImportBatch: Bool {
    visibleProfileImportBatches.contains { !ProfileImportQueuePresentation.succeeded($0) }
  }
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
    // 菜单命令（⌘F、⇧⌘N、⌘D、⌘[、Esc）挂在最外层，见 `withMenuCommands`。
    withMenuCommands(themedBody)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
      // 图片灯箱盖在整个窗口内容之上；点击图外区域或 Esc 退出。
      .overlay { InlineImageLightboxOverlay() }
      // 「已复制」药丸浮层：任何复制动作的统一视觉确认。
      .overlay { CopyFeedbackOverlay() }
      // 合集：新建 / 改名 / 删除的弹窗，和加入、移出之后的一句提示（2026-09-29）。
      .modifier(CollectionPromptsModifier(model: model))
      // 视频影院放大 overlay（任何来源）：自己的框，替代坑多的原生全屏。
      .overlay { VideoCinemaOverlay() }
      .foregroundStyle(theme.primaryText)
      .tint(theme.accent)
      .accentColor(theme.accent)
      .onAppear {
        AppearanceTheme.applyApplicationAppearance(appearanceThemeRaw)
        synchronizeRemotePreviewPreheat()
        // 捕获列表引用的必须是局部常量：直接 `[weak model]` 会因为 model 在外层闭包里
        // 已被强捕获而触发 ImplicitStrongCapture 警告。
        let mindMapModel = model
        appModel.startQueuedMindMap = { [weak mindMapModel] taskID in
          mindMapModel?.requestMindMapGeneration(taskID: taskID)
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
      .onChange(of: model.selectedHosts) { oldHosts, hosts in
        guard oldHosts != hosts else { return }
        // Any host-set change (including platform A → B) leaves reading and drops anchors.
        isReadingPlatformGalleryItem = false
        platformGalleryScrollTarget = nil
        model.abandonPlatformGalleryReadingStash()
      }
      // 自动处理管线：新捕获（浏览器/手动链接）到达即按设置勾选步骤串行处理。
      .onChange(of: appModel.currentCapture?.taskID) { _, newTaskID in
        synchronizeRemotePreviewPreheat()
        guard let taskID = newTaskID else { return }
        let settings = providerSettings
        if let requestedAction = appModel.currentCapture?.requestedAction {
          if requestedAction == .save { return }
          if requestedAction == .summarize || requestedAction == .translate {
            // 局部常量：内层闭包必须弱捕获，直接写 `[weak appModel]` 会触发
            // ImplicitStrongCapture 警告。
            let actionModel = appModel
            model.startRequestedAction(taskID: taskID) { [weak actionModel] detail in
              guard let actionModel else { return }
              if requestedAction == .translate {
                await actionModel.translate(historyDetail: detail, preferences: settings.runPreferences)
              } else {
                await actionModel.summarize(historyDetail: detail, preferences: settings.runPreferences)
              }
            }
            return
          }
        }
        let preferences = settings.runPreferences
        // 局部常量：内层闭包必须弱捕获，直接写 `[weak appModel]` 会触发
        // ImplicitStrongCapture 警告。
        let summarizeActionModel = appModel
        let summaryBusyModel = appModel
        model.startAutoPipeline(
          taskID: taskID,
          expectsMedia: appModel.currentCapture?.shouldAutomaticallyPersistLegacyMedia == true,
          transcribe: settings.autoTranscribeNewCaptures,
          tidy: settings.autoTidyTranscription,
          summarize: settings.autoSummarizeNewCaptures,
          mindMap: settings.autoMindMapNewCaptures,
          tidyModel: settings.effectiveTidyModelName,
          summarizeAction: { [weak summarizeActionModel] detail in
            guard let summarizeActionModel else { return false }
            return await summarizeActionModel.startAutomaticSummary(
              historyDetail: detail,
              preferences: preferences
            )
          },
          isSummaryBusy: { [weak summaryBusyModel] in
            guard let summaryBusyModel else { return false }
            return summaryBusyModel.runState.isActive
              || summaryBusyModel.isDataDestinationDisclosurePresented
              || summaryBusyModel.isConfirmingDataDestinationDisclosure
          }
        )
      }
      .onChange(of: manualLink.creatorAssociationRevision) { _, _ in
        model.handleCreatorAssociationChanged()
      }
      .onChange(of: manualLink.profileImportCompletionRevision) { _, _ in
        model.handleProfileImportCompletion()
      }
      .onChange(of: appearanceThemeRaw) { _, newValue in
        AppearanceTheme.applyApplicationAppearance(newValue)
      }
  }

  private var showsPlatformGallerySurface: Bool {
    !model.isCreatorDirectoryActive && !model.isWorkbenchActive
      && PlatformHistoryGalleryPresentation.showsGallery(for: model.selectedHosts)
      && isPlatformGalleryRequested
  }

  private var platformGalleryAccessibilityPrefix: String {
    if model.selectedHosts == Set(["x.com"]) { return "x-post-gallery" }
    if model.selectedHosts == Set(["mp.weixin.qq.com"]) { return "wechat-article-gallery" }
    return "platform-gallery"
  }

  @ViewBuilder private var platformGallerySurface: some View {
    if isReadingPlatformGalleryItem {
      // 返回键只留工具栏左上那一个（2026-09-25）：原来这里另有一行「返回 YouTube」，
      // 和工具栏的「<」两个返回键做的事还不一样。
      detailColumn
    } else {
      PlatformHistoryGallery(
        model: model,
        theme: theme,
        searchFocused: $isSearchFocused,
        scrollTarget: $platformGalleryScrollTarget,
        onOpen: { taskID in
          model.beginPlatformGalleryReading(taskID: taskID)
          isReadingPlatformGalleryItem = true
        },
        contextMenu: { row in AnyView(DeferredMenuContent { historyContextMenu(for: row) }) },
        accessibilityPrefix: platformGalleryAccessibilityPrefix,
        onBack: isPlatformGalleryRequested ? { isPlatformGalleryRequested = false } : nil,
        onDeleteSelection: model.canDelete(protectedTaskIDs: protectedTaskIDs)
          ? { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) } : nil
      )
    }
  }

  /// 博主页一层一层退：读作品 → 作品列表（或抓取批次）；作品列表 → 全部博主。
  private var creatorDirectoryBackTitle: String? {
    guard model.isCreatorDirectoryActive else { return nil }
    if model.isReadingCreatorWorkInDirectory {
      return model.profileImportReturnTarget == nil ? "返回作品" : "返回抓取批次"
    }
    if model.selectedCreator != nil, !showsCreatorDirectoryCatalog { return "返回全部博主" }
    return nil
  }

  private func creatorDirectoryGoBack() {
    if model.isReadingCreatorWorkInDirectory {
      if model.profileImportReturnTarget != nil {
        creatorWorkScrollTarget = nil
        model.returnToProfileImportBatch()
        columnVisibility = .all
      } else {
        creatorWorkScrollTarget = model.selectedTaskID
        model.leaveCreatorWorkReading()
      }
    } else {
      returnToCreatorDirectory()
    }
  }

  /// 菜单命令挂在根上，不挂在中间列表上：卡片墙、博主页、专注阅读里中间列表不渲染，
  /// 原来 ⌘F、⇧⌘N、⌘D 在这几处整排变灰、没有说明（2026-10-01 走查）。
  /// 单独成函数：直接接在根视图那串修饰符后面，编译器类型推断超时。
  private func withMenuCommands<Content: View>(_ content: Content) -> some View {
    content
      .focusedSceneValue(\.focusHistorySearch, FocusHistorySearchAction {
        if columnVisibility == .detailOnly { columnVisibility = .all }
        if !showsPlatformGallerySurface, !model.isCreatorDirectoryActive { isListSearchExpanded = true }
        DispatchQueue.main.async { isSearchFocused = true }
      })
      .focusedSceneValue(\.newNote, NewNoteAction { createNote() })
      .focusedSceneValue(\.todayNote, TodayNoteAction { openTodayNote() })
      .focusedSceneValue(\.toggleFavorite, model.canToggleFavorite ? ToggleFavoriteAction { model.toggleFavorite() } : nil)
      .focusedSceneValue(\.newCollection, model.canEditCollections ? NewCollectionAction { model.requestNewCollection() } : nil)
      .focusedSceneValue(\.goBack, canGoBack ? GoBackAction { goBack() } : nil)
      // 上一条 / 下一条原来挂在详情「⋯」菜单的菜单项上，快捷键跟着菜单走；菜单精简后改由菜单栏承担。
      .focusedSceneValue(\.selectPreviousItem, model.canSelectPrevious ? RunCurrentAction { model.selectAdjacent(offset: -1) } : nil)
      .focusedSceneValue(\.selectNextItem, model.canSelectNext ? RunCurrentAction { model.selectAdjacent(offset: 1) } : nil)
      // Esc 和 ⌘[ 是同一件事：退一层。专注阅读里原来没有任何出口（只在「更多」菜单里，
      // 删掉正在读的那条后「更多」也灰了，只能退出 App）。
      .onExitCommand { if canGoBack { goBack() } }
      .onChange(of: model.selectedHosts) { _, _ in isPlatformGalleryRequested = false }
      .onChange(of: isPlatformGalleryRequested) { _, requested in model.isPlatformCardViewActive = requested }
  }

  /// 现在能不能「退一层」：专注阅读、卡片墙（含读其中一条）、博主页各自的上一层。
  private var canGoBack: Bool {
    columnVisibility == .detailOnly || showsPlatformGallerySurface || creatorDirectoryBackTitle != nil
  }

  private func goBack() {
    if columnVisibility == .detailOnly {
      columnVisibility = .all
    } else if showsPlatformGallerySurface {
      platformGalleryGoBack()
    } else if creatorDirectoryBackTitle != nil {
      creatorDirectoryGoBack()
    }
  }

  private func platformGalleryGoBack() {
    sidebarScrollMemory.snapshot()
    // 卡片墙里勾着几张时，Esc / ⌘[ 先取消选择，再按一次才离开。
    if !isReadingPlatformGalleryItem, !model.selectedTaskIDs.isEmpty {
      model.selectedTaskIDs = []
      return
    }
    if isReadingPlatformGalleryItem {
      platformGalleryScrollTarget = model.endPlatformGalleryReading()
      isReadingPlatformGalleryItem = false
    } else {
      isPlatformGalleryRequested = false
    }
  }

  private var platformGalleryBackTitle: String {
    let name = PlatformHistoryGalleryPresentation.platformDisplayName(for: model.selectedHosts)
    // 中文后接英文名要空一格：「返回 X」「返回 YouTube」，「返回抖音」照旧。
    let needsSpace = name.unicodeScalars.first.map { $0.isASCII } ?? false
    return needsSpace ? "返回 \(name)" : "返回\(name)"
  }

  private var platformGalleryBackIdentifier: String {
    if model.selectedHosts == Set(["x.com"]) { return "x-post-gallery-back" }
    if model.selectedHosts == Set(["mp.weixin.qq.com"]) { return "wechat-gallery-back" }
    return "platform-gallery-back"
  }

  private var themedBody: some View {
    Group {
      if model.blockingErrorCode != nil {
        blockingError
      } else {
        Group {
          if columnVisibility == .detailOnly {
            // macOS 三列 NavigationSplitView 不保证响应 detailOnly；专注模式直接呈现详情。
            Group {
              if showsPlatformGallerySurface { platformGallerySurface }
              else if model.isCreatorDirectoryActive { creatorDirectorySurface }
              else { detailColumn }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(theme.card)
              .modifier(HistoryWindowToolbarThemeModifier(theme: theme, background: theme.card))
          } else if showsPlatformGallerySurface || model.isCreatorDirectoryActive {
            // A gallery is a desktop split, not an adaptive navigation stack.
            // NavigationSplitView can collapse its own host to the reader's
            // intrinsic width when the detail swaps back to a ScrollViewReader.
            HistoryGallerySplitView(sidebarWidth: DesignTokens.Layout.storedSidebarWidth(storedSidebarWidth)) {
              navigationRail.modifier(HistoryWindowToolbarThemeModifier(theme: theme))
            } detail: {
              Group {
                if model.isCreatorDirectoryActive { creatorDirectorySurface }
                else { platformGallerySurface }
              }
              .modifier(HistoryWindowToolbarThemeModifier(theme: theme, background: theme.card))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id("history-gallery-navigation")
            // 窗口名跟着页面走；工具栏里不重复画标题——页面自己的页头已经写着「X · 已保存…」「全部博主」。
            // 原来这里没有标题，工具栏左上角落成 App 名「汲作」（2026-09-25 走查）。
            .navigationTitle(showsPlatformGallerySurface
              ? PlatformHistoryGalleryPresentation.platformDisplayName(for: model.selectedHosts)
              : "博主")
            .toolbar(removing: .title)
            // 回到三栏时从图库页之前记下的宽度起步。
            .onDisappear { threeColumnWidths = .stored() }
          } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
              // 左侧栏可拖；拖出的宽度由 WindowColumnDividerInstaller 记下，
              // 这里和图库页都从同一个值起步，切换分类不再各自一个宽度。
              navigationRail.navigationSplitViewColumnWidth(
                min: DesignTokens.Layout.sidebarMin,
                ideal: threeColumnWidths.sidebar,
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
                } else if model.isCreatorDirectoryActive {
                  creatorDirectory
                } else {
                  sidebar
                }
              }
              // 列表滚动时行文字原样从「全部」标题和搜索、「＋」图标底下穿过（2026-09-24
              // 走查实测；系统 scroll edge 在这一列同样不生效）。和详情列同一层渐隐遮罩。
              .overlay(alignment: .top) { ToolbarScrollFade(background: theme.card) }
              .navigationTitle(listColumnTitle)
              .toolbar(removing: .title)
              .toolbar { listColumnToolbar }
              .navigationSplitViewColumnWidth(
                min: model.isCreatorDirectoryActive ? CreatorDirectoryChrome.listColumnMin : DesignTokens.Layout.listMin,
                ideal: model.isCreatorDirectoryActive ? CreatorDirectoryChrome.listColumnIdeal : threeColumnWidths.list,
                max: model.isCreatorDirectoryActive ? CreatorDirectoryChrome.listColumnMax : DesignTokens.Layout.listMax
              )
              .modifier(HistoryWindowToolbarThemeModifier(theme: theme))
            } detail: {
              detailColumn
                .modifier(HistoryWindowToolbarThemeModifier(theme: theme, background: theme.card))
            }
          }
        }
          // 窗口级分栏细线：贯通工具栏直达窗口顶；系统玻璃主题走原生外观，
          // 图片灯箱打开时移除，避免细线盖在放大的图片上。
          .background(WindowColumnDividerInstaller(
            lineColor: (columnVisibility == .detailOnly || theme.isNative || inlineImageLightbox.url != nil || videoCinema.isPresented) ? nil : NSColor(theme.hairline)
          ))
          .alert(model.deletionConfirmationTitle, isPresented: $model.isDeleteConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelDeletion() }
            Button(model.deletionConfirmationActionTitle, role: .destructive) {
              model.confirmDeletion(protectedTaskIDs: protectedTaskIDs)
            }
          } message: { Text(model.deletionConfirmationMessage) }
          .alert("清空回收站？", isPresented: $isEmptyTrashConfirmPresented) {
            Button("取消", role: .cancel) {}
            Button("彻底删除 \(model.navigationCounts.trash) 条", role: .destructive) {
              model.purgeTrash(olderThanDays: 0)
            }
          } message: { Text("回收站里的内容和它们的视频、图片会从这台电脑上彻底删除，不能撤销。") }
          .alert("正在生成结果", isPresented: $model.isProtectedDeletionAlertPresented) {
            Button("知道了") { model.dismissProtectedDeletionAlert() }
          } message: {
            Text("选中的记录正在执行生成、转写或识别任务。请先取消对应任务，再删除记录。")
          }
          .alert(
            "删除博主「\(creatorPendingDeletion?.directoryDisplayName ?? "")」？",
            isPresented: Binding(
              get: { creatorPendingDeletion != nil },
              set: { if !$0 { creatorPendingDeletion = nil } }
            ),
            presenting: creatorPendingDeletion
          ) { creator in
            Button("取消", role: .cancel) { creatorPendingDeletion = nil }
            Button("删除博主", role: .destructive) {
              model.deleteCreator(creator.id)
              creatorPendingDeletion = nil
            }
          } message: { creator in
            Text("只删除博主本身和它在博主列表里的位置。已保存的 \(creator.savedWorkCount) 条作品会留在资料库里，不会被删除。")
          }
          .alert("无法删除这条历史记录", isPresented: $model.isDeleteFailurePresented) {
            Button("知道了") { model.dismissDeleteFailure() }
          } message: { Text("资料库里什么都没删，请稍后重试。") }
          .alert("删除结果", isPresented: $model.isDeleteOutcomePresented) {
            Button("知道了") { model.dismissDeleteOutcome() }
          } message: { Text(model.deleteOutcomeMessage) }
          .sheet(isPresented: $isNewSparkPresented) { newSparkSheet }
          .sheet(isPresented: $model.isTagManagerPresented) { TagManagerView(model: model) }
          .alert("工作台", isPresented: Binding(
            get: { model.workbenchFailure != nil },
            set: { if !$0 { model.dismissWorkbenchFailure() } }
          )) {
            Button("知道了") { model.dismissWorkbenchFailure() }
          } message: { Text(model.workbenchFailure ?? "") }
          // 批量总结要花钱，确认弹窗里先给出粗估 token 量级再让用户点。
          .alert(
            model.batchSummaryConfirmationTitle,
            isPresented: $model.isBatchSummaryConfirmationPresented
          ) {
            Button("取消", role: .cancel) { model.cancelBatchSummaryRequest() }
            Button("开始总结") {
              let preferences = providerSettings.runPreferences
              // 局部常量：内层闭包必须弱捕获，直接写 `[weak appModel]` 会触发
              // ImplicitStrongCapture 警告。
              let batchSummaryModel = appModel
              let batchSummaryBusyModel = appModel
              model.confirmBatchSummary(
                summarize: { [weak batchSummaryModel] detail in
                  await batchSummaryModel?.summarize(historyDetail: detail, preferences: preferences)
                },
                // 数据去向确认弹窗开着也算「忙」：首条常常要等用户确认一次，
                // 不把它算进去就会被误判成「没能开始」而中止整批。
                isBusy: { [weak batchSummaryBusyModel] in
                  guard let batchSummaryBusyModel else { return false }
                  return batchSummaryBusyModel.runState.isActive
                    || batchSummaryBusyModel.isDataDestinationDisclosurePresented
                    || batchSummaryBusyModel.isConfirmingDataDestinationDisclosure
                }
              )
            }
          } message: { Text(model.batchSummaryConfirmationMessage) }
          .alert(
            "转写 \(untranscribedBacklogToConfirm?.count ?? 0) 条音视频？",
            isPresented: Binding(
              get: { untranscribedBacklogToConfirm != nil },
              set: { if !$0 { untranscribedBacklogToConfirm = nil } }
            )
          ) {
            Button("取消", role: .cancel) { untranscribedBacklogToConfirm = nil }
            Button("开始转写") {
              if let items = untranscribedBacklogToConfirm { localImport.transcribeBacklog(items) }
              untranscribedBacklogToConfirm = nil
            }
            .accessibilityIdentifier("untranscribed-bulk-confirm")
          } message: { Text(untranscribedConfirmationMessage) }
          .alert("批量总结结果", isPresented: $model.isBatchSummaryOutcomePresented) {
            Button("知道了") { model.dismissBatchSummaryOutcome() }
            if model.batchSummaryOutcomeMessage.contains("失败") {
              Button("重试选中项") {
                model.dismissBatchSummaryOutcome()
                model.requestBatchSummary()
              }
            }
          } message: { Text(model.batchSummaryOutcomeMessage) }
          .alert(
            model.batchTranslationConfirmationTitle,
            isPresented: $model.isBatchTranslationConfirmationPresented
          ) {
            Button("取消", role: .cancel) { model.cancelBatchTranslationRequest() }
            Button("开始翻译") {
              let preferences = providerSettings.runPreferences
              // 局部常量：内层闭包必须弱捕获，直接写 `[weak appModel]` 会触发
              // ImplicitStrongCapture 警告。
              let batchTranslateModel = appModel
              let batchTranslateBusyModel = appModel
              model.confirmBatchTranslation(
                translate: { [weak batchTranslateModel] detail in
                  await batchTranslateModel?.translate(historyDetail: detail, preferences: preferences)
                },
                isBusy: { [weak batchTranslateBusyModel] in
                  guard let batchTranslateBusyModel else { return false }
                  return batchTranslateBusyModel.runState.isActive
                    || batchTranslateBusyModel.isDataDestinationDisclosurePresented
                    || batchTranslateBusyModel.isConfirmingDataDestinationDisclosure
                }
              )
            }
          } message: { Text(model.batchTranslationConfirmationMessage) }
          .alert("批量翻译结果", isPresented: $model.isBatchTranslationOutcomePresented) {
            Button("知道了") { model.dismissBatchTranslationOutcome() }
            if model.batchTranslationOutcomeMessage.contains("失败") {
              Button("重试选中项") {
                model.dismissBatchTranslationOutcome()
                model.requestBatchTranslation(outputLanguage: providerSettings.outputLanguage)
              }
            }
          } message: { Text(model.batchTranslationOutcomeMessage) }
          .alert("无法准备导出", isPresented: $model.isExportPreparationFailurePresented) {
            Button("知道了") { model.dismissExportPreparationFailure() }
          } message: { Text("无法准备导出，请检查历史记录后重试。") }
          .alert("无法保存导出文件", isPresented: $model.isExportSaveFailurePresented) {
            Button("知道了") { model.dismissExportSaveFailure() }
          } message: { Text("请检查所选文件夹的权限后重试。") }
          .alert("视频自动保存失败", isPresented: $model.isCapturedMediaAutoSaveFailurePresented) {
            Button("知道了") { model.dismissCapturedMediaAutoSaveFailure() }
          } message: { Text(model.capturedMediaAutoSaveFailureMessage) }
          .alert("需要下载 Apple 离线听写模型", isPresented: $model.isTranscriptionModelConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelModelDownloadConfirmation() }
            Button("下载并转写") { model.confirmModelDownloadAndTranscribe() }
          } message: {
            Text(model.transcriptionModelDownloadMessage)
          }
          .alert("将视频音频发送到在线转写服务？", isPresented: $model.isOnlineTranscriptionConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelOnlineTranscriptionConfirmation() }
            Button("同意并在线转写") { model.confirmOnlineTranscription() }
          } message: {
            Text("汲作会在本机从视频里取出声音、切成小段，发给你设置的在线转写服务商。完整视频和视频地址不会交给服务商；转写稿保存在资料库里。")
          }
          .alert("将转写文字发送给聊天模型校对？", isPresented: $model.isTranscriptTidyConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelTranscriptTidyConfirmation() }
            Button("同意并校对") { model.confirmTranscriptTidy() }
          } message: {
            Text("App 会发送转写文字，以及标题和配文作为上下文，用来还原听写错误、补标点和分段。不发送视频、音频或链接。看不懂的句子会原样保留。校对稿保存为最新原文，原始转写稿保留在历史中。")
          }
          .alert("将正文发送给聊天模型整理版面？", isPresented: $model.isReformatConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelReformatConfirmation() }
            Button("同意并整理") { model.confirmArticleReformat() }
          } message: {
            Text("汲作只发送正文文字，用来在段落之间加小标题，不改正文一个字。整理排版后的版本和原文并存，随时可以切回原文。")
          }
          .fileExporter(
            isPresented: $model.isExportPanelPresented,
            document: model.exportFile.map(HistoryExportDocument.init),
            contentType: uniformType(for: model.exportFile?.format ?? .plainText),
            defaultFilename: model.exportFile?.suggestedFilename ?? "\(ProductDisplay.name)历史.txt"
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
      ToolbarItem(placement: .navigation) {
        if showsPlatformGallerySurface || model.isCreatorDirectoryActive || columnVisibility == .detailOnly {
          Button {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
          } label: {
            Image(systemName: "sidebar.left")
          }
          .help(columnVisibility == .detailOnly ? "显示边栏" : "隐藏边栏")
          .accessibilityLabel(columnVisibility == .detailOnly ? "显示边栏" : "隐藏边栏")
          .accessibilityIdentifier("history-gallery-sidebar-toggle")
        }
      }
      // 卡片墙的出口放在工具栏左上，和系统「返回」同一个位置；原来是页面里的一行字。
      // 一层一层退：在读卡片墙里的一条 → 回卡片墙；在卡片墙 → 回三栏列表。
      ToolbarItem(placement: .navigation) {
        if showsPlatformGallerySurface {
          Button(action: platformGalleryGoBack) {
            Label(isReadingPlatformGalleryItem ? platformGalleryBackTitle : "返回列表", systemImage: "chevron.left")
              // 工具栏默认只画图标：一个光秃秃的「<」看不出是返回、返回到哪（2026-10-01）。
              .labelStyle(.titleAndIcon)
          }
          .help(isReadingPlatformGalleryItem ? platformGalleryBackTitle : "回到左中右三栏的内容列表")
          .accessibilityIdentifier(isReadingPlatformGalleryItem
            ? platformGalleryBackIdentifier
            : "\(platformGalleryAccessibilityPrefix)-toolbar-back")
          .modifier(ToolbarContentEdgeAlignment(sidebarWidth: DesignTokens.Layout.storedSidebarWidth(storedSidebarWidth)))
        }
      }
      ToolbarItem(placement: .navigation) {
        if let title = creatorDirectoryBackTitle {
          Button(action: creatorDirectoryGoBack) {
            Label(title, systemImage: "chevron.left")
              .labelStyle(.titleAndIcon)
          }
          .help(title)
          .accessibilityIdentifier(model.isReadingCreatorWorkInDirectory
            ? "history-creator-directory-back"
            : "history-creator-directory-back-to-catalog")
          .modifier(ToolbarContentEdgeAlignment(sidebarWidth: DesignTokens.Layout.storedSidebarWidth(storedSidebarWidth)))
        }
      }
      // 卡片墙和博主页不是三栏布局，没有详情列把「收藏 / 标签 / ⋯」顶到右边，
      // 它们会挤在左上角、压着侧栏分界线（2026-09-25 Syc 截图）。用弹性空白推回右侧。
      if showsPlatformGallerySurface || model.isCreatorDirectoryActive {
        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }
      }
      ToolbarItemGroup(placement: .primaryAction) {
        // 专注阅读、设置、添加 2026-09-23 移走：专注阅读进阅读区「更多」，设置去侧栏底部，
        // 添加去列表列头。顶栏只留「当前这一条」的操作。
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
            .help("停止尚未开始的批量总结")
            .accessibilityLabel("停止批量总结")
            .accessibilityIdentifier("batch-summarize-stop")
        }
        if model.selectedTaskCount > 1 {
          Button { model.requestBatchSummary() } label: {
            Label("总结选中项", systemImage: MenuIcon.summarize)
          }
          .disabled(!model.canBatchSummarize)
          .help("总结选中的历史条目")
          .accessibilityLabel("总结选中项")
          .accessibilityIdentifier("batch-summarize-history")
          Button { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) } label: {
            Label(
              model.selectedScope == .trash ? "彻底删除选中项" : "移到回收站",
              systemImage: "trash"
            )
          }
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
          .help(model.selectedScope == .trash ? "从本机永久删除选中内容" : "把选中内容移到回收站")
          .accessibilityLabel(model.selectedScope == .trash ? "彻底删除选中项" : "移到回收站")
          .accessibilityIdentifier("delete-selected-history")
        }
        // 图库 / 博主目录只有两栏，没有列表列头可放「添加」，退回顶栏。
        if showsPlatformGallerySurface || model.isCreatorDirectoryActive {
          addMenu
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
    // 转写一完成就接着校对（设置里开着「自动校对」时）。只认「这一次从运行中进入完成」：
    // 打开一条早就转写过的记录，状态也会恢复成完成，不能因此重复调用模型、重复计费。
    // 挂在根视图上一处，不挂在各个视频卡片里——卡片换条目、收起时会错过完成的那一刻。
    .onChange(of: model.transcriptionState) { oldState, newState in
      guard oldState.isActive, newState == .completed, let taskID = model.transcriptionTaskID else { return }
      model.continueWithTidyAfterTranscription(
        taskID: taskID,
        autoTidyEnabled: providerSettings.autoTidyTranscription,
        model: providerSettings.effectiveTidyModelName
      )
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
    .sheet(item: $douyinProfileImportRequest) { request in
      DouyinProfileImportSheet(manualLink: manualLink, request: request) { creatorID in
        showsCreatorDirectoryCatalog = false
        creatorWorkScrollTarget = nil
        model.focusCreatorInDirectory(creatorID)
        columnVisibility = .all
      }
        .id(request.id)
    }
    .sheet(item: Binding(
      get: { douyinProfileImportRequest == nil ? manualLink.browserProfileImportToken : nil },
      set: { if $0 == nil, douyinProfileImportRequest == nil { manualLink.dismissBrowserProfileImport() } }
    )) { _ in
      if let model = manualLink.browserProfileImportModel {
        DouyinProfileImportSheet(external: model, manualLink: manualLink) { creatorID in
          showsCreatorDirectoryCatalog = false
          creatorWorkScrollTarget = nil
          self.model.focusCreatorInDirectory(creatorID)
          columnVisibility = .all
        }
      }
    }
    .alert(
      "要换成另一个主页吗？",
      isPresented: Binding(
        get: { manualLink.browserProfileImportConflict != nil },
        set: { if !$0 { manualLink.cancelIncomingBrowserProfile() } }
      )
    ) {
      browserProfileConflictButtons(incoming: manualLink.browserProfileImportConflict?.incoming)
    } message: {
      Text(manualLink.browserProfileImportConflict?.message ?? "")
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

  /// 「往库里放东西」的入口：链接、博主主页、本地文件、笔记。放在列表列头——
  /// 它作用于列表，和对标应用的「＋」同一个位置。
  private var addMenu: some View {
    // 每项带图标，和窗口顶栏「更多」菜单同一种样子（2026-09-25 走查：一个有图标一个没有）。
    // 快捷键写在菜单栏「文件」里；这里不再挂一份，免得同一组合键在两处各触发一次。
    Menu {
      Button(action: manualLink.open) { Label("添加链接（⌘N）", systemImage: "link") }
      Button(action: manualLink.readClipboardAndOpen) { Label("从剪贴板添加链接（⇧⌘V）", systemImage: "doc.on.clipboard") }
      Button { presentDouyinProfileImport() } label: { Label("添加博主主页", systemImage: "person.crop.circle.badge.plus") }
      Divider()
      Button { localImport.chooseFiles() } label: { Label("导入本地文件…（⇧⌘I）", systemImage: "folder.badge.plus") }
        .disabled(!localImport.canImport)
        .accessibilityIdentifier("import-local-files")
      // 「同步语音备忘录」「同步备忘录」不放这里（2026-10-01 走查：八项里混着两个同步，
      // 「添加」变成了杂物抽屉）。它们是偶尔做一次的批量同步，入口在菜单栏「文件」里。
      Divider()
      Button(action: createNote) { Label("新建笔记（⇧⌘N）", systemImage: "square.and.pencil") }
        .accessibilityIdentifier("create-user-note")
      // 原来侧栏里的「今天」：它是一个动作不是筛选项，收进这里；⌘⇧T 照旧。
      Button(action: openTodayNote) { Label("今天的笔记（⇧⌘T）", systemImage: "calendar") }
        .accessibilityIdentifier("history-navigation-today-note")
    } label: {
      Label("添加", systemImage: "plus")
    }
    // 工具栏菜单不带下拉小箭头：「图标 + ⌄」挤在一排是顶栏拥挤感的主要来源。
    .menuIndicator(.hidden)
    .disabled(!manualLink.canOpen)
    .help("添加链接、博主主页、本地文件或新建笔记")
    .accessibilityLabel("添加")
    .accessibilityIdentifier("manual-link-add-toolbar")
  }

  /// 列表列标题：当前看的是哪一处。原来窗口标题固定写「汲作」，不提供任何信息。
  // 「回到最上面」滚到列表里第一个真实的东西。原来顶上垫一行 0 高的定位行，
  // 它自成一组，侧栏样式在它和「今天」之间加了一段组间距，列头下空出一大截
  // （2026-10-01 Syc 截图）。
  static let listTopBatchesID = "history-list-top-batches"
  static let listTopPendingID = "history-list-top-pending"
  static func listSectionHeaderID(_ sectionID: String) -> String { "history-list-section-\(sectionID)" }
  private var listTopScrollID: AnyHashable? {
    if !visibleProfileImportBatches.isEmpty { return Self.listTopBatchesID }
    if !ordinaryPendingCaptures.isEmpty { return Self.listTopPendingID }
    guard let first = historyListSections.first else { return nil }
    if first.title != nil { return Self.listSectionHeaderID(first.id) }
    return first.entries.first.map { AnyHashable($0.row.taskID) }
  }

  private var listColumnTitle: String {
    // 搜索时标题说清搜到多少条；原来仍写「全部」，看不出是搜索结果、有多少。
    if !model.searchText.isEmpty, let count = model.searchResultCount { return "搜索 · \(count) 条" }
    if let collection = model.selectedCollection { return collection.name }
    if let creator = model.selectedCreator { return creator.directoryDisplayName }
    if let form = model.selectedForm { return form.rawValue }
    // 和侧栏行同名（「公众号」「B站」），「其他」一次选中多个小众来源，也要叫「其他」而不是落回「全部」。
    // 侧栏「自有 → 自有文件」：列标题跟侧栏同名，不写成「本地文件」（那是来源里的合计）。
    if model.selectedScope == .own, model.selectedHosts == [LocalImportSource.files.rawValue] { return "自有文件" }
    if !model.selectedHosts.isEmpty {
      return PlatformHistoryGalleryPresentation.platformDisplayName(for: model.selectedHosts)
    }
    switch model.selectedScope {
    case .own: return "自有"
    case .external: return "外部"
    case .all: return "全部"
    case .recent: return "最近 7 天"
    case .unsummarized: return "未总结"
    case .untidied: return "待校对"
    case .untranscribed: return "待转写"
    case .favorite: return "收藏"
    case .notes: return "笔记"
    case .trash: return "回收站"
    case .works: return "作品"
    case .drafts: return "稿件"
    }
  }

  private var showsListSearchField: Bool {
    isListSearchExpanded || isSearchFocused
      || !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// 列标题最多占多宽：列宽减去右边按钮（搜索、＋，在「笔记」「来源」里各多一个）和边距。
  private var listColumnTitleMaxWidth: CGFloat {
    var buttons: CGFloat = 2
    if model.selectedScope == .notes { buttons += 1 }
    if !model.selectedHosts.isEmpty { buttons += 1 }
    let listWidth = DesignTokens.Layout.storedListWidth(storedListWidthRaw)
    return max(96, listWidth - buttons * 34 - 48)
  }

  @ToolbarContentBuilder private var listColumnToolbar: some ToolbarContent {
    // 列标题自己画，不用系统标题：系统标题在列表列工具栏里预留一段固定宽度，
    // 列宽 260pt 时只剩两个按钮的位置。来源页多一个「卡片视图」就放不下，系统把
    // 整组按钮往右推，「＋」压在分栏线上，还在线右边多出一条分段线（2026-09-24 实测）。
    ToolbarItem(placement: .navigation) {
      // 跟设置里的界面字号走（原来写死 15pt，调大字号后列标题不变，2026-10-01 体检）。
      Text(listColumnTitle)
        .themedFont(.headline, weight: .bold)
        .lineLimit(1)
        .truncationMode(.tail)
        // 博主名可能很长：列宽 220pt 时，标题超过约 96pt 就会把三个按钮重新挤上分栏线。
        // 列拖宽了就跟着放宽，按钮数照实扣（2026-10-04 走查：260pt 列里「汲作验收素材-0929」
        // 被截成「汲作验收素材-…」，右边明明空着）。
        .frame(maxWidth: listColumnTitleMaxWidth, alignment: .leading)
        .help(listColumnTitle)
        .accessibilityAddTraits(.isHeader)
    }
    // 标题不再是弹性项，按钮会贴着标题排；用弹性空白把它们推回列的右缘。
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.flexible)
    }
    ToolbarItemGroup(placement: .automatic) {
      Button {
        isListSearchExpanded = true
        DispatchQueue.main.async { isSearchFocused = true }
      } label: {
        Label("搜索", systemImage: "magnifyingglass")
      }
      .help("搜索标题、正文、总结、标签（⌘F）")
      .accessibilityIdentifier("history-search-toggle")
      // 在「笔记」里时，新建笔记直接一键，不用再进「+」菜单找。
      if model.selectedScope == .notes {
        Button(action: createNote) {
          Label("新建笔记", systemImage: "square.and.pencil")
        }
        .help("新建笔记（⇧⌘N）")
        .accessibilityIdentifier("history-notes-create-toolbar")
      }
      if !model.selectedHosts.isEmpty {
        Button {
          sidebarScrollMemory.snapshot()
          isPlatformGalleryRequested = true
        } label: {
          Label("卡片视图", systemImage: "square.grid.2x2")
        }
        .help("以卡片墙查看这个来源的全部内容；卡片页右上角的「列表 / 卡片」可以切回来")
        .accessibilityIdentifier("history-platform-gallery-open")
      }
      addMenu
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      if showsListSearchField {
      // 三处搜索框同一个组件（2026-10-01 视觉一致性）。
      ThemedSearchField {
        // 提示语要说清搜的范围。写「搜索历史」时用户不会想到能搜正文，
        // 于是有了这个能力也用不上。「总结」必须留：能搜总结是刻意实现的能力。
        DebouncedSearchField(placeholder: listSearchPlaceholder, committed: model.searchText,
                             onChange: { model.searchText = $0 })
          .focused($isSearchFocused)
      }
      .padding(.horizontal, DesignTokens.Layout.columnInset).padding(.top, 5).padding(.bottom, 10)
        .accessibilityIdentifier("history-search")
        .background(ReleaseInitialSearchFocus().allowsHitTesting(false))
      }
      if hasClearableListFilters && !isSingleFilterShownAsTitle {
        activeFilterBar
      }
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
      if model.selectedScope == .trash, !model.rows.isEmpty {
        // 回收站原来没有任何说明：不知道会不会自动清、也没有一键清空，
        // 恢复只藏在右键菜单里（2026-10-01 走查）。
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("放满 \(HistoryTrashPolicy.retentionDays) 天自动删除")
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          Button("清空") { isEmptyTrashConfirmPresented = true }
            .buttonStyle(.appQuiet)
            .controlSize(.small)
            .disabled(model.isReadOnly)
            .accessibilityIdentifier("history-trash-empty")
        }
        .padding(.horizontal, DesignTokens.Layout.columnInset + 4)
        .padding(.bottom, 8)
        .accessibilityIdentifier("history-trash-banner")
      }
      if let notice = manualLink.captureNotice {
        captureNoticeBanner(notice)
      }
      if let failure = model.creatorFailure {
        HStack {
          Label(failure, systemImage: "exclamationmark.triangle")
            .themedFont(.caption)
            .foregroundStyle(theme.danger)
          Spacer()
          Button("知道了", action: model.dismissCreatorFailure)
        }
        // 10：和搜索框、列表卡片外缘同一条线（原来 12，往里缩 2pt，2026-10-01 体检）。
        .padding(.horizontal, 10).padding(.bottom, 8)
      }
      if let creator = model.selectedCreator {
        // 名字一行、按钮一行：列宽 220–260 时同一行放名字加两个按钮，名字被挤成三四个字一折
        // （2026-10-01 体检）。
        VStack(alignment: .leading, spacing: 6) {
          Text(creator.directoryDisplayName)
            .themedFont(.headline)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button("更新资料") {
              presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
            }
            .buttonStyle(.appQuiet)
            .disabled(ProfileImportPlatform.parse(creator.profileURL) == nil)
            .help("只刷新姓名和头像，不必保存新作品")
            .accessibilityIdentifier("history-creator-refresh-selected")
            // 一主一次：抓取作品是这一页的主动作。
            Button("抓取作品") {
              presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
            }
            .buttonStyle(.appProminent(theme.accent))
            .disabled(ProfileImportPlatform.parse(creator.profileURL) == nil)
            .help(ProfileImportPlatform.parse(creator.profileURL) != nil ? "打开主页并选择作品" : "暂不支持此平台主页")
            .accessibilityIdentifier("history-creator-capture-selected")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
      if model.selectedScope == .unsummarized, !providerSettings.autoSummarizeNewCaptures {
        unsummarizedAutoSummaryBanner
      }
      if model.selectedScope == .untranscribed, model.navigationCounts.untranscribed > 0 {
        untranscribedBulkBanner
      }
      switch model.listState {
      case .idle where model.rows.isEmpty:
        HistorySkeletonList(theme: theme)
      case .loading where model.rows.isEmpty:
        HistorySkeletonList(theme: theme)
      // 关键词一条没搜到、但有意思相近的：直接显示那一组，不说「没有符合条件的内容」。
      // 抓取队列里有东西时照样显示列表：队列那一行在列表里。原来空库加第一条链接，
      // 抓取那几秒中间只写着「还没有保存的内容」，像没点上（2026-10-02 新用户走查）。
      case .empty where model.visibleRelatedRows.isEmpty
        && ordinaryPendingCaptures.isEmpty && visibleProfileImportBatches.isEmpty:
        if model.selectedScope == .unsummarized, !model.hasCategoryFilter,
           model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: "checkmark.circle",
            title: "没有未总结的内容",
            message: "新抓取的链接会出现在这里。也可切到「全部」浏览已有内容。",
            actionTitle: "查看全部",
            action: { model.selectScope(.all) },
            seal: (.summary, theme.seal.opacity(0.75))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-unsummarized-empty")
        } else if model.selectedScope == .untidied, !model.hasCategoryFilter,
                  model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: "checkmark.seal",
            title: "都校对过了",
            message: "新的转写还没校对时，会出现在这里。",
            actionTitle: "查看全部",
            action: { model.selectScope(.all) },
            seal: (.proof, theme.seal.opacity(0.75))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-untidied-empty")
        } else if model.selectedScope == .untranscribed, !model.hasCategoryFilter,
                  model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: "waveform",
            title: "都转写过了",
            message: "新导入、新同步的音视频还没转成文字时，会出现在这里。",
            actionTitle: "查看全部",
            action: { model.selectScope(.all) },
            seal: (.record, theme.seal.opacity(0.75))
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-untranscribed-empty")
        } else if model.selectedScope == .notes, !model.hasCategoryFilter,
                  model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: "square.and.pencil",
            title: "还没有笔记",
            message: "随手记下想法、灵感或读后感。",
            actionTitle: "写第一条笔记",
            action: createNote
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-notes-empty")
        } else if model.selectedScope == .trash, !model.hasCategoryFilter,
                  model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: "trash",
            title: "回收站是空的",
            message: "删除的内容会在这里保留 \(HistoryTrashPolicy.retentionDays) 天。过期后会从本机彻底清除，无法再恢复。",
            actionTitle: "查看全部",
            action: { model.selectScope(.all) }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-trash-empty")
        } else if let collection = model.selectedCollection,
                  model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HistoryInlineState(
            symbol: CollectionIcon.collection,
            title: "「\(collection.name)」还是空的",
            message: "在列表里右键一条内容，选「加入合集」，就会按加入的先后排在这里；多选后可以一起加入。进来之后可以拖动调整顺序。",
            actionTitle: "去全部里挑",
            action: { model.selectScope(.all) }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-collection-empty")
        } else if model.showsCreatorZeroWorks {
          HistoryInlineState(
            symbol: "tray",
            title: "尚未保存作品",
            message: "打开主页后勾选要保存的内容。",
            actionTitle: "抓取作品",
            action: {
              if let url = model.selectedCreator?.profileURL {
                presentDouyinProfileImport(profileURL: url, autoStart: true)
              }
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-creator-zero-works")
        } else if model.hasActiveFilter {
          filterEmptyState
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("history-filter-empty")
        } else {
          // 没有任何内容时也要说话：纯空白分不清「扫完了没有」和「还没加载」。
          // 完整的三步引导在详情列，这里只留一句（2026-10-01 走查：中栏、三步卡、
          // 下面一块各说一遍同一件事，三个入口只留三步卡）。
          VStack(spacing: 10) {
            SealMark(glyph: .external, size: 52, color: theme.seal.opacity(0.75), style: .pending)
              .frame(width: 58, height: 58)
            Text("还没有保存的内容").themedFont(.headline)
          }
          .padding(24)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("history-empty")
        }
      case .failed where model.rows.isEmpty:
        // 三句：发生了什么、数据安不安全、现在能做什么。第三句必须对应一个
        // 真能点的按钮——只写「请稍后重试」而没有重试入口，等于让人自己猜。
        if model.canRetryList {
          HistoryInlineState(
            symbol: "exclamationmark.triangle",
            title: "无法载入历史记录",
            message: "这次没能从本机读出历史。已保存的内容都还在，这期间也不会写入任何变更。点「重试」再读一次。",
            actionTitle: "重试",
            action: { model.retryList() }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-list-failed")
        } else {
          HistoryInlineState(
            symbol: "exclamationmark.triangle",
            title: "无法载入历史记录",
            message: "资料库这次打不开。已保存的内容都还在，这期间也不会写入任何变更。退出并重新打开\(ProductDisplay.name)通常能恢复；仍然不行时，可在「数据与备份」里从备份恢复。",
            actionTitle: "查看备份说明",
            action: {
              SettingsNavigationRequest.request("dataBackup")
              openSettings()
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-list-failed")
        }
      case .loaded, .loading, .failed, .idle, .empty:
        ScrollViewReader { batchScroll in
          List(selection: $model.selectedTaskIDs) {
          if !visibleProfileImportBatches.isEmpty {
            Section {
              ProfileImportBatchStack(
                manualLink: manualLink,
                historyModel: model,
                compact: true
              )
              .listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
              .listRowSeparator(.hidden)
              .id(Self.listTopBatchesID)
            } header: {
              if hasInProgressProfileImportBatch {
                listSectionHeader("主页抓取批次")
              }
            }
          }
          // 排队抓取区：提交链接后立刻回到列表，这里可见进度/失败重试，
          // 不再让用户守着弹窗转圈。
          if !ordinaryPendingCaptures.isEmpty {
            Section {
              ForEach(ordinaryPendingCaptures) { pending in
                PendingCaptureRow(pending: pending, model: manualLink)
              }
            } header: {
              listSectionHeader("抓取队列").id(Self.listTopPendingID)
            }
          }
          // 按存入时间分「今天 / 昨天 / 近 7 天 / 几月」。回收站按删除时间排，不分组。
          ForEach(historyListSections) { section in
          Section {
          ForEach(section.entries, id: \.row.taskID) { index, row in
            UIReadingHistoryRow(
              row: row,
              isSelected: model.selectedTaskIDs.contains(row.taskID),
              faviconURL: model.faviconImageURL(for: row),
              theme: theme,
              // 分组的第一行总是写作者：上一行在另一个分组里，读者看不到它。
              showsAuthor: index == section.entries.first?.index
                || !UIReadingHistoryRow.repeatsPreviousAuthor(in: model.rows, at: index),
              onToggleFavorite: { model.toggleFavorite(taskID: row.taskID) },
              onSummarize: { summarizeSingle(row) },
              onActivate: { model.selectedTaskIDs = [row.taskID] },
              // 「更多」和右键是同一份菜单。原来列表内联写了一份、画廊调另一份，
              // 两边已经开始漂移；现在只有 `historyContextMenu` 一处。
              moreMenu: { AnyView(DeferredMenuContent { historyContextMenu(for: row) }) }
            ).equatable().tag(row.taskID).onAppear { model.loadNextPageIfNeeded(after: row) }
              .listRowBackground(Color.clear)
              // 卡片之间留出 8pt，选中底色才读得出是一张张独立的卡。
              // 左右 -6：抵掉表格自带的 16pt，卡片外缘落在 10pt，和搜索框、侧栏选中条对齐。
              .listRowInsets(EdgeInsets(top: 4, leading: -6, bottom: 4, trailing: -6))
              .listRowSeparator(.hidden)
              .contextMenu { DeferredMenuContent { historyContextMenu(for: row) } }
          }
          // 合集里可以拖动调整顺序；其它列表按时间排，没有「顺序」可调。
          .onMove(perform: model.canReorderSelectedCollection ? { model.moveCollectionRows(fromOffsets: $0, toOffset: $1) } : nil)
          } header: {
            if let title = section.title {
              // 和侧栏分组标题同一种写法、同一条左边线（卡片里的图标）。
              listSectionHeader(title)
                .id(Self.listSectionHeaderID(section.id))
                .accessibilityIdentifier("history-list-day-group")
            }
          }
          }
          if !model.visibleRelatedRows.isEmpty {
            relatedRowsSection
          }
          if model.isLoadingNextPage { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() } }
          else if model.listErrorCode != nil, model.canRetryList {
            HStack(alignment: .firstTextBaseline) {
              Text("下一页没能载入。已经显示的内容都在，也没有发生任何写入。点「重试」再读一次。")
                .themedFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: DesignTokens.Space.sm)
              Button("重试", action: model.retryList)
                .accessibilityIdentifier("history-list-next-page-retry")
            }
          }
        }.listStyle(.sidebar)
          // 顶端定位行要真的是 0 高：List 默认给每行一个最小行高，那一行原来白占了一整行，
          // 列表顶上空出一大截（2026-10-01 Syc 截图）。内容行自己有 minHeight 44，不受影响。
          .environment(\.defaultMinListRowHeight, 0)
          // 分组标题默认最小高度和列表顶部内边距叠起来，「今天」离列头空出约 60pt，
          // 比左栏、正文都低一截（2026-10-01 Syc 截图）。收到和侧栏同一档。
          .environment(\.defaultMinListHeaderHeight, 22)
          .contentMargins(.top, 0, for: .scrollContent)
          // `.listStyle(.sidebar)` 只是外观，读屏却会把这一列念成「边栏」——
          // 而真正的边栏在它左边。显式命名成它实际装的东西。
          .accessibilityLabel("内容列表")
          .accessibilityIdentifier("history-content-list")
          // 滚动中整表一直在长高（行高是估算的、翻页又多 50 行），滑块平滑过渡，不再一跳一跳。
          .background(SmoothKnobScrollerInstaller().frame(width: 0, height: 0))
          .scrollContentBackground(.hidden)
          // 滑动中读回来的下一页等手停了再并入（见 `HistoryViewModel.setListScrolling`）。
          .onScrollPhaseChange { _, phase in model.setListScrolling(phase.isScrolling) }
          .onDeleteCommand { model.requestDeletion(protectedTaskIDs: protectedTaskIDs) }
          // macOS List 对插入行沿用估算行高，新到卡片被压扁；初始构建
          // 的测量始终正确，因此新条目登顶时整表重建（新行本就在顶部，
          // 不损失滚动位置），行高恢复按真实内容计算。
          // 搜索结果换了也整表重建：从最上面开始，连「昨天」这类分组标题一起露出来。
          // 用 scrollTo 第一行会把它上面的分组标题顶出视野（2026-10-01 自查）。
          .id("\(model.listRebuildToken)|\(model.searchScrollToTopToken)")
          .onChange(of: model.profileImportScrollTarget) { _, target in
            guard let target else { return }
            withAnimation(historyUIAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
              batchScroll.scrollTo(target, anchor: .center)
            }
            model.consumeProfileImportScrollTarget()
          }
          // 搜索、从博主页回来：等新列表落地再滚到顶。只靠整表重建不够——实测从博主页
          // 回到「全部」，列表仍停在 9 月 8 日那段（2026-10-01 自查）。
          .task(id: model.searchScrollToTopToken) {
            guard model.searchScrollToTopToken > 0 else { return }
            for _ in 0..<40 where model.listState == .loading {
              try? await Task.sleep(for: .milliseconds(50))
            }
            // 列表落地后还会因选中项、整表重建再挪一次位置：隔一会儿再滚一次，以最后一次为准。
            for delay in [150, 450, 900] {
              try? await Task.sleep(for: .milliseconds(delay == 150 ? 150 : delay - 150))
              if Task.isCancelled { return }
              if let top = listTopScrollID { batchScroll.scrollTo(top, anchor: .top) }
            }
          }
          // reveal 之后列表要重载，目标行可能还没进 rows：等它出现再滚。
          // 一页 50 条，较早的内容不在第一页——不在就接着读下一页。上限 40 页（2000 条）：
          // 原来只追 6 页，实测第 833 条的录音、第 300 多条的公众号文章都跟不过去
          // （2026-10-01 走查）。再往前的不追，详情照样打开，只是列表留在原处。
          .task(id: model.revealScrollTarget) {
            guard let target = model.revealScrollTarget else { return }
            var extraPages = 0
            for _ in 0..<400 {
              // 先等 reveal 触发的重载落地：重载前的旧列表里可能正好有这一行，
              // 这时滚过去，随后第一页换上来，位置就偏了十来行（2026-10-01 自查）。
              if model.listState != .loading, model.rows.contains(where: { $0.taskID == target }) {
                try? await Task.sleep(for: .milliseconds(50))
                batchScroll.scrollTo(target, anchor: .center)
                break
              }
              if model.listState != .loading, !model.isLoadingNextPage, let last = model.rows.last {
                guard extraPages < 40, model.hasMorePages else { break }
                model.loadNextPageIfNeeded(after: last)
                extraPages += 1
              }
              try? await Task.sleep(for: .milliseconds(50))
              if Task.isCancelled { return }
            }
            model.consumeRevealScrollTarget()
          }
        }
      }
    }
    // 剪贴板提示改成浮层。原来它排在列表上面，出现和消失都会把整张列表
    // 往下推一截又弹回来——用户正在读的那一行会自己跑掉。
    // 浮在列表**底部**：放在顶部会一直盖住列表第一条（通常正是刚选中、正在读的那条）。
    .overlay(alignment: .bottom) {
      if let suggestion = manualLink.clipboardSuggestion {
        ClipboardSuggestionBanner(
          suggestion: suggestion,
          capture: manualLink.captureClipboardSuggestion,
          ignore: manualLink.ignoreClipboardSuggestion
        )
        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(theme.hairline, lineWidth: 1)
        )
        .designShadow(.floating, tint: theme.canvas)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion),
      value: manualLink.clipboardSuggestion
    )
    .frame(maxWidth: .infinity)
    // 底色铺到窗口顶：工具栏自己不再着色（见 HistoryWindowToolbarThemeModifier），
    // 这一列头顶那段由它自己的颜色填满，列与列的分界因此在工具栏里也对得上。
    //
    // 列表和正文同用纸面色：原来侧栏、列表、正文三档底色，窗口被切成三块互不相干的板子。
    // 现在侧栏一档、「列表 + 正文」一档，中间只靠一条细线分开，读起来是一组。
    .background(theme.card.opacity(theme.isNative ? 0 : 1).ignoresSafeArea(edges: .top))
    // 搜索框失焦且没有搜索词时收回成列头图标，列表多出一行。
    .onChange(of: isSearchFocused) { _, focused in
      // 只在 App 在前台时按失焦收起：从后台点放大镜那一下，焦点还没进来就先「失焦」了，
      // 搜索框弹出又立刻收回（2026-10-02 自查）。切到别的 App 时也不该把用户展开的框收掉。
      if !focused, NSApp.isActive, model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        isListSearchExpanded = false
      }
    }
    // 用筛选条上的 × 清掉搜索词时，搜索框并没有焦点，上面那条收回规则碰不到——
    // 空的搜索框就一直占着列头下面一行（2026-10-01 Syc 截图）。词清空且不在输入时一并收回。
    .onChange(of: model.searchText) { _, text in
      if !isSearchFocused, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        isListSearchExpanded = false
      }
    }
  }

  /// 「自有 / 外部」下面缩进的本机来源行。没有条目的来源不出行。
  @ViewBuilder private func localSourceRows(_ hosts: [String]) -> some View {
    let items = hosts.compactMap { host in
      model.navigationCounts.platforms.first { $0.host == host }
    }.filter { $0.count > 0 }
    if !items.isEmpty {
      UIReadingPlatformNavigation(
        items: items.map { .init(host: $0.host, count: $0.count, faviconURL: nil, faviconTaskID: nil) },
        theme: theme,
        isSelected: { model.selectedHosts.contains($0) },
        onSelect: { host in
          isReadingPlatformGalleryItem = false
          model.selectHost(host)
        }
      )
      .padding(.leading, 16)
    }
  }

  private struct StepStatusRow {
    let scope: HistoryListScope
    let title: String
    let symbol: String
    let count: Int
    let help: String
    let identifier: String
  }

  /// 「工序状态」下的几行：清空了就不占一行，正选中时仍留着。
  private var stepStatusRows: [StepStatusRow] {
    var rows: [StepStatusRow] = []
    let counts = model.navigationCounts
    if counts.untranscribed > 0 || model.selectedScope == .untranscribed {
      rows.append(.init(scope: .untranscribed, title: "待转写", symbol: "waveform", count: counts.untranscribed,
                        help: "带音视频、还没转成文字的内容", identifier: "history-navigation-untranscribed"))
    }
    if counts.untidied > 0 || model.selectedScope == .untidied {
      rows.append(.init(scope: .untidied, title: "待校对", symbol: "checkmark.seal", count: counts.untidied,
                        help: "有转写、还没用模型校对过的内容", identifier: "history-navigation-untidied"))
    }
    // 自动总结开着时新内容会自己总结，这一行就不占位（2026-10-01 走查：「待总结 475」像一份做不完的作业）。
    if !providerSettings.autoSummarizeNewCaptures || model.selectedScope == .unsummarized {
      rows.append(.init(scope: .unsummarized, title: "未总结", symbol: MenuIcon.summarize, count: counts.unsummarized,
                        help: "还没有生成总结的内容", identifier: "history-navigation-unsummarized"))
    }
    return rows
  }

  /// 正选中其中一行时一定展开，免得选中项藏在折叠里。
  private var showsStepStatusRows: Bool {
    navigationStepStatusExpanded || stepStatusRows.contains { $0.scope == model.selectedScope }
  }

  /// 「工序状态」那一行：图标列、文字起点、行高、选中底都和 `navigationButton` 同一套尺寸，
  /// 展开箭头放在数字那一列（2026-10-04：原来箭头占了图标位、左右边距自己写，整行比上下
  /// 几行往右缩了 4pt、行也矮一截）。
  private var stepStatusDisclosureRow: some View {
    Button {
      sidebarScrollMemory.remember(expanding: !navigationStepStatusExpanded)
      navigationStepStatusExpanded.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "checklist")
          .font(.system(size: DesignTokens.IconSize.sidebar, weight: .regular))
          .foregroundStyle(theme.secondaryText)
          .frame(width: 18)
        Text("工序状态")
          .themedFont(.body)
          .foregroundStyle(theme.primaryText)
          .layoutPriority(1)
        Spacer(minLength: DesignTokens.Space.xs)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.secondaryText)
          .rotationEffect(.degrees(showsStepStatusRows ? 90 : 0))
          .padding(.horizontal, 6)
      }
      .frame(minHeight: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, DesignTokens.Space.xxs)
    .padding(.horizontal, DesignTokens.Space.sm)
    .padding(.horizontal, -6)
    .help("还没转写、没校对、没总结的内容，要批量补做时点开")
    .accessibilityLabel("工序状态")
    .accessibilityValue(showsStepStatusRows ? "已展开" : "已折叠")
    .accessibilityIdentifier("history-navigation-step-status")
  }

  @ViewBuilder private var ownLocalFilesRow: some View {
    let host = LocalImportSource.files.rawValue
    if model.navigationCounts.ownLocalFiles > 0 {
      UIReadingPlatformNavigation(
        // 悬停说清和「来源」那行的差别（2026-10-01）：两行同名、数字不同，不说明像算错了。
        items: [.init(
          host: host,
          count: model.navigationCounts.ownLocalFiles,
          faviconURL: nil,
          faviconTaskID: nil,
          helpText: "自己的本地文件（\(model.navigationCounts.ownLocalFiles) 条）；全部本地文件在「来源 → 本地文件」",
          title: "自有文件"
        )],
        theme: theme,
        isSelected: { model.selectedHosts == [$0] && model.selectedScope == .own },
        onSelect: { host in
          isReadingPlatformGalleryItem = false
          model.selectHost(host, scope: .own)
        }
      )
      .padding(.leading, 16)
      .accessibilityIdentifier("history-navigation-own-local-files")
    }
  }

  /// 侧栏「合集」（2026-09-29）：一组要按顺序一起看的内容，例如一套教程。放在「视图」之后；
  /// 每个合集一行（名称 + 条数），标题右侧「＋」新建，右键改名、删除。
  @ViewBuilder private var collectionsNavigationSection: some View {
    Section {
      if navigationCollectionsExpanded {
        if model.collections.isEmpty {
          // 2026-10-01 走查：原来两句话在侧栏里被截成「例…」。精简成一句放得下的，
          // 仍允许换行，窄侧栏或大字号时不再截断。
          Text("点 ＋ 把一组内容按顺序放一起")
            .themedFont(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history-navigation-collections-empty")
        } else {
          ForEach(model.collections) { collection in
            // 合集名一行：博主页、图库页的侧栏行宽略窄，两行时同一个名字在不同页面
            // 一会儿一行一会儿两行（2026-10-01 走查）。全名在悬停提示里。
            navigationButton(
              collection.name,
              systemImage: CollectionIcon.collection,
              count: collection.itemCount,
              selected: model.selectedCollectionID == collection.id && !model.isCreatorDirectoryActive,
              titleLineLimit: 1
            ) {
              isReadingPlatformGalleryItem = false
              model.selectCollection(collection.id)
            }
            .help(collection.name)
            .contextMenu {
              Button { model.requestRenameCollection(collection) } label: {
                Label("重命名…", systemImage: "pencil")
              }
              .disabled(!model.canEditCollections)
              Divider()
              Button(role: .destructive) { model.requestDeleteCollection(collection) } label: {
                Label("删除合集…", systemImage: "trash")
              }
              .disabled(!model.canEditCollections)
            }
            .accessibilityIdentifier("history-navigation-collection-\(collection.id.rawValue)")
          }
        }
      }
    } header: {
      HStack(spacing: DesignTokens.Space.xs) {
        navigationSectionHeader("合集", expanded: $navigationCollectionsExpanded)
          .accessibilityIdentifier("history-navigation-collections-header")
        Button { model.requestNewCollection() } label: {
          Image(systemName: "plus")
            .font(.system(size: DesignTokens.IconSize.inline, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditCollections)
        .help("新建合集")
        .accessibilityLabel("新建合集")
        .accessibilityIdentifier("history-navigation-collection-add")
      }
    }
  }

  private var navigationRail: some View {
    ScrollViewReader { proxy in
    List {
      // 侧栏顶上：「汲作」两字印 + 宋体名字（2026-09-30 Syc 定稿丙：朱白相间、古法右起）。
      // 只写中文名，英文工程名不给用户看。
      HStack(spacing: 10) {
        BrandSealMark(size: 34)
        Text("汲作")
          .font(.custom(ReadingFontCatalog.editorialSerifFamily, size: 16).weight(.semibold))
          .tracking(4)
          .foregroundStyle(theme.primaryText)
      }
        .padding(.horizontal, DesignTokens.Space.sm)
        .padding(.bottom, DesignTokens.Space.xs)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("history-sidebar-wordmark")
        // 侧栏重建后第一行总在眼前，借它拿到侧栏的滚动视图、把位置还原回去。
        .background(SidebarScrollProbe(memory: sidebarScrollMemory))
      // 顶部三个入口按「这条内容是谁说的」切（2026-09-24）：全部 = 自有 + 外部，数字加得上。
      // 汲作是记录平台，不是待办清单：原来的收件箱 / 已归档 / 已使用记的是「处理到哪了」，
      // 那是外部 Agent 或用户自己工作流的事，不占侧栏最显眼的位置。
      Section {
        navigationButton("全部", systemImage: "line.3.horizontal", count: model.navigationCounts.total, selected: model.selectedScope == .all && !model.hasCategoryFilter && !model.isCreatorDirectoryActive && !model.isWorkbenchActive) {
          model.selectScope(.all)
        }
        .help("所有记录：收集来的外部内容，和自己的笔记、作品、备忘录、录音")
        .accessibilityIdentifier("history-navigation-all")
        navigationButton("自有", systemImage: OwnershipIcon.own, seal: .own, count: model.navigationCounts.own, selected: model.selectedScope == .own && !model.hasCategoryFilter && !model.isCreatorDirectoryActive && !model.isWorkbenchActive) {
          model.selectScope(.own)
        }
        .help("自己说的：笔记、作品、备忘录、语音备忘录。判断错了可以右键改成「外部」")
        .accessibilityIdentifier("history-navigation-own")
        // 「笔记」放回来（2026-09-25 Syc：新建笔记找不到了）：09-24 改版撤掉「我的笔记」后，
        // 自己写的笔记只能从「形式 → 笔记」里和 740 条备忘录混着找，新建也只剩「+」菜单。
        // 它是自己写的，排在「自有」下面第一个。
        navigationButton("笔记", systemImage: "square.and.pencil", count: model.navigationCounts.notes, selected: model.selectedScope == .notes) {
          model.selectScope(.notes)
        }
        .padding(.leading, 16)
        .help("自己在汲作里写的笔记（⇧⌘N 新建）")
        .accessibilityIdentifier("history-navigation-notes")
        localSourceRows([LocalImportSource.appleNotes.rawValue, LocalImportSource.voiceMemos.rawValue])
        // 自有的本地文件（2026-10-01）：缺了这行，「自有」下面几项加起来比「自有」少，
        // 看着像丢了数据。只数归自有的那部分，点进去也只看自有的。2026-10-04 起叫「自有文件」：
        // 原来也叫「本地文件」，和「来源」里那行同名不同数（15 / 20），只能靠悬停说明。
        ownLocalFilesRow
        navigationButton("外部", systemImage: OwnershipIcon.external, seal: .external, count: model.navigationCounts.external, selected: model.selectedScope == .external && !model.hasCategoryFilter && !model.isCreatorDirectoryActive && !model.isWorkbenchActive) {
          model.selectScope(.external)
        }
        .help("别人的内容：抓来的帖子、文章、视频，从微信、浏览器下载后拖进来的文件。判断错了可以右键改成「自有」")
        .accessibilityIdentifier("history-navigation-external")
      }
      // 第一组不给标题。它是打开 App 的默认落点，标题不提供任何新信息。

      // 视图：同一批资料换个角度看。以后的自定义视图也放这里。
      Section {
        if navigationViewsExpanded {
          // 「最近」说不清是多近。标签直接写出口径，省得每个人自己猜一个。
          navigationButton("最近 7 天", systemImage: "clock.arrow.circlepath", count: model.navigationCounts.recent, selected: model.selectedScope == .recent) {
            model.selectScope(.recent)
          }
          .accessibilityIdentifier("history-navigation-recent")
          navigationButton("收藏", systemImage: "star", count: model.navigationCounts.favorite, selected: model.selectedScope == .favorite) {
            model.selectScope(.favorite)
          }
          .accessibilityIdentifier("history-navigation-favorite")
          // 待校对 / 待转写 / 未总结收进一个默认折叠的「工序状态」（2026-10-04 侧栏去重）：
          // 原来和「最近 7 天」「收藏」「回收站」平铺在「视图」里，一组里混着三种东西。
          // 不加新概念、不是收件箱：只是把已有的三行收起来，要批量补做时点开。
          if !stepStatusRows.isEmpty {
            stepStatusDisclosureRow
            if showsStepStatusRows {
              ForEach(stepStatusRows, id: \.scope) { row in
                navigationButton(row.title, systemImage: row.symbol, count: row.count, selected: model.selectedScope == row.scope) {
                  model.selectScope(row.scope)
                }
                .padding(.leading, 16)
                .help(row.help)
                .accessibilityIdentifier(row.identifier)
              }
            }
          }
          // 回收站清空后正停在回收站里：行不能凭空消失，否则侧栏一个高亮都没有（2026-10-01 体检）。
          if model.navigationCounts.trash > 0 || model.selectedScope == .trash {
            navigationButton(
              "回收站",
              systemImage: "trash",
              count: model.navigationCounts.trash,
              selected: model.selectedScope == .trash
            ) {
              model.selectScope(.trash)
            }
            .accessibilityIdentifier("history-navigation-trash")
          }
        }
      } header: {
        navigationSectionHeader("视图", expanded: $navigationViewsExpanded)
          .accessibilityIdentifier("history-navigation-views-header")
      }

      collectionsNavigationSection

      // 形式：这条内容「是什么」。抓取时按规则判定（`ContentForm`），不需要 AI。
      if !model.navigationCounts.forms.isEmpty {
        Section {
          if navigationFormsExpanded {
            // 「笔记」不在这里列（2026-10-04 侧栏去重）：它就是「自有」下的笔记 + 备忘录，
            // 原来两处都叫「笔记」、一处 3 条一处 743 条。正选中它时仍留着，免得选中项凭空消失。
            ForEach(model.navigationCounts.forms.filter { $0.form != .note || model.selectedForm == .note }) { item in
              navigationButton(
                item.form.rawValue,
                systemImage: item.form.systemImage,
                count: item.count,
                selected: model.selectedForm == item.form && !model.isCreatorDirectoryActive
              ) {
                model.selectForm(item.form)
              }
              .accessibilityIdentifier("history-navigation-form-\(item.form.rawValue)")
            }
          }
        } header: {
          navigationSectionHeader("形式", expanded: $navigationFormsExpanded)
            .accessibilityIdentifier("history-navigation-forms-header")
        }
      }

      if !model.navigationCounts.platforms.isEmpty {
        // 公共平台各占一行；杂项来源聚合进"待分类"，避免侧栏被长域名占满。
        // 本机来源（备忘录、语音备忘录、本地文件）和外部平台同属「从哪来」，合在一组按条数排。
        // 本机来源（2026-09-25）挪到「自有 / 外部」下面：备忘录、语音备忘录是自己说的。
        // 本地文件（2026-09-29）回到「来源」：它说的是「从哪个渠道进来」，每一份按下载标记
        // 各自归自有或外部，不整组挂在任何一边下面。
        let filesHost = LocalImportSource.files.rawValue
        let knownPlatforms = model.navigationCounts.platforms.filter {
          $0.host == filesHost
            || (HistoryPlatformDisplay.isWellKnown(host: $0.host) && LocalImportSource(rawValue: $0.host) == nil)
        }
        let miscPlatforms = model.navigationCounts.platforms.filter {
          $0.host != filesHost && !HistoryPlatformDisplay.isWellKnown(host: $0.host)
        }
        // 分区标题同样要显式给字体：`Section("平台")` 那种字符串写法的标题是 List
        // 自己渲染的，和行内容一样收不到环境字体。
        Section {
          if navigationPlatformsExpanded {
            // 平台名称必须常驻可见。只显示图标虽然省高度，但把理解成本转嫁给
            // tooltip；新的紧凑行仍然只占一行，同时给出图标、名称和数量。
            UIReadingPlatformNavigation(
              items: knownPlatforms.map { platform in
                let favicon = model.platformFavicon(forHost: platform.host)
                // 「来源」里的本地文件是合计，「自有」下那行只数自有的；差出来的就是外部文件。
                let externalFiles = platform.count - model.navigationCounts.ownLocalFiles
                return .init(
                  host: platform.host,
                  count: platform.count,
                  faviconURL: favicon?.url,
                  faviconTaskID: favicon?.taskID,
                  helpText: platform.host == filesHost && externalFiles > 0
                    ? "本地文件（\(platform.count) 条），含 \(externalFiles) 条外部文件"
                    : nil
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
                  // 「自有」下的本地文件也选中这个 host，但那时这里不该一起亮。
                  : model.selectedHosts.contains(host) && model.selectedScope == .all
              },
              onSelect: { host in
                isReadingPlatformGalleryItem = false
                if host == HistoryPlatformDisplay.miscHost {
                  model.selectHosts(miscPlatforms.map(\.host))
                } else {
                  model.selectHost(host)
                }
              },
              // 4 家：侧栏分组多，平台再多露一行，最下面几项就得滚动才看得到（2026-10-01）。
              collapsedLimit: 4,
              isExpanded: $navigationPlatformsShowsAll
            )
          }
        } header: {
          navigationSectionHeader("来源", expanded: $navigationPlatformsExpanded)
        }
      }

      Section {
        if navigationCreatorsExpanded {
          navigationButton(
            "全部博主",
            systemImage: "person.2",
            count: model.navigationCounts.creatorCount,
            // 正在看某位置顶博主时只亮那一行，不和「全部博主」一起亮（2026-10-01 体检）。
            selected: model.isCreatorDirectoryActive
              && !model.navigationCounts.pinnedCreators.contains { isPinnedCreatorHighlighted($0.id) }
          ) {
            showsCreatorDirectoryCatalog = true
            creatorWorkScrollTarget = nil
            creatorDirectoryScrollTarget = model.selectedCreatorID
            model.enterCreatorDirectory()
          }
          .accessibilityIdentifier("history-navigation-creators-all")
          ForEach(model.navigationCounts.pinnedCreators) { creator in
            creatorPinRow(creator)
              .padding(.leading, 14)
          }
          // 「导入博主」是个动作不是去处，不再常驻侧栏；入口放在「全部博主」页标题右侧，
          // 列表为空时空状态里也有同一个按钮。
        }
      } header: {
        navigationSectionHeader("博主", expanded: $navigationCreatorsExpanded)
      }
      .accessibilityIdentifier("history-navigation-creators")

      if model.navigationCounts.tags.isEmpty {
        // 标签是"内容讲什么"：总结后由模型生成，也可在详情里手动添加。
        // 空态保留区块存在感，而不是让整块消失。
        Section {
          Text("总结后自动生成，也可在详情中手动添加")
            .themedFont(.caption)
            .foregroundStyle(.tertiary)
        } header: {
          navigationSectionHeader("标签")
        }
      } else {
        Section {
          if navigationTagsExpanded {
            // 标签是跨内容的分类关键词：按引用数降序的药丸云，
            // 大类自然浮到最前。
            let ordered = model.navigationCounts.tags
              .filter { !Self.hiddenSidebarTagNames.contains($0.tag.normalizedName) }
              .sorted { $0.count > $1.count }
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
                  // 无描边的浅底胶囊：带边框的药丸在侧栏里像一排按钮，比左边的文字还重。
                  .background(
                    selected ? AnyShapeStyle(theme.selectionFill) : AnyShapeStyle(theme.primaryText.opacity(0.05)),
                    in: Capsule()
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
            // 两个动作放一行、用主题色和图标：原来两行灰字看起来像说明文字，不像能点（2026-09-24 走查）。
            HStack(spacing: DesignTokens.Space.sm) {
              if ordered.count > 6 {
                sidebarLinkAction(
                  model.showsAllNavigationTags ? "收起" : "显示全部 \(ordered.count) 个",
                  systemImage: model.showsAllNavigationTags ? "chevron.up" : "chevron.down"
                ) { model.showsAllNavigationTags.toggle() }
                  .accessibilityIdentifier("history-navigation-tags-all")
              }
              Spacer(minLength: 0)
              sidebarLinkAction("管理", systemImage: "slider.horizontal.3") { model.isTagManagerPresented = true }
                .help("改名、合并、删除标签")
                .accessibilityIdentifier("history-navigation-tags-manage")
            }
            if !model.selectedTagNormalizedNames.isEmpty {
              sidebarTextAction("清空标签筛选（\(model.selectedTagNormalizedNames.count)）") { model.clearTagSelection() }
                .accessibilityIdentifier("history-navigation-tags-clear")
            }
          }
        } header: {
          navigationSectionHeader("标签", expanded: $navigationTagsExpanded)
            .accessibilityIdentifier("history-navigation-tags-header")
        }
        .id("history-navigation-tags")
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
        // 和其它导航行同一个组件：原来手写，图标颜色、选中色（系统蓝）都和别的行不一样（2026-10-01 体检）。
        navigationButton(
          "工作台",
          systemImage: "hammer",
          count: { let active = model.pieces.filter { !$0.isFinished }.count; return active > 0 ? active : nil }(),
          selected: model.isWorkbenchActive
        ) { model.enterWorkbench() }
        .accessibilityIdentifier("history-navigation-workbench")
      }
      }

    }
    .listStyle(.sidebar)
    // 分组展开 / 收起时整张侧栏重建一次。macOS 侧栏 List 对「启动时为空的分组」
    // 后来插入的行不刷新显示（2026-09-23 实测：点开「视图」「来源平台」箭头转了、
    // 行却不出现）。侧栏只有几十行，重建没有可感的开销。
    .id(navigationSectionsLayoutKey)
    // 系统侧栏的默认最小行高会把 28pt 的行再撑高一截。
    .environment(\.defaultMinListRowHeight, 24)
    .scrollContentBackground(theme.isNative ? .automatic : .hidden)
    .background((theme.isNative ? Color.clear : theme.canvas).ignoresSafeArea(edges: .top))
    // 侧栏滚下去时，行会从红绿灯按钮底下穿过（2026-09-24 走查）。同一层渐隐。
    .overlay(alignment: .top) {
      if !theme.isNative { ToolbarScrollFade(background: theme.canvas) }
    }
    // 第一组没有标题后，「全部」会直接贴住工具栏下沿；补回标题原本占的余白。
    .contentMargins(.top, 8, for: .scrollContent)
    .contentMargins(.bottom, 20, for: .scrollContent)
    .safeAreaInset(edge: .bottom, spacing: 0) { navigationFooter }
    .accessibilityIdentifier("history-navigation-rail")
    // 只在启动时把「上次选中、但在侧栏下方看不到」的平台露出来一次。
    // 原来每次选中平台都 scrollTo(.center)，分组展开 / 收起重建侧栏时也会触发，
    // 结果是点哪一行、整列就跳到哪一行居中，侧栏像被钉在中间（2026-09-23 Syc 反馈）。
    // 用户自己点的行本来就在眼前，不需要滚。
    .onAppear {
      guard !didRevealInitialNavigationPlatform else { return }
      didRevealInitialNavigationPlatform = true
      if let target = navigationPlatformScrollTarget(model.selectedHosts) {
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
      }
    }
    }
    .frame(minHeight: 0, maxHeight: .infinity)
  }

  struct ThreeColumnWidths: Equatable {
    var sidebar: CGFloat
    var list: CGFloat

    static func stored(_ defaults: UserDefaults = .standard) -> Self {
      Self(
        sidebar: DesignTokens.Layout.storedSidebarWidth(defaults.double(forKey: DesignTokens.Layout.sidebarWidthStorageKey)),
        list: DesignTokens.Layout.storedListWidth(defaults.double(forKey: DesignTokens.Layout.listWidthStorageKey))
      )
    }
  }

  /// 侧栏标签云里不显示的标签：归属的两个保留标签（「自有」「外部」本身就是顶部入口）、
  /// 旧版「已使用 / 已归档」留下的标签（界面已撤，2026-09-24）；和来源平台重名的
  /// 标签（Twitter、YouTube…）只是重复平台信息。只在侧栏隐藏，标签本身不删。
  /// 素材类型（灵感、观点…）不再单独成组，就在标签云里按条数排。
  static let hiddenSidebarTagNames: Set<String> = MaterialCatalog.systemTagNormalizedNames.union(
    (["Twitter", "X", "YouTube", "GitHub", "抖音", "公众号", "微信公众号", "B站", "哔哩哔哩", "bilibili", "小红书", "Reddit", "Substack"])
      .compactMap { HistoryTagNormalizer.normalized($0)?.normalizedName }
  )

  /// 侧栏里的次要文字动作（「全部标签」「清空筛选」）：和「更多平台」同一种样子，不用系统按钮。
  private func sidebarTextAction(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .themedFont(.subheadline)
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignTokens.Space.xs)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// 侧栏里「能点的小动作」：主题色 + 图标，和灰色说明文字区分开。
  private func sidebarLinkAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.titleAndIcon)
        .themedFont(.subheadline)
        .foregroundStyle(theme.accent)
        .padding(.vertical, DesignTokens.Space.xs)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var navigationSectionsLayoutKey: String {
    [navigationViewsExpanded, navigationFormsExpanded,
     navigationCreatorsExpanded, navigationPlatformsExpanded, navigationTagsExpanded,
     navigationCollectionsExpanded, navigationStepStatusExpanded]
      .map { $0 ? "1" : "0" }.joined()
      // 合集从无到有（第一个合集建出来）时，分组里后插入的行同样不刷新，跟着重建一次。
      + "-\(model.collections.count)"
  }

  private func navigationPlatformScrollTarget(_ hosts: Set<String>) -> String? {
    guard !hosts.isEmpty else { return nil }
    let misc = Set(
      model.navigationCounts.platforms
        .filter { !HistoryPlatformDisplay.isWellKnown(host: $0.host) }
        .map(\.host)
    )
    if !misc.isEmpty, hosts == misc { return HistoryPlatformDisplay.miscHost }
    return hosts.count == 1 ? hosts.first : nil
  }

  /// All sections share the same title baseline; disclosure controls occupy a
  /// leading overlay so expandable groups do not indent their top-level rows.
  private func navigationSectionHeader(
    _ title: String,
    expanded: Binding<Bool>? = nil
  ) -> some View {
    // 四个分组标题一种写法：11pt 中等、次要灰、和图标左边缘对齐、不带折叠箭头
    // （点标题本身就能折叠）。原来「资料」「笔记」不带箭头、「博主」「来源平台」带，
    // 四个标题两种样子。
    HStack(spacing: 8) {
      if let expanded {
        Button {
          sidebarScrollMemory.remember(expanding: !expanded.wrappedValue)
          expanded.wrappedValue.toggle()
        } label: {
          // 2026-09-23：分组默认收起后必须看得出「能点开」，补一个转向的小箭头（对标应用同款）。
          HStack(spacing: 4) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
              .frame(width: 10)
            Text(title)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded.wrappedValue ? "点击折叠" : "点击展开")
        .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
      } else {
        // 不能折叠的标题也空出箭头那一格：空库时「标签」比「视图」「合集」往左凸出一截（2026-10-02 走查）。
        HStack(spacing: 4) {
          Color.clear.frame(width: 10, height: 1)
          Text(title)
        }
        Spacer(minLength: 0)
      }
    }
    .themedFont(.subheadline, weight: .medium)
    .foregroundStyle(theme.secondaryText)
    .padding(.leading, DesignTokens.Space.xs)
    .frame(height: 24)
    .textCase(nil)
  }

  /// 侧栏底部：设置。它是整个 App 的偶尔操作，不该和「当前这一条」的收藏、标签挤在顶栏。
  private var navigationFooter: some View {
    HStack(spacing: 8) {
      Button(action: { openSettings() }) {
        Label("设置", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
          .themedFont(.callout)
          .foregroundStyle(theme.secondaryText)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("打开设置")
      .accessibilityLabel("打开设置")
      .accessibilityIdentifier("open-provider-settings")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DesignTokens.Space.lg)
    .padding(.vertical, DesignTokens.Space.sm)
    .overlay(alignment: .top) {
      Rectangle().fill(theme.hairline).frame(height: 1)
    }
    // 系统主题原来是透明底，侧栏滚到底时最后几行从「设置」字底下透出来（2026-10-01 走查）。
    .background {
      if theme.isNative { Rectangle().fill(.bar) } else { theme.canvas }
    }
  }

  private func navigationButton(
    _ title: String,
    systemImage: String,
    seal: SealMark.Glyph? = nil,
    count: Int?,
    selected: Bool,
    emphasizesCount: Bool = false,
    titleLineLimit: Int = 2,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      // 进「全部博主」、来源卡片墙这类两栏页面时侧栏会换一张，先把位置定住（见 SidebarScrollMemory）。
      sidebarScrollMemory.snapshot()
      action()
    } label: {
      HStack(spacing: 8) {
        // 字体必须写在这里，不能靠窗口根部注入的环境字体。
        //
        // 这一行是 `List` 的行内容，而 macOS 的 List 是 NSTableView 支撑的：
        // 它会给行套上自己的字体，**盖过 `.environment(\.font,)`**。实测根部
        // 注入对详情列、工具栏、设置页都生效，唯独进不了 List 行——表现就是
        // 整扇窗都换了字体，只有侧栏这一列还是系统字体。
        //
        // 图标统一 14pt、medium 字重、单色：未选中次要灰，选中强调色。
        // 原来各符号按默认字重各画各的，粗细不一，是「像拼凑的」最直接来源。
        // 「自有 / 外部」用「作 / 汲」两方印的墨线稿（2026-09-28 自有风格），导航和
        // 列表、题跋里的印是同一套语言；其余一律线性图标，选中也不换实心。
        if let seal {
          // 选中时上朱：导航里唯一一处朱色，和列表的「作」、页头的主印连成一套（2026-09-29）。
          SealMark(glyph: seal, size: 16, color: selected ? SealMark.stampInk : theme.secondaryText, showsInnerFrame: false)
            .frame(width: 18)
        } else {
          Image(systemName: systemImage)
            // regular：线条细一档，和其余图标同一重量；比正文小一号，不压过字。
            .font(.system(size: DesignTokens.IconSize.sidebar, weight: .regular))
            .foregroundStyle(selected ? theme.accent : theme.secondaryText)
            .frame(width: 18)
        }
        Text(title)
          .themedFont(.body)
          .foregroundStyle(selected ? theme.accent : theme.primaryText)
          .lineLimit(titleLineLimit)
          // 一行时截中间：「汲作验收…0929」比「汲作验收素材…」更认得出是哪一个。
          .truncationMode(titleLineLimit == 1 ? .middle : .tail)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
        Spacer(minLength: DesignTokens.Space.xs)
        if let count {
          countBadge(count, selected: selected, emphasized: emphasizesCount)
        }
      }
      .frame(minHeight: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // 选中态只留浅色底一种提示。原来同时有左侧色条、浅底、加粗三种，一个就够。
    //
    // 上下 8pt、最小 28pt：之前是 3pt / 20pt，理由写的是「4pt 时侧栏每行比列表
    // 松一截」。但把两栏量到一起才看出方向反了——列表行是 padding 8pt、
    // minHeight 60pt，侧栏 22pt 只有它的三分之一，一直是侧栏更紧。
    //
    // 28pt 同时是 macOS Source List 的常规行高下限（系统在 28–32pt 之间）。
    // 行高不够时整列导航项会糊成一片，用户的说法是「挤」，但缺的不是留白总量，
    // 是每一行的呼吸空间。改完仍不到列表行的一半，不会反过来显得松。
    // 2026-09-23 对标收紧：上下 2pt、内容 20pt，加上侧栏自带的行距实测约 32pt，
    // 与「来源平台」行同高。原来 8pt / 28pt 让主导航每行约 52pt，是对标应用的两倍。
    .padding(.vertical, DesignTokens.Space.xxs)
    .padding(.horizontal, DesignTokens.Space.sm)
    .background(
      selected ? theme.accent.opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    )
    .foregroundStyle(theme.primaryText)
    .padding(.horizontal, -6)
    .fontWeight(selected ? .medium : .regular)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityValue(count.map(String.init) ?? "")
  }

  /// 图24 式计数徽章：灰底小胶囊；选中时反白依附在蓝色药丸上。
  ///
  /// 等宽数字：侧栏这排计数常驻可见，抓到新内容时会一起变。比例字体下
  /// 9→10 的宽度跳变会让整列胶囊宽窄不一地抽动一下，等宽把它压成
  /// 只有需要进位时才变宽。
  private func presentDouyinProfileImport(profileURL: String = "", autoStart: Bool = false) {
    douyinProfileImportRequest = autoStart
      ? .capture(profileURL: profileURL)
      : .blank()
  }

  @ViewBuilder
  private func browserProfileConflictButtons(incoming: XProfileCandidatesRequest?) -> some View {
    Button("保留当前勾选") { manualLink.cancelIncomingBrowserProfile() }
    Button("换成新主页", role: .destructive) {
      if let incoming { manualLink.replaceIncomingBrowserProfile(incoming) }
    }
  }

  private func captureNoticeBanner(_ notice: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "info.circle")
      Text(notice).themedFont(.caption)
      Spacer(minLength: 8)
      Button("知道了", action: manualLink.dismissCaptureNotice)
        .themedFont(.caption)
    }
    .foregroundStyle(theme.primaryText)
    .padding(8)
    .background(theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .accessibilityIdentifier("history-creator-association-notice")
  }

  /// 列表里的小节标题（「今天」「抓取队列」「主页抓取批次」）同一种写法：原来三种字号、
  /// 两种颜色、缩进差 4pt（2026-10-01 体检）。
  private func listSectionHeader(_ title: String) -> some View {
    Text(title)
      .themedFont(.subheadline, weight: .medium)
      .foregroundStyle(theme.secondaryText)
      .padding(.leading, DesignTokens.Space.xs)
      .accessibilityAddTraits(.isHeader)
  }

  private func isPinnedCreatorHighlighted(_ id: CreatorID) -> Bool {
    model.isCreatorDirectoryActive && !showsCreatorDirectoryCatalog && model.selectedCreatorID == id
  }

  private func creatorPinRow(_ creator: CreatorSummary) -> some View {
    // 和「全部博主」里点同一位走同一条路：进这位博主的作品页。原来侧栏置顶行是
    // 「三栏列表 + 按博主筛选」，同一个博主两处点进去长得完全不一样（2026-10-01 体检）。
    Button {
      showsCreatorDirectoryCatalog = false
      creatorDirectoryScrollTarget = nil
      creatorWorkScrollTarget = nil
      model.focusCreatorInDirectory(creator.id)
    } label: {
      HStack(spacing: 8) {
        CreatorDirectoryAvatar(creator: creator, size: 22, theme: theme)
        VStack(alignment: .leading, spacing: 1) {
          Text(creator.directoryDisplayName)
            .themedFont(.body)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
          HStack(spacing: 4) {
            Text(HistoryPlatformDisplay.name(forHost: creator.identity.platform))
              .font(.caption2)
              .foregroundStyle(theme.secondaryText)
            Text("\(creator.savedWorkCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(theme.secondaryText)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isPinnedCreatorHighlighted(creator.id) ? theme.accent.opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    )
    .accessibilityIdentifier("history-navigation-creator-\(creator.id.rawValue)")
    .contextMenu {
      Button("抓取作品") {
        presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
      }
      .disabled(ProfileImportPlatform.parse(creator.profileURL) == nil)
      Button("取消置顶") { model.setCreatorPinned(creator.id, pinned: false) }
      Divider()
      Button("删除博主", role: .destructive) { requestCreatorDeletion(creator) }
    }
  }

  private var creatorDirectory: some View {
    VStack(spacing: 0) {
      // 页头和设置页同一套写法：淡底图标 + 页名 + 一句概览，右端一个动作按钮。
      // 原来只有一行「全部博主 · 5 位」，和下面的分组标题没有层次差。
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
        SettingsSidebarChip(
          symbol: "person.2",
          fill: theme.accent,
          edge: DesignTokens.IconSize.empty,
          showsBackground: true
        )
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          Text("全部博主")
            // 和设置页页头、平台图库标题同一条：写死 18pt 时放大界面字号后
            // 正文涨了、页头没涨，标题反而比它下面的说明还小。
            .themedFont(.title3, weight: .semibold)
            .foregroundStyle(theme.primaryText)
            .accessibilityIdentifier("history-creator-directory-title")
          Text(CreatorDirectoryChrome.overview(
            creatorCount: model.navigationCounts.creatorCount,
            loaded: model.creatorDirectoryRows
          ))
            .themedFont(.callout)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .accessibilityIdentifier("history-creator-directory-overview")
        }
        Spacer(minLength: 0)
        Button {
          presentDouyinProfileImport()
        } label: {
          Label("添加博主", systemImage: "person.crop.circle.badge.plus")
        }
        .help("粘贴抖音、小红书、X 或 B 站博主主页。")
        .accessibilityIdentifier("history-navigation-creator-add")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.top, 12)
      ThemedSearchField("搜索博主名称、主页或作者 ID", text: $model.creatorSearchText)
      .padding(.horizontal, DesignTokens.Layout.columnInset).padding(.top, 5).padding(.bottom, 10)
      .accessibilityIdentifier("history-creator-search")
      if let notice = manualLink.captureNotice {
        captureNoticeBanner(notice)
      }
      if let failure = model.creatorFailure {
        HStack {
          Label(failure, systemImage: "exclamationmark.triangle")
            .themedFont(.caption)
            .foregroundStyle(theme.danger)
          Spacer()
          Button("知道了", action: model.dismissCreatorFailure)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
      }
      if model.showsCreatorDirectoryFailure {
        HistoryInlineState(
          symbol: "exclamationmark.triangle",
          title: "无法载入博主列表",
          message: model.creatorFailure ?? "请稍后重试。",
          actionTitle: "重试",
          action: { model.reloadCreators() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-creator-directory-failed")
      } else if model.showsCreatorNeverAddedEmpty {
        HistoryInlineState(
          symbol: "person.2",
          title: "还没有添加博主",
          message: "点加号粘贴抖音、小红书、X 或 B 站主页，选择要保存的作品。",
          actionTitle: "添加博主",
          action: { presentDouyinProfileImport() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-creator-directory-empty")
      } else if model.showsCreatorNoMatchEmpty {
        HistoryInlineState(
          symbol: "line.3.horizontal.decrease.circle",
          title: "没有符合的博主",
          message: "换个名称、主页或作者 ID 再搜。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-creator-directory-filtered-empty")
      } else {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                ForEach(CreatorDirectoryPlatformGroup.groups(from: model.creatorDirectoryRows)) { group in
                  CreatorDirectoryPlatformSection(
                    platform: group.id,
                    count: group.creators.count,
                    theme: theme,
                    isExpanded: Binding(
                      get: { !collapsedCreatorPlatforms.contains(group.id) },
                      set: { expanded in
                        if expanded { collapsedCreatorPlatforms.remove(group.id) }
                        else { collapsedCreatorPlatforms.insert(group.id) }
                      }
                    )
                  ) {
                    // 自适应列数、横排小卡：原来固定两列、竖排大卡，右边空一整列。
                    LazyVGrid(
                      columns: [GridItem(.adaptive(minimum: CreatorDirectoryChrome.xCardMinimumWidth), spacing: CreatorDirectoryChrome.xGridSpacing, alignment: .top)],
                      spacing: CreatorDirectoryChrome.xGridSpacing
                    ) {
                      ForEach(group.creators) { creator in
                        creatorDirectoryRow(creator)
                          .id(creator.id)
                      }
                    }
                  }
                }
              }
              // Pagination must not depend on a card hidden by a collapsed group,
              // or on the old last row's position after platform regrouping.
              Color.clear.frame(height: 1)
                .id(model.creatorDirectoryRows.last?.id)
                .onAppear {
                  if let last = model.creatorDirectoryRows.last {
                    model.loadNextCreatorPageIfNeeded(after: last)
                  }
                }
              if model.isLoadingCreatorPage {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                  .padding(.vertical, 8)
              }
            }
            .padding(12)
            .onAppear { restoreCreatorDirectoryScroll(using: proxy) }
            .onChange(of: creatorDirectoryScrollTarget) { _, _ in
              restoreCreatorDirectoryScroll(using: proxy)
            }
            .onChange(of: model.creatorSearchText) { _, _ in
              collapsedCreatorPlatforms.removeAll()
            }
          }
        }
        .accessibilityIdentifier("history-creator-directory")
      }
    }
    .frame(maxWidth: .infinity)
    // 和内容列表同一档纸面色，见 `sidebar` 的说明。
    .background(theme.card.opacity(theme.isNative ? 0 : 1).ignoresSafeArea(edges: .top))
  }

  private func creatorDirectoryRow(_ creator: CreatorSummary) -> some View {
    let canCapture = ProfileImportPlatform.parse(creator.profileURL) != nil
    return Button {
      showsCreatorDirectoryCatalog = false
      creatorDirectoryScrollTarget = nil
      creatorWorkScrollTarget = nil
      model.focusCreatorInDirectory(creator.id)
    } label: {
      CreatorDirectoryCard(
        creator: creator,
        theme: theme,
        isSelected: model.selectedCreatorID == creator.id,
        onRetryAvatar: { presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true) }
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("history-creator-select-\(creator.id.rawValue)")
    .contextMenu {
      Button("更新资料") {
        presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
      }
      .disabled(!canCapture)
      .accessibilityIdentifier("history-creator-refresh-\(creator.id.rawValue)")
      Button(creator.isPinned ? "取消置顶" : "置顶到侧栏") {
        model.setCreatorPinned(creator.id, pinned: !creator.isPinned)
      }
      .accessibilityIdentifier("history-creator-pin-\(creator.id.rawValue)")
      Divider()
      Button("删除博主", role: .destructive) { requestCreatorDeletion(creator) }
        .accessibilityIdentifier("history-creator-delete-\(creator.id.rawValue)")
    }
  }

  private func requestCreatorDeletion(_ creator: CreatorSummary) {
    if creator.savedWorkCount == 0 {
      model.deleteCreator(creator.id)
    } else {
      creatorPendingDeletion = creator
    }
  }

  private func creatorDirectoryGridColumns(availableWidth: CGFloat) -> [GridItem] {
    let count = CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)
    return Array(
      repeating: GridItem(.flexible(minimum: 0), spacing: CreatorDirectoryChrome.xGridSpacing, alignment: .top),
      count: count
    )
  }

  private func restoreCreatorDirectoryScroll(using proxy: ScrollViewProxy) {
    guard let creatorID = creatorDirectoryScrollTarget else { return }
    DispatchQueue.main.async {
      withAnimation(historyUIAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
        proxy.scrollTo(creatorID, anchor: .center)
      }
      creatorDirectoryScrollTarget = nil
    }
  }

  private func creatorDirectorySubtitle(_ creator: CreatorSummary) -> String {
    var parts = [
      HistoryPlatformDisplay.name(forHost: creator.identity.platform),
      "已保存 \(creator.savedWorkCount) 条",
    ]
    if creator.isPinned { parts.append("已置顶") }
    return parts.joined(separator: " · ")
  }

  /// 计数只是一个数字，用次要灰的等宽数字直接右对齐；不再套灰底胶囊——
  /// 一整列胶囊比左边的文字还重，看起来像一排按钮。只有需要提醒的那一项
  /// （待总结）保留一个浅色胶囊。
  /// 选中项的计数反白成主题色小胶囊（对标应用的做法），一眼能看出「当前在哪、有几条」；
  /// 其余仍是不带底色的灰数字，整列不会变成一排按钮。
  private func countBadge(_ count: Int, selected: Bool, emphasized: Bool = false) -> some View {
    // 2026-09-28 自有风格：选中项不再反白成蓝色胶囊（那是对标应用的画法），
    // 只把数字换成靛青、中等字重；需要提醒的计数仍留一层极淡的底。
    Text("\(count)")
      .themedFont(.subheadline, weight: selected ? .medium : .regular, monospacedDigit: true)
      .foregroundStyle(selected ? theme.accent : theme.secondaryText)
      .padding(.horizontal, 6)
      .padding(.vertical, emphasized ? 1 : 0)
      .background(emphasized ? theme.accent.opacity(0.12) : Color.clear, in: Capsule())
  }

  private var listSearchPlaceholder: String {
    if model.selectedCollection != nil {
      return "在这个合集里搜标题、正文、总结、标签"
    }
    if model.selectedCreator != nil {
      return "搜索该博主的标题、正文、总结、标签"
    }
    switch model.selectedScope {
    case .notes: return "搜索笔记标题、正文、标签"
    case .unsummarized: return "搜索未总结的标题、正文、标签"
    case .untidied: return "搜索待校对的标题、正文、标签"
    case .untranscribed: return "搜索待转写的标题、正文、标签"
    case .favorite: return "搜索收藏的标题、正文、总结、标签"
    case .own: return "搜索自有内容的标题、正文、总结、标签"
    case .external: return "搜索外部内容的标题、正文、总结、标签"
    case .recent: return "搜索最近 7 天的标题、正文、总结、标签"
    case .works: return "搜索作品标题、正文、标签"
    case .drafts: return "搜索稿件标题、正文、标签"
    case .trash: return "搜索回收站里的标题、正文、标签"
    case .all: return "搜索标题、正文、总结、标签"
    }
  }

  private var hasClearableListFilters: Bool {
    !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || model.hasCategoryFilter
      || ([HistoryListScope.recent, .unsummarized, .untidied, .untranscribed, .favorite].contains(model.selectedScope) && !model.isCreatorDirectoryActive)
  }

  private var listScopeFilterTitle: String? {
    guard !model.isCreatorDirectoryActive else { return nil }
    switch model.selectedScope {
    case .all: return nil
    case .recent: return "最近 7 天"
    case .unsummarized: return "未总结"
    case .untidied: return "待校对"
    case .untranscribed: return "待转写"
    case .favorite: return "收藏"
    // 自有、外部的名字已经写在列表标题上，不再重复成一个筛选胶囊。
    case .own, .external: return nil
    case .trash: return "回收站"
    case .notes, .drafts, .works: return nil
    }
  }

  /// 当前挂着几个筛选：搜索词、范围、博主、平台、标签各算一个。
  private var activeListFilterCount: Int {
    var count = 0
    if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
    if listScopeFilterTitle != nil { count += 1 }
    if model.selectedCreator != nil { count += 1 }
    if model.selectedForm != nil { count += 1 }
    if model.selectedCollection != nil { count += 1 }
    count += model.selectedHosts.count
    count += activeFilterTags.count
    return count
  }

  private func clearListFilters() {
    let scope = model.selectedScope
    model.searchText = ""
    // 在合集里只清搜索词，人还留在这个合集；要离开点侧栏或合集那枚筛选片的 ✕。
    if model.isBrowsingCollection { return }
    model.selectScope([HistoryListScope.notes, .drafts, .works, .own, .external].contains(scope) ? scope : .all)
  }

  private func removeHostFilter(_ host: String) {
    let remaining = model.selectedHosts.subtracting([host])
    if remaining.isEmpty { model.clearHostSelection() }
    else { model.selectHosts(Array(remaining)) }
  }

  /// 只挂着一个筛选、而且它的名字已经写在列表标题上（最近 7 天、收藏、某个形式 / 平台 / 博主）时，
  /// 不再在标题下重复一枚同名筛选片（2026-09-24 Syc 走查）。搜索词和标签不写进标题，照常显示。
  /// 要回到全部，点侧栏「全部」即可。
  private var isSingleFilterShownAsTitle: Bool {
    activeListFilterCount == 1
      && model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && activeFilterTags.isEmpty
  }

  private var activeFilterBar: some View {
    HStack(alignment: .center, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filterChip("“\(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”") {
              model.searchText = ""
            }
          }
          if let scopeTitle = listScopeFilterTitle {
            filterChip(scopeTitle) { model.selectScope(.all) }
          }
          if let form = model.selectedForm {
            filterChip(form.rawValue) { model.clearFormSelection() }
          }
          if let collection = model.selectedCollection {
            filterChip(collection.name) { model.selectScope(.all) }
          }
          if let creator = model.selectedCreator {
            filterChip(creator.listingTitle) { model.selectCreator(creator.id) }
          }
          ForEach(Array(model.selectedHosts).sorted(), id: \.self) { host in
            filterChip(HistoryPlatformDisplay.name(forHost: host)) { removeHostFilter(host) }
          }
          ForEach(activeFilterTags, id: \.normalizedName) { tag in
            filterChip(tag.name) { model.toggleTag(tag, additive: true) }
          }
        }
      }
      // 每个筛选片自带 ✕，右端再放一个「清除」是同一件事的第二个入口；
      // 只有同时挂着两个以上筛选时才值得一键全清。
      if activeListFilterCount > 1 {
        Button("清除") { clearListFilters() }
          .buttonStyle(.borderless)
          .themedFont(.caption, weight: .medium)
          .help("清除当前搜索和筛选")
          .accessibilityLabel("清除筛选")
          .accessibilityIdentifier("history-clear-filters")
      }
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .accessibilityIdentifier("history-active-filters")
  }

  private var activeFilterTags: [HistoryTag] {
    model.navigationCounts.tags
      .map(\.tag)
      .filter { model.selectedTagNormalizedNames.contains($0.normalizedName) }
  }

  private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
    Button(action: clear) {
      HStack(spacing: 4) {
        Text(title).lineLimit(1)
        Image(systemName: "xmark")
          .themedFont(.caption2, weight: .bold)
      }
      .themedFont(.caption)
      .padding(.vertical, 3)
      .padding(.horizontal, 8)
      .background(theme.primaryText.opacity(0.06), in: Capsule())
      .foregroundStyle(theme.primaryText)
    }
    .buttonStyle(.plain)
    .help("移除这个筛选")
    .accessibilityLabel("移除筛选 \(title)")
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

  /// Gallery cards keep the same context actions as the history list.
  @ViewBuilder private func historyContextMenu(for row: HistoryRowProjection) -> some View {
    if model.selectedScope == .trash {
      trashContextMenu(for: row)
    } else {
      regularHistoryContextMenu(for: row)
    }
  }

  @ViewBuilder private func trashContextMenu(for row: HistoryRowProjection) -> some View {
    Button {
      model.restoreFromTrash(taskIDs: [row.taskID])
    } label: {
      Label("恢复", systemImage: "arrow.uturn.backward")
    }
    .disabled(model.isReadOnly || model.isDeleting)
    .accessibilityIdentifier("history-context-restore")
    Section {
      Button(role: .destructive) {
        if !model.selectedTaskIDs.contains(row.taskID) {
          model.selectedTaskIDs = [row.taskID]
        }
        model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
      } label: {
        Label("彻底删除…", systemImage: "trash")
      }
      .disabled(model.isReadOnly || model.isDeleting)
      .foregroundStyle(theme.danger)
      .accessibilityIdentifier("history-context-purge")
    }
  }

  /// 素材类型与归属。勾选状态读列表行自带的标签名，不必先打开详情。
  @ViewBuilder private func materialContextMenu(for row: HistoryRowProjection) -> some View {
    let names = Set((row.tagNames ?? []).compactMap { HistoryTagNormalizer.normalized($0)?.normalizedName })
    Menu {
      ForEach(MaterialCatalog.MaterialType.allCases, id: \.self) { type in
        let normalized = HistoryTagNormalizer.normalized(type.tagName)?.normalizedName ?? type.tagName
        let isOn = names.contains(normalized)
        Button {
          model.toggleMaterialTag(type.tagName, on: row.taskID, isOn: !isOn)
        } label: {
          Label(type.tagName, systemImage: isOn ? "checkmark" : type.systemImage)
        }
      }
    } label: {
      Label("素材类型", systemImage: "square.grid.2x2")
    }
    .disabled(model.isReadOnly || model.isDeleting)
    .accessibilityIdentifier("history-context-material-type")
    ownershipButton(taskID: row.taskID, canonicalURL: row.canonicalURL, host: row.host, tagNames: row.tagNames ?? [])
  }

  /// 「改为自有 / 改为外部」：默认规则判错时的手动开关（`ContentOwnership`）。
  private func ownershipButton(taskID: TaskID, canonicalURL: String, host: String, tagNames: [String]) -> some View {
    OwnershipToggleButton(model: model, taskID: taskID, canonicalURL: canonicalURL, host: host, tagNames: tagNames)
  }

  @ViewBuilder private func regularHistoryContextMenu(for row: HistoryRowProjection) -> some View {
    // 笔记、本机导入没有网页可开（2026-09-24 走查：原来点了没反应）。
    if HistoryDetailView.isWebURL(row.canonicalURL) {
      Button { openHistoryURL(row.canonicalURL) } label: {
        Label("在浏览器中打开", systemImage: "safari")
      }
      Button { copyHistoryURL(row.canonicalURL) } label: {
        Label("复制链接", systemImage: "doc.on.doc")
      }
      Divider()
    }
    // 收藏、标签、总结原来只有详情页有：右键菜单能删掉一条内容，却不能给它
    // 加一个标签，这不是「精简」，是漏了。
    Button { model.toggleFavorite(taskID: row.taskID) } label: {
      Label(
        row.isFavorite == true ? "取消收藏" : "收藏",
        systemImage: row.isFavorite == true ? "star.slash" : "star"
      )
    }
    .disabled(model.isReadOnly || model.isDeleting)
    .accessibilityIdentifier("history-context-favorite")
    Menu {
      if model.availableTags.isEmpty {
        Text("还没有标签")
      } else {
        ForEach(model.availableTags) { tag in
          Button(tag.name) { model.addTag(tag.name, to: row.taskID) }
        }
        Divider()
      }
      Button { model.selectedTaskIDs = [row.taskID] } label: { Label("打开并新建标签…", systemImage: "plus") }
    } label: {
      Label("添加标签", systemImage: "tag")
    }
    .disabled(model.isReadOnly || model.isDeleting)
    .accessibilityIdentifier("history-context-add-tag")
    materialContextMenu(for: row)
    CollectionMenuItems(model: model, taskIDs: model.collectionTargets(for: row.taskID))
    Button { summarizeSingle(row) } label: {
      Label(row.hasSummary == true ? "重新生成总结" : "总结", systemImage: MenuIcon.summarize)
    }
    .disabled(singleSummaryUnavailableReason != nil)
    .help(singleSummaryUnavailableReason ?? "用本机已保存的正文生成总结")
    .accessibilityIdentifier("history-context-summarize")
    if model.selectedTaskIDs.contains(row.taskID), model.selectedTaskCount > 1 {
      Divider()
      Button { model.requestBatchSummary() } label: {
        Label("总结选中的 \(model.selectedTaskCount) 条…", systemImage: MenuIcon.summarize)
      }
      .disabled(!model.canBatchSummarize || !providerSettings.arePreferencesReady)
      .accessibilityIdentifier("batch-summarize-history-context")
      Button {
        model.requestBatchTranslation(outputLanguage: providerSettings.outputLanguage)
      } label: {
        Label("翻译选中的 \(model.selectedTaskCount) 条…", systemImage: MenuIcon.translate)
      }
      .disabled(!model.canBatchTranslate || !providerSettings.arePreferencesReady)
      .accessibilityIdentifier("batch-translate-history-context")
    }
    let unfinished = model.pieces.filter { !$0.isFinished }
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
    // 删除单独成节并染成危险色：它和上面那些「改一改还能改回来」的动作不是
    // 一类东西，紧挨着排等于把误点的代价压到 1 像素。
    Section {
      Button(role: .destructive) {
        if !model.selectedTaskIDs.contains(row.taskID) {
          model.selectedTaskIDs = [row.taskID]
        }
        model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
      } label: {
        Label("移到回收站…", systemImage: "trash")
      }
      .disabled(model.isReadOnly || model.isDeleting)
      .foregroundStyle(theme.danger)
      .accessibilityIdentifier("history-context-delete")
    }
  }

  /// 对单条内容跑总结：列表行内动作和右键菜单共用这一条路径。
  private func summarizeSingle(_ row: HistoryRowProjection) {
    guard singleSummaryUnavailableReason == nil else { return }
    Task {
      guard let target = model.detailProjection(for: row.taskID) else { return }
      await appModel.summarize(historyDetail: target, preferences: providerSettings.runPreferences)
    }
  }

  /// 不能总结时说清楚是哪一步没到位，别只把按钮灰掉。
  private var singleSummaryUnavailableReason: String? {
    if model.isReadOnly { return "这份历史当前只能浏览" }
    if !providerSettings.arePreferencesReady { return "正在读取模型设置，请稍候" }
    if !providerSettings.hasConfiguredAPIKey { return "还没配置模型，先去设置里填一个" }
    if appModel.runState.isActive { return "已有一次生成在跑，完成后再试" }
    return nil
  }

  /// 「待总结」列表顶部的一条横幅。
  ///
  /// 这张列表会一直涨，原因是自动总结默认关着——可那个开关在设置里隔着两级
  /// 导航，没人会把两件事联系起来。横幅把原因和一个当场能用的动作，放在它
  /// 造成的后果旁边。
  private var unsummarizedBulkCandidates: [TaskID] {
    Array(model.rows.prefix(20)).map(\.taskID)
  }

  /// 「待转写」列表顶上：一共多少条、多长，一键全部排队本机转写。
  @ViewBuilder private var untranscribedBulkBanner: some View {
    let count = model.navigationCounts.untranscribed - model.navigationCounts.untranscribedFailed
    let failed = model.navigationCounts.untranscribedFailed
    let isRunning = localImport.isTranscriptionQueueRunning
    // 列表这一栏很窄：数字和按钮占第一行，说明另起一行，不和按钮挤在同一排。
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: DesignTokens.Space.xs) {
        Image(systemName: "waveform")
          .foregroundStyle(theme.info)
          .accessibilityHidden(true)
        Text(untranscribedSummaryText(count: count))
          .themedFont(.caption, weight: .semibold)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: DesignTokens.Space.xs)
        Button(isLoadingUntranscribedBacklog ? "正在清点…" : "全部转写…") {
          isLoadingUntranscribedBacklog = true
          Task {
            let items = await model.loadUntranscribedBacklog()
            isLoadingUntranscribedBacklog = false
            if let items, !items.isEmpty { untranscribedBacklogToConfirm = items }
          }
        }
        .buttonStyle(.borderless)
        .themedFont(.caption, weight: .medium)
        .fixedSize()
        .disabled(count <= 0 || isRunning || isLoadingUntranscribedBacklog || model.isReadOnly)
        .help(isRunning ? "已经在转写了，进度在窗口右下角" : "把这里的全部音视频排队转写；开始前会先确认条数和总时长")
        .accessibilityIdentifier("untranscribed-bulk-transcribe")
      }
      Text(untranscribedBannerDetail(isRunning: isRunning, failed: failed))
        .themedFont(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, DesignTokens.Space.sm)
    .padding(.vertical, DesignTokens.Space.sm)
    .background(theme.info.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("untranscribed-bulk-banner")
  }

  private func untranscribedBannerDetail(isRunning: Bool, failed: Int) -> String {
    let base = isRunning ? "正在排队转写，进度在窗口右下角，转好的会从这里消失。" : "本机听写，免费、不上传；一条一条转，随时可以停。"
    guard failed > 0 else { return base }
    return base + "另有 \(failed) 条上次没转成（多半没有中文人声），会跳过。"
  }

  private func untranscribedSummaryText(count: Int) -> String {
    let duration = Self.roughDuration(model.navigationCounts.untranscribedSeconds)
    return duration.map { "可转 \(count) 条 · 约 \($0)" } ?? "可转 \(count) 条"
  }

  private var untranscribedConfirmationMessage: String {
    let duration = Self.roughDuration(model.navigationCounts.untranscribedSeconds)
    let length = duration.map { "加起来约 \($0)。" } ?? ""
    return "\(length)用本机听写逐条转写，免费、不上传，不会自动总结。时长越长越久，期间电脑会比较忙；可以随时在窗口右下角停止，已经转好的会留着。"
  }

  /// 「约 56 小时」「约 40 分钟」；没有时长时返回 nil。
  static func roughDuration(_ seconds: Double) -> String? {
    guard seconds >= 60 else { return nil }
    let hours = seconds / 3600
    if hours >= 1 { return "\(Int(hours.rounded())) 小时" }
    return "\(Int((seconds / 60).rounded())) 分钟"
  }

  @ViewBuilder private var unsummarizedAutoSummaryBanner: some View {
    let count = unsummarizedBulkCandidates.count
    // 上下排：说明一段、按钮一行。原来左右并排，列表列只有两百多点宽，
    // 说明被挤成五六行、按钮被截成「总结前 20 条…」的半截（2026-10-01 走查）。
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xs) {
        Image(systemName: "sparkles")
          .foregroundStyle(theme.info)
          .accessibilityHidden(true)
        Text("自动总结当前已关闭")
          .themedFont(.caption, weight: .semibold)
      }
      Text("新抓到的内容不会自动生成总结，会一直留在这张列表里。")
        .themedFont(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("总结前 \(count) 条…") {
        model.requestBatchSummary(
          taskIDs: unsummarizedBulkCandidates,
          modelName: providerSettings.activeSummaryModelName
        )
      }
      .buttonStyle(.borderless)
      .themedFont(.caption, weight: .medium)
      // 主题色：单独一行的黑字看着像说明的最后一句，不像能点（2026-10-01 自查）。
      .foregroundStyle(theme.accent)
      .disabled(count == 0 || !model.canRunBatchSummary || !providerSettings.arePreferencesReady)
      .help(singleSummaryUnavailableReason ?? "按列表顺序逐条生成总结；开始前会先确认条数、模型和用量")
      .accessibilityIdentifier("unsummarized-bulk-summarize")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, DesignTokens.Space.sm)
    .padding(.vertical, DesignTokens.Space.sm)
    .background(theme.info.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("unsummarized-auto-summary-banner")
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
    } else if model.isCreatorDirectoryActive {
      creatorDirectoryDetail
    } else {
      detail
    }
  }

  /// 工作台里没选中任何一件时的右侧。
  private var workbenchPlaceholder: some View {
    Group {
      if model.pieces.isEmpty {
        HistoryInlineState(
          symbol: "hammer",
          title: "还没有在做的创作",
          message: "一个念头写下来就是一件创作。",
          actionTitle: "记一个新灵感",
          action: { isNewSparkPresented = true }
        )
      } else {
        HistoryInlineState(
          symbol: "hammer",
          title: "从左边选一件",
          message: "打开后能看到它攒了哪些素材、稿子写到哪了。"
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var creatorDirectoryDetail: some View {
    if model.showsCreatorNeverAddedEmpty {
      creatorDirectoryPlaceholder
    } else if model.showsCreatorDirectoryFailure {
      HistoryInlineState(
        symbol: "exclamationmark.triangle",
        title: "无法载入博主列表",
        message: model.creatorFailure ?? "请稍后重试。",
        actionTitle: "重试",
        action: { model.reloadCreators() }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.showsCreatorNoMatchEmpty {
      HistoryInlineState(
        symbol: "line.3.horizontal.decrease.circle",
        title: "没有符合的博主",
        message: "换个名称、主页或作者 ID 再搜。"
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("history-creator-directory-detail-empty")
    } else if model.isReadingCreatorWorkInDirectory {
      creatorDirectoryReader
    } else if let creator = model.selectedCreator {
      creatorDirectoryWorks(creator)
    } else if model.isLoadingCreatorPage {
      InlineLoadingLabel("正在载入博主…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      creatorDirectoryPlaceholder
    }
  }

  @ViewBuilder private var creatorDirectorySurface: some View {
    switch CreatorDirectorySurfaceState.resolve(
      showsCatalog: showsCreatorDirectoryCatalog,
      hasSelectedCreator: model.selectedCreator != nil,
      isReading: model.isReadingCreatorWorkInDirectory
    ) {
    case .catalog:
      creatorDirectory
    case .works:
      creatorDirectoryDetail
    case .reader:
      creatorDirectoryReader
    }
  }

  /// 读一条作品：和主阅读区同一张纸面。
  ///
  /// 原来顶上单独一行挂着「抓取作品」，看着像从工具栏掉下来的按钮；读一条作品时
  /// 它也不是要做的事——作品墙那一层（左上角返回一步）就有。底色原来是画布灰，
  /// 和主阅读区的白纸面不像同一个 App（2026-10-01 走查）。
  private var creatorDirectoryReader: some View {
    detailStateContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background((theme.isNative ? Color(nsColor: .textBackgroundColor) : theme.card).ignoresSafeArea(edges: .top))
  }

  private func creatorDirectoryWorks(_ creator: CreatorSummary) -> some View {
    let canCapture = ProfileImportPlatform.parse(creator.profileURL) != nil
    let batches = manualLink.profileImportBatches.filter { $0.creatorID == creator.id }
    return VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 10) {
        CreatorDirectoryAvatar(creator: creator, size: 36, theme: theme) {
          presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(creator.directoryDisplayName)
            .themedFont(.headline)
            .foregroundStyle(theme.primaryText)
            .lineLimit(2)
          // 「互动数据是保存时的数字」并进这一行：原来单独一行顶格在头像下面，
          // 和名字不在一条线上（2026-10-01 走查）。公众号没有互动数据，不写。
          Text(HistoryPlatformRegistry.canonicalHost(for: creator.identity.platform) == "mp.weixin.qq.com"
            ? creatorDirectorySubtitle(creator)
            : "\(creatorDirectorySubtitle(creator)) · 互动数据是保存时的数字")
            .themedFont(.caption)
            .foregroundStyle(theme.secondaryText)
        }
        .layoutPriority(1)
        Spacer(minLength: 8)
        Button("更新资料") {
          presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
        }
        .buttonStyle(.appQuiet)
        .disabled(!canCapture)
        .help("只刷新姓名和头像，不必保存新作品")
        .accessibilityIdentifier("history-creator-refresh-selected")
        // 一主一次：抓取作品是这一页的主动作。
        Button("抓取作品") {
          presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true)
        }
        .buttonStyle(.appProminent(theme.accent))
        .disabled(!canCapture)
        .help(canCapture ? "打开主页并选择作品" : "暂不支持此平台主页")
        .accessibilityIdentifier("history-creator-capture-selected")
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)
      .padding(.bottom, 8)
      if !batches.isEmpty {
        creatorWorksGridSurface(creator: creator, batches: batches, scrollTarget: $creatorWorkScrollTarget)
      } else {
        switch model.listState {
      case .idle where model.rows.isEmpty, .loading where model.rows.isEmpty:
        InlineLoadingLabel("正在载入作品…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed where model.rows.isEmpty:
        HistoryInlineState(
          symbol: "exclamationmark.triangle",
          title: "无法载入作品",
          message: "请稍后重试。",
          actionTitle: "重试",
          action: { model.retryList() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-list-failed")
      case .empty:
        HistoryInlineState(
          symbol: "tray",
          title: "尚未保存作品",
          message: "打开主页后勾选要保存的内容。",
          actionTitle: "抓取作品",
          action: { presentDouyinProfileImport(profileURL: creator.profileURL, autoStart: true) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-creator-directory-works-empty")
      default:
        creatorWorksGridSurface(creator: creator, batches: [], scrollTarget: $creatorWorkScrollTarget)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.card.opacity(theme.isNative ? 0 : 1))
  }

  private func creatorWorksGridSurface(
    creator: CreatorSummary,
    batches: [ProfileImportBatch],
    scrollTarget: Binding<TaskID?>
  ) -> some View {
    GeometryReader { geometry in
      let columns = creatorWorksGridColumns(for: creator, availableWidth: geometry.size.width)
      // `uniqueKeysWithValues` 遇到重复 taskID 会直接崩。分页边界上同一条
      // 出现两次是可能的（批次完成后行会被重新插入），保留后到的那份即可。
      let savedRows = Dictionary(model.rows.map { ($0.taskID, $0) }, uniquingKeysWith: { _, new in new })
      let reservedTaskIDs = Set(batches.filter { !$0.isCollapsed }.flatMap { batch in
        batch.items.compactMap { item -> TaskID? in
          if case let .completed(taskID) = item.phase { return taskID }
          return nil
        }
      })
      // 「高赞」只和这位博主自己的作品比：大 V 和小博主各用各的尺子。
      let likesThreshold = CreatorWorkHighlight.likesThreshold(
        model.rows.map(\.likes) + batches.flatMap { batch in
          batch.items.compactMap { item -> String? in
            if case let .completed(id) = item.phase, savedRows[id] != nil { return nil }
            return item.seed.likes
          }
        }
      )
      let entries = creatorWorkEntries(batches: batches, savedRows: savedRows, reservedTaskIDs: reservedTaskIDs)
      let columnCount = columns.count
      let columnWidth = max(1, (geometry.size.width - 24 - CGFloat(columnCount - 1) * CreatorDirectoryChrome.xGridSpacing) / CGFloat(columnCount))
      let masonryKey = "\(creator.id.rawValue)|\(creatorWorkSort.rawValue)|\(columnCount)|\(Int(columnWidth))"
      let masonryIDs = entries.map(\.id)
      // 读这个状态让量完高度后重排一次；真实高度本身放在不触发重算的暂存处。
      let _ = creatorMasonryMeasuredRevision
      // 卡片高度只跟列宽有关：换排序、换博主都不该清空已量好的高度，
      // 否则位置和高度都没变的卡不会再上报，永远凑不齐「全部量完」。
      let heightKey = "\(Int(columnWidth))"
      let measured = creatorMasonryHeightBox.key == heightKey ? creatorMasonryHeightBox.heights : [:]
      let masonryHeights = entries.map {
        measured[$0.id] ?? CreatorWorkMasonry.estimatedHeight(
          text: $0.estimateText(savedRows: savedRows),
          hasHeading: $0.estimateHasHeading(savedRows: savedRows),
          hasCover: $0.estimateHasCover,
          columnWidth: columnWidth
        )
      }
      let allMeasured = masonryIDs.allSatisfy { measured[$0] != nil }
      let masonryIndices = CreatorWorkMasonry.columns(
        ids: masonryIDs,
        heights: masonryHeights,
        count: columnCount,
        pinned: creatorMasonryPinsKey == masonryKey ? creatorMasonryPins : [:]
      )
      // 作品不多时先把已保存的作品全部读进来，再钉住分列：否则滑动途中翻页，
      // 预留卡换成已保存卡（多出中文标题、换成原文），已钉住的列就高矮失衡。
      let loadsAllWorksFirst = model.hasMoreListPages && model.rows.count < Self.creatorMasonryEagerLoadLimit
      // 作品不多时整列一次性画出来（不用懒加载），每张卡都能量到真实高度。
      let measuresAllCards = entries.count <= Self.creatorMasonryEagerLoadLimit
      let masonryColumns = masonryIndices.map { $0.map { entries[$0] } }
      // 把这次的分列记下来：之后同一张卡永远留在这一列。
      let masonrySignature = "\(masonryKey)#\(masonryIDs.count)#\(masonryIDs.last.map { "\($0)" } ?? "")"
      ScrollViewReader { batchScroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(batches) { batch in
              ProfileImportBatchHeader(batch: batch, manualLink: manualLink)
            }
            // 瀑布流：每列一个 LazyVStack，各自往下排。见 CreatorWorkMasonry。
            HStack(alignment: .top, spacing: CreatorDirectoryChrome.xGridSpacing) {
              ForEach(Array(masonryColumns.enumerated()), id: \.offset) { _, column in
                Group {
                  if measuresAllCards {
                    VStack(spacing: CreatorDirectoryChrome.xGridSpacing) {
                      ForEach(column, id: \.id) { entry in
                        creatorWorkMasonryCard(entry, savedRows: savedRows, likesThreshold: likesThreshold)
                          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            creatorMasonryHeightBox.record(height, for: entry.id, key: heightKey) {
                              creatorMasonryMeasuredRevision += 1
                            }
                          }
                      }
                    }
                  } else {
                    LazyVStack(spacing: CreatorDirectoryChrome.xGridSpacing) {
                      ForEach(column, id: \.id) { entry in
                        creatorWorkMasonryCard(entry, savedRows: savedRows, likesThreshold: likesThreshold)
                      }
                    }
                  }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
              }
            }
            // A completed batch can own rows.last and remove its saved card.
            // This lazy footer still advances pagination at the visual end.
            if let last = model.rows.last {
              Color.clear.frame(height: 1)
                .id("creator-pagination-\(last.taskID.rawValue)")
                .onAppear { model.loadNextPageIfNeeded(after: last) }
            }
          }
          .padding(12)
        }
        .onAppear {
          scrollToProfileImportTarget(using: batchScroll)
          restoreCreatorWorkScroll(using: batchScroll, target: scrollTarget)
        }
        .task(id: "\(masonrySignature)#\(model.rows.count)#\(model.hasMoreListPages)#\(allMeasured)#\(creatorMasonryMeasuredRevision)") {
          if loadsAllWorksFirst, let last = model.rows.last {
            model.loadNextPageIfNeeded(after: last)
            return
          }
          // 能量的都量完了再钉：按真实高度分好一次，之后不再换列。
          if measuresAllCards, !allMeasured { return }
          var pins = creatorMasonryPinsKey == masonryKey ? creatorMasonryPins : [:]
          for (column, indices) in masonryIndices.enumerated() {
            for index in indices where pins[masonryIDs[index]] == nil {
              pins[masonryIDs[index]] = column
            }
          }
          creatorMasonryPins = pins
          creatorMasonryPinsKey = masonryKey
        }
        .onChange(of: model.profileImportScrollTarget) { _, _ in
          scrollToProfileImportTarget(using: batchScroll)
        }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      // 「各组内仅排序已加载作品」是实现细节，收进下拉的悬停提示；这一行不再铺深色底。
      HStack {
        Spacer()
        // 默认那一档在博主页的真实含义（2026-10-01 核对 creatorWorkEntries）：已存的作品按
        // 存进来的先后、新的在前（列表 ordersBySavedTime）；本次正在抓的那批仍按主页上的顺序。
        // 原名「发现顺序」说不清是谁发现的，这里叫「保存顺序」。
        Picker("排序", selection: $creatorWorkSort) {
          ForEach(WorkSortOrder.allCases) { Text($0 == .original ? "保存顺序" : $0.title).tag($0) }
        }
        .frame(width: 220)
        .accessibilityIdentifier("creator-work-sort")
        .help("「保存顺序」：已存的作品按存进来的先后，新的在前；本次抓取的按主页上的顺序。只排序已加载的作品，缺失值排最后。")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(theme.card)
    }
    .accessibilityIdentifier("history-creator-directory-works")
  }

  /// 已保存作品少于这个数时，打开博主页就一次读完再排瀑布流。
  static let creatorMasonryEagerLoadLimit = 400

  /// 作品页里的一张卡：抓取批次里的一项，或已保存的作品。
  private enum CreatorWorkEntry {
    case batch(batchID: UUID, item: ProfileImportBatchItem)
    case saved(HistoryRowProjection)

    var id: AnyHashable {
      switch self {
      case let .batch(_, item): AnyHashable(item.id)
      case let .saved(row): AnyHashable(row.taskID)
      }
    }

    /// 分列估高用卡片「最终会显示」的内容：已经保存且行已加载时按已保存卡估。
    /// 估高后来变了也没关系——第一次分好的列会被钉住，见 creatorMasonryPins。
    func estimateText(savedRows: [TaskID: HistoryRowProjection]) -> String? {
      switch self {
      case let .batch(_, item):
        if case let .completed(id) = item.phase, let row = savedRows[id] { return row.sourcePreview }
        return item.seed.previewText
      case let .saved(row): return row.sourcePreview
      }
    }

    func estimateHasHeading(savedRows: [TaskID: HistoryRowProjection]) -> Bool {
      let row: HistoryRowProjection?
      switch self {
      case let .batch(_, item):
        if case let .completed(id) = item.phase { row = savedRows[id] } else { row = nil }
      case let .saved(saved): row = saved
      }
      guard let row else { return false }
      return CapturedContentNaming.name(
        title: row.title, body: row.sourcePreview, host: row.host,
        author: row.author, published: row.published
      ).origin == .sourceTitle
    }

    var estimateHasCover: Bool {
      switch self {
      case let .batch(_, item): item.seed.coverURL?.isEmpty == false
      case let .saved(row): row.coverURL?.isEmpty == false || row.hasMedia == true
      }
    }
  }

  private func creatorWorkEntries(
    batches: [ProfileImportBatch],
    savedRows: [TaskID: HistoryRowProjection],
    reservedTaskIDs: Set<TaskID>
  ) -> [CreatorWorkEntry] {
    var entries: [CreatorWorkEntry] = []
    for batch in batches where !batch.isCollapsed {
      let sorted = creatorWorkSort.sorted(batch.items, likes: { item in
        if case let .completed(id) = item.phase { return savedRows[id]?.likes ?? item.seed.likes }
        return item.seed.likes
      }, published: { item in
        if case let .completed(id) = item.phase { return savedRows[id]?.published ?? item.seed.publishedText }
        return item.seed.publishedText
      }, referenceDate: creatorSortReferenceDate)
      entries += sorted.map { .batch(batchID: batch.id, item: $0) }
    }
    entries += creatorWorkSort.sorted(
      model.rows.filter { !reservedTaskIDs.contains($0.taskID) },
      likes: { $0.likes }, published: { $0.published }
    ).map { .saved($0) }
    return entries
  }

  @ViewBuilder
  private func creatorWorkMasonryCard(
    _ entry: CreatorWorkEntry,
    savedRows: [TaskID: HistoryRowProjection],
    likesThreshold: Double?
  ) -> some View {
    switch entry {
    case let .batch(batchID, item):
      ProfileImportBatchWorkCard(
        batchID: batchID,
        item: item,
        savedRows: savedRows,
        isHighlighted: CreatorWorkHighlight.isHighlighted({
          if case let .completed(id) = item.phase { return savedRows[id]?.likes ?? item.seed.likes }
          return item.seed.likes
        }(), threshold: likesThreshold),
        localCover: { taskID, coverURL in
          await model.localCoverURL(for: taskID, matching: coverURL)
        },
        manualLink: manualLink,
        historyModel: model
      )
      .id(item.id)
    case let .saved(row):
      CreatorWorkHoverSelection(alwaysVisible: !model.selectedTaskIDs.isEmpty) {
        Button {
          model.selectedTaskID = row.taskID
        } label: {
          CreatorSavedWorkCard(
            row: row,
            theme: theme,
            localCover: { await model.localCoverURL(for: row.taskID, matching: $0) },
            showsAuthor: false,
            isHighlighted: CreatorWorkHighlight.isHighlighted(row.likes, threshold: likesThreshold)
          )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityHint("打开作品")
        .contextMenu { DeferredMenuContent { historyContextMenu(for: row) } }
      } control: {
        CreatorWorkSelectionControl(
          isSelected: model.selectedTaskIDs.contains(row.taskID), theme: theme
        ) { model.toggleGallerySelection(row.taskID) }
        .accessibilityIdentifier("history-work-select-\(row.taskID.rawValue)")
        .padding(6)
      }
      .accessibilityIdentifier("history-creator-work-card-\(row.taskID.rawValue)")
      .id(row.taskID)
    }
  }

  private func scrollToProfileImportTarget(using proxy: ScrollViewProxy) {
    guard let target = model.profileImportScrollTarget else { return }
    withAnimation(historyUIAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
      proxy.scrollTo(target, anchor: .center)
    }
    model.consumeProfileImportScrollTarget()
  }

  private func restoreCreatorWorkScroll(using proxy: ScrollViewProxy, target: Binding<TaskID?>) {
    guard let taskID = target.wrappedValue else { return }
    DispatchQueue.main.async {
      withAnimation(historyUIAnimation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
        proxy.scrollTo(taskID, anchor: .center)
      }
      target.wrappedValue = nil
    }
  }

  private func returnToCreatorDirectory() {
    creatorDirectoryScrollTarget = model.selectedCreatorID
    showsCreatorDirectoryCatalog = true
    model.leaveCreatorWorkReading()
  }

  private func creatorWorksGridColumns(for creator: CreatorSummary, availableWidth: CGFloat) -> [GridItem] {
    if CreatorWorkMetricLayout.usesAdaptiveWorkGrid(creator.identity.platform) {
      let count = CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)
      return Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
        count: count
      )
    }
    return [
      GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
      GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
      GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
    ]
  }

  /// 目录还没选出有效博主时的右侧。
  private var creatorDirectoryPlaceholder: some View {
    Group {
      if model.showsCreatorNeverAddedEmpty {
        HistoryInlineState(
          symbol: "person.2",
          title: "还没有添加博主",
          message: "点加号粘贴抖音、小红书、X 或 B 站主页，选择要保存的作品。",
          actionTitle: "添加博主",
          action: { presentDouyinProfileImport() }
        )
        .accessibilityIdentifier("history-creator-directory-detail-add")
      } else {
        HistoryInlineState(
          symbol: "person.2",
          title: "从左边选择一位博主",
          message: "打开后能看到这位博主已保存的作品。"
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("history-creator-directory-detail-empty")
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
        .overlay(alignment: .top) { ToolbarScrollFade(background: theme.card) }
        .background(theme.card.ignoresSafeArea(edges: .top))
    }
  }

  @ViewBuilder private var detailStateContent: some View {
    if model.selectedTaskCount > 1 || model.isBatchSummarizing || model.isBatchTranslating {
      HistoryMultiSelectionPanel(
        model: model,
        providerSettings: providerSettings,
        protectedTaskIDs: protectedTaskIDs,
        theme: theme
      )
    } else if let detail = model.detail {
      articleDetail(detail: detail)
    } else {
      switch model.detailState {
    case .loading:
      // 载入中也要留住占位按钮：否则这一瞬间列表的「搜索」「＋」被挤到窗口最右边，
      // 详情一出来又跳回去（2026-10-01 走查，同 .idle 那段）。
      InlineLoadingLabel("正在载入详情…").frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PlaceholderDetailToolbar())
    case .failed:
      // 和列表、空状态同一个组件；原来只有一个三角和「重试」，不说为什么、还能做什么（2026-10-01 体检）。
      HistoryInlineState(
        symbol: "exclamationmark.triangle",
        title: "这条内容没能打开",
        message: "可能刚被移到回收站，或资料库暂时读不了。点「重试」再读一次；不行就在左边选别的一条。",
        actionTitle: "重试",
        action: model.retryDetail
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PlaceholderDetailToolbar())
    case .loaded:
      // 成功路径总是先写 detail 再翻 .loaded，走不到这里；只为 switch 穷尽。
      EmptyView()
    case .idle:
      Group {
        // 换来源时列表先清空再重载：这一瞬间没有选中项，但也不是「库是空的」。
        // 原来直接落到 emptyDetail，闪一下「还没有保存页面」（2026-09-25 走查）。
        if model.listState == .loading && model.rows.isEmpty {
          Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          emptyDetail
        }
      }
        // 没选中任何一条时，阅读区那几颗按钮（收藏、更多）整个消失，macOS 会把
        // 列表列头的搜索、「＋」挤到窗口最右边（2026-09-24 走查）。留灰着的占位，
        // 工具栏布局就和选中时一致；灰着也如实说明「现在没东西可操作」。
        // 选中时的标签按钮 2026-10-01 撤掉了，这里跟着去掉，两种状态的图标一一对应。
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            Button {} label: { Label("收藏", systemImage: "star") }.disabled(true)
            Button {} label: { Label("更多", systemImage: "ellipsis") }.disabled(true)
          }
        }
      }
    }
  }

  /// 有正文时的详情列内容。载入下一条时这里仍然走同一个分支，SwiftUI 就能
  /// 原地更新这棵详情树；中间插一屏转圈会让它先整棵拆掉、再整棵重建，
  /// 每次切换白白多跑一轮 AppKit 布局递归——那正是切换文章要卡半秒的地方。
  private func articleDetail(detail: HistoryDetailProjection) -> some View {
    VStack(spacing: 0) {
      if model.profileImportReturnTarget?.taskID == detail.task.id,
         !model.isReadingCreatorWorkInDirectory {
        HStack {
          Button("返回抓取批次") {
            model.returnToProfileImportBatch()
            columnVisibility = .all
          }
          .accessibilityIdentifier("profile-import-return-to-batch")
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.badge)
      }
      if model.selectedScope == .trash {
        // 打开回收站里的一条，原来和正常内容看着一模一样（2026-10-01 走查）。
        HStack(spacing: 10) {
          Image(systemName: "trash")
            .foregroundStyle(theme.secondaryText)
          Text("这条在回收站里，\(HistoryTrashPolicy.retentionDays) 天后自动删除。")
            .themedFont(.callout)
            .foregroundStyle(theme.primaryText)
          Spacer(minLength: 0)
          Button("恢复") { model.restoreFromTrash(taskIDs: [detail.task.id]) }
            .buttonStyle(.appProminent(theme.accent))
            .controlSize(.small)
            .disabled(model.isReadOnly)
            .accessibilityIdentifier("history-trash-restore-detail")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.badge)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 1) }
        .accessibilityIdentifier("history-trash-detail-banner")
      } else if !isCaptureOnboardingDismissed && !firstCaptureIsComplete,
                !detail.task.canonicalURL.hasPrefix(HistoryPlatformDisplay.noteURLPrefix) {
        // 自己写的笔记不提示「配置模型后即可总结当前内容」：刚新建、一个字没写就被催着配模型
        // （2026-10-02 新用户走查）。
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
        isFocusReading: columnVisibility == .detailOnly,
        toggleFocusReading: { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly },
        openSettings: { openSettings() },
        openRecapture: { manualLink.openForRecapture($0) },
        remotePreviewPlayback: remotePreviewPlayback,
        sessionMediaPlayback: sessionMediaPlayback
      )
      .equatable()
      // 换一条时新内容淡入，而不是一帧之内整块替换（2026-10-04 走查）。
      .swapReveal(on: detail.task.id)
    }
  }

  private var emptyDetail: some View {
    // 空状态必须跟着当前区域走。
    //
    // 有搜索或筛选时，列表空只表示「当前条件没命中」，不是库空，更不是没写过笔记。
    // 「我的笔记」是自己写东西的地方，在那里显示「还没有保存页面 / 添加链接 /
    // 从剪贴板添加链接」不只是文案不对——它把用户往完全相反的动作上引。
    if model.showsCreatorZeroWorks {
      return AnyView(
        HistoryInlineState(
          symbol: "tray",
          title: "尚未保存作品",
          message: "打开主页后勾选要保存的内容。",
          actionTitle: "抓取作品",
          action: {
            if let url = model.selectedCreator?.profileURL {
              presentDouyinProfileImport(profileURL: url, autoStart: true)
            }
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-creator-zero-works-detail")
      )
    }
    // 列表里有内容、只是还没选中时，不能说「没有符合条件的内容」（2026-09-23 实测：
    // 点侧栏「语音备忘录」列出 88 条，右侧却提示筛选为空）。
    if model.hasActiveFilter, !model.rows.isEmpty {
      return AnyView(
        HistoryInlineState(
          symbol: "sidebar.left",
          title: "从左边选一条内容",
          message: "点列表里的任意一条，就会在这里打开。",
          // 每次打开 App 最先看到的就是这一屏：一枚等着盖的「汲」印位，不用通用侧栏图标。
          seal: (.external, theme.seal.opacity(0.75))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-select-item-detail")
      )
    }
    // 筛选/搜索没结果时，提示和「清除筛选」只在列表里说一次；详情区留白，
    // 不再把同一句话和同一个按钮并排显示两遍（2026-09-29 发布前走查）。
    if model.hasActiveFilter {
      return AnyView(
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("history-filter-empty-detail")
      )
    }
    if model.selectedScope == .notes {
      return AnyView(emptyNotesDetail)
    }
    if model.selectedScope == .trash {
      return AnyView(emptyTrashDetail)
    }
    return AnyView(emptyCaptureDetail)
  }

  /// 「按意思搜」补充的一组：不含搜索词、但讲的是相近的事（2026-09-29）。
  /// 行的样子和上面的列表完全一样，只多一个组标题说明它们为什么出现。
  private var relatedRowsSection: some View {
    Section {
      ForEach(model.visibleRelatedRows, id: \.taskID) { row in
        UIReadingHistoryRow(
          row: row,
          isSelected: model.selectedTaskIDs.contains(row.taskID),
          faviconURL: model.faviconImageURL(for: row),
          theme: theme,
          showsAuthor: true,
          onToggleFavorite: { model.toggleFavorite(taskID: row.taskID) },
          onSummarize: { summarizeSingle(row) },
          onActivate: { model.selectedTaskIDs = [row.taskID] },
          moreMenu: { AnyView(DeferredMenuContent { historyContextMenu(for: row) }) }
        ).equatable().tag(row.taskID)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 4, leading: -6, bottom: 4, trailing: -6))
          .listRowSeparator(.hidden)
          .contextMenu { DeferredMenuContent { historyContextMenu(for: row) } }
      }
    } header: {
      VStack(alignment: .leading, spacing: 2) {
        Text("意思相近")
          .themedFont(.subheadline, weight: .medium)
          .foregroundStyle(theme.secondaryText)
          .accessibilityAddTraits(.isHeader)
        Text("没有这几个字，但讲的是相近的内容")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText.opacity(0.8))
      }
      .padding(.leading, DesignTokens.Space.xs)
      .accessibilityIdentifier("history-list-related-group")
    }
  }

  private var filterEmptyState: some View {
    HistoryInlineState(
      symbol: "line.3.horizontal.decrease.circle",
      title: "没有符合条件的内容",
      message: "调整搜索词或清除筛选后再试",
      actionTitle: "清除筛选",
      action: clearListFilters
    )
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
        // 「我的笔记」已并入侧栏「形式 → 笔记」（2026-09-24），落到同一处，侧栏能看到选中。
        model.selectForm(.note, toggles: false)
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
        // 「我的笔记」已并入侧栏「形式 → 笔记」（2026-09-24），落到同一处，侧栏能看到选中。
        model.selectForm(.note, toggles: false)
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

  private var emptyTrashDetail: some View {
    HistoryInlineState(
      symbol: "trash",
      title: "回收站是空的",
      message: "删除的内容会在这里保留 \(HistoryTrashPolicy.retentionDays) 天。过期后会从本机彻底清除，无法再恢复。现在没有任何可恢复的内容。",
      actionTitle: "查看全部",
      action: { model.selectScope(.all) }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("history-trash-empty-detail")
  }

  private var emptyCaptureDetail: some View {
    // 三步卡在时只放三步卡（2026-10-01 走查）：下面那块「直接添加公开链接」+ 两个按钮和
    // 三步卡第 ① 步是同一件事，同屏三个入口反而不知道点哪个。卡关掉以后才露出这块。
    if !isCaptureOnboardingDismissed {
      return AnyView(
        firstCaptureCard
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .sheet(isPresented: $isSamplePreviewPresented) {
            SampleReadingPreviewSheet(theme: theme)
          }
      )
    }
    return AnyView(emptyCaptureFallback)
  }

  private var emptyCaptureFallback: some View {
    VStack(spacing: 0) {
      // 图标放进软底圆角瓦片，参考稿里 Browse channels 卡片的图形语言。
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 72, height: 72)
        .background(theme.badge, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl).stroke(theme.hairline, lineWidth: 1))
        .padding(.bottom, 18)
      Text("还没有保存页面")
        .themedFont(.title2, weight: .semibold)
        .padding(.bottom, 6)
      Text("粘贴公开网页链接，或用\(ProductDisplay.extensionName)保存已打开的页面后，可在这里总结或翻译。")
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
      // 第 ③ 步的按钮名固定写「生成总结」（2026-10-01 走查：原来没链接时写「先添加链接」
      // 像报错）。前两步没做完就灰掉，悬停说明原因；做完了点它打开第一条未总结的内容，
      // 详情顶上的「完成首次设置」条里就是同一个「生成总结」。
      onboardingStep(
        number: 3,
        title: "生成第一份总结",
        completed: model.rows.contains { $0.hasSummary == true },
        actionTitle: "生成总结",
        isEnabled: firstSummaryPrerequisitesMet,
        disabledHelp: "先完成前两步：添加链接、配置模型"
      ) {
        if let row = model.rows.first(where: { $0.hasSummary != true }) ?? model.rows.first {
          model.selectedTaskIDs = [row.taskID]
        }
      }
      // 新用户面对空库只看得到空壳（2026-10-01 走查）：给一个只读示例，看保存后长什么样。
      // 示例内容内置在 App 里，不写入资料库。
      HStack {
        Spacer()
        Button {
          isSamplePreviewPresented = true
        } label: {
          Label("看个示例", systemImage: "eye")
        }
        .buttonStyle(.borderless)
        .help("看一条保存好的内容长什么样：原文和总结。只是示例，不会存进资料库")
        .accessibilityIdentifier("first-capture-sample")
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

  private var firstSummaryPrerequisitesMet: Bool {
    !model.rows.isEmpty && providerSettings.hasConfiguredAPIKey
  }

  private func onboardingStep(
    number: Int,
    title: String,
    completed: Bool,
    actionTitle: String,
    isEnabled: Bool = true,
    disabledHelp: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: completed ? "checkmark.circle.fill" : "\(number).circle")
        .foregroundStyle(completed ? theme.success : theme.secondaryText)
        .font(.title3)
      Text(title).themedFont(.callout, weight: .medium)
      Spacer()
      if !completed {
        Button(actionTitle, action: action)
          .buttonStyle(.borderless)
          .disabled(!isEnabled)
          // 窗口统一染了正文色，borderless 按钮灰掉时看不出来（2026-10-01 实测），这里自己淡下去。
          .opacity(isEnabled ? 1 : 0.4)
          // 灰掉的按钮自己收不到悬停，提示挂在外层才看得到。
          .help(isEnabled ? "" : (disabledHelp ?? ""))
          .accessibilityHint(isEnabled ? "" : (disabledHelp ?? ""))
      }
    }
    .contentShape(Rectangle())
    .help(!completed && !isEnabled ? (disabledHelp ?? "") : "")
  }

  private var blockingError: some View {
    HistoryInlineState(
      symbol: "externaldrive.badge.exclamationmark",
      title: "无法打开历史记录",
      message: "资料库这次打不开。\(ProductDisplay.name)没有对数据做任何写入，已保存的内容仍在原处。请检查本机存储后重新启动\(ProductDisplay.name)；仍然不行时，可在「数据与备份」里从备份恢复。",
      actionTitle: "查看备份说明",
      action: {
        SettingsNavigationRequest.request("dataBackup")
        openSettings()
      }
    )
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityIdentifier("history-blocking-error")
  }
}

/// 多选时详情列的操作面板：批量动作和操作对象同屏，不分散到窗口工具栏。
private struct HistoryMultiSelectionPanel: View {
  @Bindable var model: HistoryViewModel
  var providerSettings: ProviderSettingsViewModel
  let protectedTaskIDs: Set<TaskID>
  let theme: HistoryThemeTokens

  var body: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Image(systemName: "checklist.checked")
          .font(.system(size: DesignTokens.IconSize.empty, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 58, height: 58)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        if model.isBatchSummarizing {
          Text("正在批量总结").themedFont(.title2, weight: .semibold)
        } else if model.isBatchTranslating {
          Text("正在批量翻译").themedFont(.title2, weight: .semibold)
        } else {
          Text("已选择 \(model.selectedTaskCount) 项").themedFont(.title2, weight: .semibold)
          Text(selectionScopeDescription)
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }

      if model.isBatchSummarizing {
        VStack(spacing: 14) {
          HStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(model.batchSummaryProgressText)
              .themedFont(.callout, weight: .medium)
              .foregroundStyle(theme.secondaryText)
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          .accessibilityIdentifier("batch-summarize-progress")
          Button("停止") { model.stopBatchSummary() }
            .buttonStyle(AppButtonStyle(emphasis: .normal))
            .disabled(model.batchSummaryProgress?.isStopping == true)
            .help("停止尚未开始的批量总结")
            .accessibilityLabel("停止批量总结")
            .accessibilityIdentifier("batch-summarize-stop")
        }
        .frame(maxWidth: 360)
      } else if model.isBatchTranslating {
        VStack(spacing: 14) {
          HStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(model.batchTranslationProgressText)
              .themedFont(.callout, weight: .medium)
              .foregroundStyle(theme.secondaryText)
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          .accessibilityIdentifier("batch-translate-progress")
          Button("停止") { model.stopBatchTranslation() }
            .buttonStyle(AppButtonStyle(emphasis: .normal))
            .disabled(model.batchTranslationProgress?.isStopping == true)
            .help("停止尚未开始的批量翻译")
            .accessibilityLabel("停止批量翻译")
            .accessibilityIdentifier("batch-translate-stop")
        }
        .frame(maxWidth: 360)
      } else {
        VStack(spacing: 10) {
          Button {
            model.requestBatchSummary()
          } label: {
            Label("总结选中项", systemImage: MenuIcon.summarize)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(AppButtonStyle(emphasis: .prominent, accent: theme.accent))
          .disabled(!model.canBatchSummarize || !providerSettings.arePreferencesReady)
          .accessibilityIdentifier("batch-summarize-history")

          Button {
            model.requestBatchTranslation(outputLanguage: providerSettings.outputLanguage)
          } label: {
            Label("翻译选中项", systemImage: MenuIcon.translate)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(AppButtonStyle(emphasis: .normal))
          .disabled(!model.canBatchTranslate || !providerSettings.arePreferencesReady)
          .accessibilityIdentifier("batch-translate-history")

          Button {
            model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
          } label: {
            Label(
              model.selectedScope == .trash ? "彻底删除选中项" : "移到回收站",
              systemImage: "trash"
            )
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(AppButtonStyle(emphasis: .normal))
          .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
          .accessibilityIdentifier("delete-selected-history")

          Button("取消选择") { model.selectedTaskIDs = [] }
            .buttonStyle(AppButtonStyle(emphasis: .quiet))
            .accessibilityIdentifier("clear-history-selection")
        }
        .frame(maxWidth: 280)
      }

      if !model.isBatchSummarizing, !model.isBatchTranslating {
        Text("已有总结或译文的条目会跳过。失败后可再次总结或翻译选中项。列表右键菜单提供同样操作；Delete 键可删除。")
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("history-multi-selection-panel")
  }

  private var selectionScopeDescription: String {
    var parts: [String] = []
    if let creator = model.selectedCreator {
      parts.append("博主 \(creator.listingTitle)")
    } else {
      switch model.selectedScope {
      case .all: parts.append("全部内容")
      case .recent: parts.append("最近 7 天")
      case .unsummarized: parts.append("未总结")
      case .untidied: parts.append("待校对")
      case .untranscribed: parts.append("待转写")
      case .favorite: parts.append("收藏")
      case .own: parts.append("自有")
      case .external: parts.append("外部")
      case .notes: parts.append("笔记")
      case .drafts: parts.append("稿件")
      case .works: parts.append("作品")
      case .trash: parts.append("回收站")
      }
    }
    if let form = model.selectedForm {
      parts.append(form.rawValue)
    }
    if !model.selectedHosts.isEmpty {
      parts.append("\(model.selectedHosts.count) 个平台")
    }
    if !model.selectedTagNormalizedNames.isEmpty {
      parts.append("\(model.selectedTagNormalizedNames.count) 个标签")
    }
    return "范围：" + parts.joined(separator: " · ")
  }
}

struct HistoryWindowToolbarThemeModifier: ViewModifier {
  let theme: HistoryThemeTokens
  /// 这一列头顶那段工具栏条的底色。
  ///
  /// **它在 macOS 26+ 上已经不起作用，也不可能起作用**：`toolbarBackground`
  /// 是窗口级的，而统一工具栏只有一条横贯整扇窗的背景——三列各传一个颜色时
  /// 只有一个会赢（实测赢的是最外层那次 `theme.canvas`）。于是画布色的横条
  /// 压在 listPane(#EFF0ED) 与 card(#FAFAF7) 两种底色之上，详情列顶上就多出
  /// 一条 ΔL*≈8 的灰带——用户看到的「上面那条边框跟下面不融合」就是它。
  ///
  /// 正确做法是 Finder / 备忘录那一套：工具栏不自带底色，由每一列把自己的
  /// 背景铺到窗口顶，横条自然就跟着列分段。遮挡交给 `.hard` scroll edge。
  /// 这个参数保留是为了不改 8 个调用点的形状；旧系统分支仍然用它。
  var background: Color? = nil

  @ViewBuilder func body(content: Content) -> some View {
    if theme.isNative {
      content
    } else if #available(macOS 26.0, *) {
      // macOS 26 起工具栏是悬浮 Liquid Glass，不再有可着色的整条背景；
      // 自定义 toolbarBackground 反而会压掉系统的 scroll edge effect，
      // 表现就是正文文字原样从悬浮图标底下穿过去。用系统的柔和 scroll edge：
      // 内容滑到工具栏下方时渐变模糊淡出，图标保持清晰，又不像硬边那样一刀切。
      // 原来是 `.hard`，实测在 macOS 27 上视频和正文仍从图标底下原样穿过。
      content
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .windowToolbar)
    } else {
      content
        .toolbarBackground(background ?? theme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .windowToolbar)
    }
  }
}

/// 详情列顶部、工具栏那一条的渐变毛玻璃。
///
/// 系统的 scroll edge effect（`.hard` / `.soft`）在详情列实测都不生效：视频和正文
/// 原样从星标、标签这些悬浮图标底下穿过，图标看不清。列表列没这个问题。
/// 这里自己叠一层：毛玻璃 + 列底色，越往上越实，向下渐变到透明。
/// 只盖工具栏那一条（安全区顶部再多一点），不接收点击，也不在工具栏按钮之上。
struct ToolbarScrollFade: View {
  let background: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        // 0.92 而不是 0.6：0.6 时列表行滚到「全部」和搜索、「＋」底下还能读出字
        // （2026-10-01 Syc 走查截图）。实色段也从上半截拉到 75%，只留底边一小段渐隐。
        background.opacity(0.92)
      }
      .mask(
        LinearGradient(
          stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.75),
            .init(color: .clear, location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      // 只盖工具栏那一条（安全区），不往下多盖：再往下就压到吸顶表头和标题上沿了。
      .frame(height: proxy.safeAreaInsets.top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .ignoresSafeArea(edges: .top)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// 侧栏与网格共用，所以不是 private。
struct PlatformNavigationIcon: View {
  let host: String
  var faviconURL: URL? = nil
  var faviconTaskID: TaskID? = nil
  /// 侧栏里的平台 logo 改成单色剪影：一列里既有黑白线稿又有彩色商标，视线会被
  /// 商标抢走。列表行里仍用彩色 logo 保持辨识度。颜色由调用方的 foregroundStyle 给。
  var monochrome: Bool = false

  var body: some View {
    if host == HistoryPlatformDisplay.miscHost {
      // 杂项来源没有 logo 可取，用收件盘符号——它表达的正是「还没归类」。
      // List 会盖掉环境字号；resizable + 16 框避免 SF Symbol 按 18pt 被裁。
      // 颜色由调用方给，和其它平台剪影一致。
      // 不用托盘：托盘已经是「收件箱」的图标，两处同图会被当成同一个东西。
      Image(systemName: "ellipsis.circle")
        .resizable()
        .scaledToFit()
        .frame(width: Self.monochromeSize, height: Self.monochromeSize)
    } else if monochrome, let glyph = PlatformIconCatalog.sidebarGlyph(for: host) {
      Image(nsImage: glyph)
        .renderingMode(.template)
        .resizable().scaledToFit()
        .frame(width: Self.monochromeSize, height: Self.monochromeSize)
    } else if let image = PlatformIconCatalog.image(for: host) {
      // 单色两种画法，同一颜色、同一 16pt 框（2026-09-23 统一）：
      // - 线条型 logo（X、GitHub、B 站、公众号、掘金）：直接取形状，模板渲染；
      // - 满底型 logo（YouTube、抖音、Reddit、小红书、知乎…）：实心底色块，把里面的
      //   白色标志镂空。原来这类是「去色 + 72% 透明」的灰块，和旁边的线条剪影不是一家。
      // 侧栏单色图标只有两种画法，同一颜色、同一线宽（2026-09-23 统一成线框）：
      // - 本身就是细线条的 logo（X、B 站、掘金）：直接取形状；
      // - 其余 logo：自动描成约 1pt 的轮廓，深底白标型再保留里面的标志。
      //   原来这些是实心块或镂空色块，一列里一半是色块，比文字重得多。
      if monochrome, let name = PlatformIconCatalog.assetName(for: host),
         PlatformIconCatalog.usesGlyphSilhouette(forAssetName: name) {
        Rectangle()
          .fill(.foreground)
          .mask { Image(nsImage: image).resizable().scaledToFit() }
          .frame(width: Self.monochromeSize, height: Self.monochromeSize)
      } else if monochrome, PlatformIconCatalog.assetName(for: host) == "xiaohongshu" {
        // 小红书的标志就是「小红书」三个字，缩到 14pt 描边后看不清，改成单字线框徽标。
        monochromeLetterBadge("红")
      } else if monochrome, let name = PlatformIconCatalog.assetName(for: host),
                let outline = PlatformIconCatalog.sidebarOutlineImage(forAssetName: name) {
        Image(nsImage: outline)
          .renderingMode(.template)
          .resizable().scaledToFit()
          .frame(width: Self.monochromeSize, height: Self.monochromeSize)
      } else {
        Image(nsImage: image)
          .resizable().scaledToFit().frame(width: 16, height: 16)
      }
    } else if monochrome {
      // 侧栏不用站点 favicon：Substack 这类没有内置 logo 的平台，favicon 取自某一条
      // 记录的刊物头像，换一条记录图标就换一张，看起来像在闪。降级用稳定首字母，
      // 画法和满底型 logo 一致：当前文字色的圆角块，字母镂空。
      monochromeLetterBadge(PlatformIconCatalog.fallbackInitial(for: host))
    } else if let faviconURL, let faviconTaskID {
      HistoryFaviconDiskImage(url: faviconURL, host: host, taskID: faviconTaskID) {
        fallbackBadge
      }
    } else {
      fallbackBadge
    }
  }

  /// 侧栏单色图标的显示尺寸：比文字行略小一档，和「本机」区的系统线条图标同一重量。
  /// 13：和侧栏系统图标（`IconSize.sidebar`）同一大小（2026-09-25，原 14）。
  static let monochromeSize: CGFloat = 13

  /// 单色字母徽标：1pt 线框圆角方块，字用常规偏中等字重。原来是实心块、字镂空，
  /// 一列三个小黑方块（Discourse、Substack、小红书）正是侧栏发重的来源之一。
  private func monochromeLetterBadge(_ letter: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        .strokeBorder(.foreground, lineWidth: 1)
      Text(letter)
        .font(.system(size: 9, weight: .medium, design: .rounded))
    }
    .frame(width: Self.monochromeSize, height: Self.monochromeSize)
  }

  private var fallbackBadge: some View {
    Text(PlatformIconCatalog.fallbackInitial(for: host))
      .font(.system(size: BadgeTypography.size, weight: .bold))
      .foregroundStyle(PlatformIconCatalog.fallbackBadgeForeground(for: host))
      .frame(width: 16, height: 16)
      .background(PlatformIconCatalog.fallbackBadgeBackground(for: host), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
  }
}

/// The detail header needs a recognizable source, not a wire-format URL.
/// Opening and copying still use the untouched value; this is display-only.

private struct HistoryDetailView: View, Equatable {
  @AppStorage("onboarding.capture-v1.dismissed") private var isCaptureOnboardingDismissed = false
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
      && lhs.isFocusReading == rhs.isFocusReading
  }

  let detail: HistoryDetailProjection
  @Bindable var model: HistoryViewModel
  var appModel: AppViewModel
  var providerSettings: ProviderSettingsViewModel
  let appearanceTheme: AppearanceTheme
  let localImageURLs: [URL]
  let localMediaFileURL: URL?
  /// 主界面「专注阅读」：隐藏侧栏后正文收窄居中，约 760pt。
  let isFocusReading: Bool
  /// 专注阅读开关。2026-09-23 从窗口顶栏收进阅读区「更多」菜单。
  let toggleFocusReading: () -> Void
  let openSettings: () -> Void
  let openRecapture: (String) -> Void
  /// 与列表预热共享：选中当前抓取时已开始 prepare，详情卡复用同一 controller。
  @ObservedObject var remotePreviewPlayback: RemotePreviewPlayerController
  @ObservedObject var sessionMediaPlayback: SessionMediaPlaybackController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isRegeneratePopoverPresented = false
  /// 「处理 → 抓取评论…」面板。
  @State private var isCommentPickerPresented = false
  @State private var isRunPanelExpanded = false
  @State private var isReadingHeaderPinned = false
  @State private var showsPlainText = false
  /// 逐字稿看哪一份：校对稿（默认）、朱批（校对稿 + 改动）、原稿（机器听写）。
  @State private var manuscriptMode: TranscriptManuscript.Mode = .revised
  /// 刚校对完的那一条：「校对稿已保存」只亮几秒。
  @State private var recentlyCompletedTidyTaskID: TaskID?
  /// 「处理」面板（2026-09-28 工序印）：原来是系统菜单，只能放单色小图标，放不下印。
  @State private var isProcessPanelPresented = false
  /// 盖章那一刻：记下这一条已经做过哪些工序，新多出来的那道就盖一下。
  @State private var stampBaseline: (taskID: TaskID, steps: [ProcessStep: Double])?
  @State private var stampingStep: ProcessStep?
  /// 点页尾的「图」要滚到脑图模块。
  @State private var moduleScrollTarget: ReadingAnchor?
  @State private var temporaryModel = ""
  /// Brief completion feedback after summarize/translate finishes.
  @State private var completionBanner: String?
  /// When both a model artifact and the captured source exist, user can switch.
  /// 这一条上用户点过的页签。没点过（或换了一条）就是 `defaultReadingPane`。
  ///
  /// 按条目记，而不是换条目时在 onChange 里把它改回默认：那一改会让整页再重算一遍，
  /// 切一条要多卡 40–140ms（2026-10-05 逐次计数）。下面几个「只对这一条有效」的状态同理。
  @State private var readingPaneChoice: PerItem<ReadingPane>?
  private var readingPane: ReadingPane {
    get { readingPaneChoice?.value(for: detail.task.id) ?? defaultReadingPane }
    nonmutating set { readingPaneChoice = PerItem(taskID: detail.task.id, value: newValue) }
  }
  /// 点了总结/翻译、Run 还没变成可见态时，先把对应页签打开。
  /// 否则抖音图文只有「原文」，生成过程只能再挂一块预览卡片。
  @State private var pendingRunPane: ReadingPane?
  /// 阅读进度独立小模型：进度若放进本视图的 @State，每个滚动事件都会
  /// 重求值整个详情页——那是长文滚动掉帧的来源（见 ReadingProgressModel）。
  ///
  /// 用 @State 而不是 @StateObject：@StateObject 会让本视图订阅它的
  /// objectWillChange，进度每变 1% 整个详情页照样重求值一遍，独立模型等于白拆
  /// （2026-09-24 实测：九万字长文滚到底要重算约百次）。只有真正显示进度的叶子
  /// 视图才该观察它。
  @State private var readingProgressModel = ReadingProgressModel()
  /// 已访问过的阅读面板（见 content 的注释）：保活的折叠集合。
  @State private var visitedReadingPanesStore: PerItem<Set<ReadingPane>>?
  private var visitedReadingPanes: Set<ReadingPane> {
    visitedReadingPanesStore?.value(for: detail.task.id) ?? []
  }
  /// 各阅读面板的实测高度：ZStack 容器按「当前活动面板的高度」定高，
  /// 隐藏面板保持自然尺寸不被折叠——切换因此不触发任何几何重算。
  @State private var paneHeights: [ReadingPane: CGFloat] = [:]
  @State private var pendingSourceCitation: String?
  @State private var measuredTitleHeightStore: PerItem<CGFloat>?
  private var measuredTitleHeight: CGFloat {
    measuredTitleHeightStore?.value(for: detail.task.id) ?? HistoryDetailView.captureTitleLineHeight
  }
  /// 抓取长标题默认最多 3 行；超出后用「展开标题 / 收起标题」，切换条目复位。
  @State private var isTitleExpanded = false
  /// 转写校对：编辑态与草稿只属于当前详情页，切换条目即复位。
  /// 长配文 / 长转写默认收起，避免把「重新转写」顶出一屏。
  @State private var isCaptionExpanded = false
  @State private var isTranscriptExpanded = false
  @State private var isImportedImageTextExpanded = false
  @State private var renamingSpeaker: String?
  @State private var speakerNameDraft = ""
  @State private var isOnlineDiarizationConfirmPresented = false
  @State private var isSubtitleExpanded = false
  /// 收起长文后滚回该层顶部，避免停在空白处。
  @State private var sourceCollapseScrollTarget: String?
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
  /// 当前条目的排版档案。按快照算一次记住——形态指纹要扫一遍全文，长文有九万字，
  /// 放在 body 里每次重求值都算等于把它做成了热路径。原来是换条目时写进 @State，
  /// 那一写又让整页多重算一遍。
  private var readingFormat: ReadingFormatDecisions {
    let snapshot = latestTranscriptionSnapshot ?? latestSnapshot
    return derivedMemo.value("readingFormat", snapshot: snapshot) {
      guard let snapshot else { return ReadingFormatDecisions(keepsImagePositions: false, allowsOutline: true) }
      let body = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
      return ReadingFormatRegistry.decisions(for: ReadingFormatContext(
        shape: ContentShape.measure(markdown: body),
        platform: snapshot.platform,
        isTranscript: snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
      ))
    }
  }
  /// 详情页派生值的备忘：frontmatter、命名、长文判定这些都要扫全文，原来是
  /// 计算属性，一次 body 求值对九万字正文扫二三十遍。按「快照 id + 字节数」缓存，
  /// 引用类型放在 @State 里，读写它不触发重绘。
  @State private var derivedMemo = DetailDerivedMemo()
  @State private var colophonMemo = ColophonContextMemo()
  /// 当前转写稿的分段时间，空数组表示这份正文没有可跳转的时间。
  @State private var transcriptParagraphs: [TranscriptParagraph] = []
  /// 转写稿显示段首时间码。关掉时去掉时间码、把短句合成段落，当文章读；全局记住。
  @AppStorage("reading-shows-transcript-timecodes") private var showsTranscriptTimecodes = true
  /// 分段属于哪一份 snapshot。切换条目时新分段还没读回来，旧分段会在这一帧
  /// 配上新正文——记住来源，对不上就不画锚点。
  @State private var transcriptParagraphsSnapshotID: ContentSnapshotID?
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
  @AppStorage(ReadingLayoutWidth.storageKey) private var readingUsesWideLayout = false
  /// 点了「添加笔记」才出现输入框；已经写过笔记的条目直接显示。
  @State private var isInlineNoteRequested = false
  @FocusState private var isInlineNoteFocused: Bool
  @State private var noteLastSavedAt: Date?
  private var theme: HistoryThemeTokens { appearanceTheme.tokens }
  /// 工具栏「小／大」按步进调字号，夹在合法区间内。改的是与设置页同一个
  /// @AppStorage，外观页的滑块会立即跟着动。
  private static func readingFontSizeLabel(_ raw: Double) -> String {
    let value = ReadingFontSize.clamped(CGFloat(raw))
    if value == value.rounded() {
      return "\(Int(value)) 点"
    }
    return String(format: "%.1f 点", Double(value))
  }

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

    /// 表头页签上的短名。`heading` 是文档里的小标题（「视频转写」），页签只放一个词。
    var tabTitle: String {
      switch self {
      case .caption: "配文"
      case .subtitles: "字幕"
      case .transcript: "转写"
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

  /// 有评论读取器的外部来源才给「抓取评论…」；自己写的笔记、本机文件没有评论区。
  private var commentSourceURL: URL? {
    guard !isOwnWriting, latestSnapshot != nil, let url = URL(string: sourceURL),
          CommentCapture.platform(for: url) != nil else { return nil }
    return url
  }

  /// 勾选结果替换正文末尾的评论段，走与校对正文同一条原地保存通道。
  private func saveSelectedComments(_ selected: [CapturedComment], expectedCount: Int?) {
    guard let snapshot = latestSnapshot else { return }
    let body = CommentCapture.replacingComments(in: snapshot.bodyText, expectedCount: expectedCount, selected: selected)
    guard body != snapshot.bodyText else { return }
    model.saveEditedSnapshotText(taskID: detail.task.id, snapshotID: snapshot.id, bodyText: body)
  }
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
      noteLastSavedAt = Date()
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      guard !Task.isCancelled else { return }
      noteSaveIndicator = false
    }
  }

  private var noteCharacterCount: Int {
    transcriptionDraft.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
  }

  private func noteEditorStatusText(isDirty: Bool) -> String {
    if isDirty { return "正在保存…" }
    guard noteSaveIndicator, let savedAt = noteLastSavedAt else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return "已保存 · \(formatter.string(from: savedAt))"
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
    if DailyNoteTitleFormat.isISODateTitle(title),
       DailyNoteTitleFormat.display(title) == resolved {
      noteTitleDraft = resolved
      return
    }
    guard resolved != title else {
      noteTitleDraft = DailyNoteTitleFormat.display(resolved)
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
  /// 配文层：抓取正文非空就呈现。抖音即使配文与标题相同也要能读，不能藏掉。
  /// 只有一层文字、但这条是带视频的帖子：那段文字就是视频的配文，页签叫「配文」。
  ///
  /// 原来只有一层时一律叫「原文」，转写完分成两层才改叫「配文 / 转写」——同一段字
  /// 点一次转写就换了名字，像换了一份内容（2026-10-03 Syc 走查）。
  private var singleSourceIsCaption: Bool {
    // `latestSourceSnapshot` 已经只取抓取来源那一层（见 captionSnapshot），不会是转写。
    guard !isOwnWriting, hasPresentableCaption, let snapshot = latestSourceSnapshot else { return false }
    if localMediaFileURL != nil || detail.media != nil || detail.hadMediaDescriptor || isUnsavedXVideo {
      return true
    }
    if isDouyinCapture { return !isDouyinImagePostCapture }
    return snapshot.platform == "bilibili"
  }

  private var hasPresentableCaption: Bool {
    guard let snapshot = latestSourceSnapshot,
          !LayeredSourceDocument.isSupersededPlaceholder(snapshot, in: detail.snapshots) else { return false }
    return !LayeredSourceDocument.body(of: snapshot).isEmpty
  }
  /// 原文层在阅读页上显示的小标题。本机导入的录音、音频没有画面，转写层叫「视频转写」
  /// 会让人以为弄错了条目；发给模型和翻译拆层用的仍是原标题，这里只改显示。
  private func displayHeading(_ heading: String) -> String {
    guard heading == LayeredSourceDocument.transcriptHeading else { return heading }
    let audioOnlyMethods: Set<String> = ["voice_memos_import", "local_file_audio"]
    return latestSourceSnapshot.map { audioOnlyMethods.contains($0.captureMethod) } == true
      ? "录音转写"
      : heading
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
    if available.contains(.transcript) { return .transcript }
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
  ///
  /// 配文本来就是输出语言时，模型交回来的「配文译文」就是原样抄一遍（2026-10-03 实库：
  /// 中文配文 + 英文讲座视频）。这一层不列：点开和原文一字不差，只会让人以为翻译没生效。
  /// 只剩一层时不出切换控件，但仍只显示那一层，不退回整篇纵向叠着。
  private var availableTranslationLayers: [SourceLayer] {
    let layers = translationPreamble == nil ? translationLayers : Array(translationLayers.dropFirst())
    guard layers.count > 1 else { return [] }
    let named = layers.compactMap(\.layer)
    guard named.count == layers.count else { return [] }
    return named.filter { layer in
      guard layer == .caption,
            let translated = layers.first(where: { $0.layer == .caption })?.body,
            let source = latestSourceSnapshot
      else { return true }
      return Self.comparableText(translated) != Self.comparableText(LayeredSourceDocument.body(of: source))
    }
  }

  /// 比较「译文是不是原样抄回来」用：去掉所有空白再比。
  private static func comparableText(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
  }

  private var activeTranslationLayer: SourceLayer? {
    let available = availableTranslationLayers
    if let selected = selectedTranslationLayer, available.contains(selected) { return selected }
    if available.contains(.transcript) { return .transcript }
    return available.first
  }

  private var showsTranslationLayerPicker: Bool { availableTranslationLayers.count > 1 }

  /// 当前看的译文是一份带时间码的转写稿（转写层、字幕层的译文）时，按逐字稿排的正文；否则 nil。
  /// 译文常是一行一个时间码、行间只隔一个换行：先在每个时间码前补成空行，逐字稿按空行切段。
  private var translatedTranscriptBody: String? {
    guard !showsPlainText, let layer = activeTranslationLayer, layer == .transcript || layer == .subtitles,
          let body = translationLayers.first(where: { $0.layer == layer })?.body else { return nil }
    let normalized = body.replacingOccurrences(
      of: #"\n[ \t]*(?=(?:\d{1,2}:)?\d{1,2}:\d{2}\s)"#, with: "\n\n", options: .regularExpression
    )
    return TranscriptManuscript.looksLikeTranscript(normalized) ? normalized : nil
  }

  /// 当前该渲染的译文正文：开头那段（标题）+ 当前这一层。没分层时返回 nil，
  /// 调用方退回整篇。
  private var activeTranslationBody: String? {
    guard let active = activeTranslationLayer,
          let body = translationLayers.first(where: { $0.layer == active })?.body
    else { return nil }
    guard let preamble = translationPreamble else { return body }
    // 译出来的标题和页面标题、或这一层的第一句是同一句话时不再拼上去：
    // 原来每一层开头都多出一行「今晚别刷Netflix了。」，配文层里紧接着又是同一句（2026-10-03 走查）。
    let firstLine = body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
    // 先去掉「captured 标题：」这类包装行再比：旧译文开头常带着它，原样比永远对不上（2026-10-04 走查）。
    let comparablePreamble = Self.comparableText(
      MarkdownNoteFrontmatter.strippingCapturedEnvelope(from: preamble).replacingOccurrences(of: "#", with: "")
    )
    if comparablePreamble == Self.comparableText(readingPrimaryTitle)
      || comparablePreamble == Self.comparableText(firstLine) {
      return body
    }
    return preamble + "\n\n" + body
  }

  private var showsLayeredSource: Bool {
    // 听写和画面字幕都算派生层，有任意一层就该分层显示。
    //
    // 原来只看听写，于是只读了字幕、没跑听写的记录会退回单层渲染，把刚读出来
    // 的那一层整个藏起来——数据在库里，界面上却什么都看不到。
    //
    // 配文**不是**分层的前提。字幕和听写同时在，就必须分层，不能因为配文与标题
    // 相同就把整页退回单层、只画听写稿。
    if latestSubtitleSnapshot != nil, latestTranscriptionSnapshot != nil { return true }
    if hasPresentableCaption && (latestTranscriptionSnapshot != nil || latestSubtitleSnapshot != nil) {
      return true
    }
    // 抖音只有配文、还没转写时也要走配文层，避免退回「只显示转写」而整页空白。
    return isDouyinCapture && hasPresentableCaption
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
  private var title: String {
    let stored = CapturedDocumentTitle.display(detail.snapshots.last?.title, for: sourceURL)
    // 备忘录的长标题导入时被截短了：按正文第一行（切碎的标题先合回来）还原成完整句。
    guard let snapshot = detail.snapshots.last, snapshot.platform == "applenotes", stored.hasSuffix("…") else { return stored }
    return derivedMemo.value("appleNoteTitle|\(stored)", snapshot: snapshot) {
      let body = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
      let merged = AppleNoteHTML.mergingFragmentedHeadings(body.components(separatedBy: "\n")).joined(separator: "\n")
      return CapturedSourceBodyPresentation.expandedTruncatedTitle(stored, firstLines: merged)
    }
  }
  private var contentName: CapturedContentNaming.Name {
    if isOwnWriting { return .init(text: title, origin: .sourceTitle) }
    if latestSourceSnapshot?.sourceLabel == "X public article endpoint", title != CapturedDocumentTitle.missing {
      return .init(text: title, origin: .sourceTitle)
    }
    let frontmatter = sourceFrontmatter
    let host = URL(string: sourceURL)?.host ?? ""
    return derivedMemo.value("contentName|\(host)|\(title)", snapshot: latestSourceSnapshot) {
      let body = latestSourceSnapshot.map { LayeredSourceDocument.body(of: $0) }
      // 备忘录用还原过的完整标题（见 `title`）：正文里那句已按「和标题同一句」藏掉，
      // 这里再用截短版，句子后半就哪儿都看不到了。
      let name = CapturedContentNaming.name(
        title: latestSourceSnapshot?.platform == "applenotes" ? title : latestSourceSnapshot?.title,
        body: body,
        host: host,
        author: frontmatter.author, published: frontmatter.published
      )
      // 和列表行同一个取法：首句只是「啊啊啊啊😮😮！」时往后取一句有内容的。
      // 原来列表叫「感受一下 Muse 直出的视频！」，点开详情却叫「啊啊啊啊😮😮！」（2026-10-01 走查）。
      guard name.origin == .caption else { return name }
      let preview = body.map { MarkdownNoteFrontmatter.parse($0).body }
      return .init(text: HistoryListFinding.informativeCaptionTitle(caption: name.text, sourcePreview: preview), origin: .caption)
    }
  }
  private var hidesRepeatedCaptureHeading: Bool {
    guard !isOwnWriting,
          readingPrimaryTitle == contentName.text,
          readingOriginalSubtitle == nil, let source = latestSourceSnapshot else { return false }
    // 只有正文首句就在眼前时才藏标题，免得同一句话连着出现两次。
    // 推文、抖音这类标题从配文首句合成的，原来所有页签一律不显示标题：切到「总结」
    // 或抖音的「转写」后，整页没有任何地方写着这是哪一条（2026-10-01 走查）。
    guard effectiveReadingPane == .source,
          !showsLayeredSource || activeSourceLayer == .caption else { return false }
    // 标题和正文之间夹着视频时，正文首句被挤到一屏以外：藏了标题，整页看不出是哪一条
    // （2026-10-01 走查：一条竖版视频推文，头部只剩作者行）。
    if localMediaFileURL != nil || detail.media != nil { return false }
    if contentName.origin == .caption { return true }
    let name = contentName
    return derivedMemo.value("hidesRepeatedHeading|\(name.text)|\(name.origin)", snapshot: source) {
      CapturedContentNaming.hidesRepeatedHeading(
        name: .init(text: name.text, origin: name.origin == .fallback ? .fallback : .caption),
        body: LayeredSourceDocument.body(of: source)
      )
    }
  }
  /// 页面上方正显示着一个取自配文首句的标题：这时配文就不必再从同一句开始。
  private var showsCaptionTitleAbove: Bool {
    !isOwnWriting && !hidesRepeatedCaptureHeading
      && contentName.origin == .caption && readingPrimaryTitle == contentName.text
  }
  /// 详情头：有总结/翻译一级标题时主标题用产物，原文降副行；标题本地化后副行读 original_title。
  /// 按快照记住：`detailTitles` 要把正文按行切开逐行比对，一次几十毫秒；详情页切换时
  /// body 会求值好几次，每次都重算，切一条要多卡上百毫秒（2026-10-04 Instruments 实测）。
  private var readingTitles: (primary: String, original: String?) {
    let captured = contentName.text
    let summary = summaryArtifact?.bodyText
    let translation = translationArtifact?.bodyText
    let key = "readingTitles|\(captured)|\(summary?.utf8.count ?? -1)|\(translation?.utf8.count ?? -1)"
    let titles: ReadingTitles = derivedMemo.value(key, snapshot: latestSourceSnapshot) {
      let resolved = HistoryReadingTitle.detailTitles(
        captured: captured,
        product: HistoryReadingTitle.productTitle(summaryBody: summary, translationBody: translation),
        preservedOriginalTitle: sourceFrontmatter.originalTitle,
        sourceBody: sourceFrontmatter.body
      )
      return ReadingTitles(primary: resolved.primary, original: resolved.original)
    }
    return (titles.primary, titles.original)
  }
  private struct ReadingTitles { let primary: String; let original: String? }
  private var readingPrimaryTitle: String { readingTitles.primary }
  private var readingOriginalSubtitle: String? { readingTitles.original }
  /// 专注阅读约 760pt；常规模式仍用字号联动的绝对上限。
  /// 「加宽正文」（2026-09-25，对齐 Tolaria 的 Normal / Wide）去掉上限，铺满可用宽度，
  /// 给宽表格、流程图、代码用。三栏并排时正文列本来就比上限窄，效果在专注阅读和宽窗口里才看得出。
  private static let focusReadingMaxWidth: CGFloat = 760
  private var readingContentMaxWidth: CGFloat {
    if readingUsesWideLayout { return .infinity }
    let scaled = DesignTokens.Layout.readingAbsoluteMaxWidth(bodySize: readingFont.bodySize)
    return isFocusReading ? min(Self.focusReadingMaxWidth, scaled) : scaled
  }
  private var sourceURL: String { detail.snapshots.last?.sourceURL ?? detail.task.canonicalURL }
  /// Tolaria-style properties from capture frontmatter (author / published / description).
  private var sourceFrontmatter: MarkdownNoteFrontmatter {
    derivedMemo.value("frontmatter", snapshot: latestSourceSnapshot) {
      MarkdownNoteFrontmatter.parse(latestSourceSnapshot?.bodyText ?? "")
    }
  }
  private var showsCurrentCapture: Bool { appModel.currentCapture?.taskID == detail.task.id }
  private var showsVisibleRun: Bool { appModel.showsVisibleRun(for: detail.task.id) }
  private var canRunHistory: Bool { appModel.canStartRun(from: detail) }
  private var isUntranscribedMedia: Bool {
    guard let body = detail.snapshots.last?.bodyText else { return false }
    return LocalImportDocument.isUntranscribedPlaceholder(body)
  }
  private var summarizeUnavailableReason: String? {
    if appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .summarize) {
      return nil
    }
    let reason = appModel.summarizeUnavailableReason(
      usingCurrentCapture: showsCurrentCapture,
      detail: detail,
      preferencesReady: providerSettings.arePreferencesReady
    )
    // 还没转写不是「通道忙」，排队等多久都不会变成能总结。
    if isUntranscribedMedia { return AppViewModel.untranscribedRunReason }
    if reason != nil, appModel.canEnqueueManualGeneration(for: detail.task.id) {
      return nil
    }
    return reason
  }
  private var translateUnavailableReason: String? {
    if appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .translate) {
      return nil
    }
    let reason: String?
    if showsCurrentCapture {
      reason = appModel.translateUnavailableReason(
        usingCurrentCapture: true,
        detail: detail,
        preferences: providerSettings.runPreferences,
        preferencesReady: providerSettings.arePreferencesReady
      )
    } else if let blocked = appModel.summarizeUnavailableReason(
      usingCurrentCapture: false, detail: detail, preferencesReady: providerSettings.arePreferencesReady
    ) {
      reason = blocked
    } else {
      // 「要不要翻译」要对全文跑几遍正则数字母；这个属性一次重绘被读四五遍，长转写稿
      // 每次重绘都卡（2026-10-01 体检）。按这份正文 + 输出语言只算一次。
      let language = providerSettings.runPreferences.outputLanguage
      let needed = derivedMemo.value(
        "needsTranslation|\(detail.snapshots.count)|\(language)", snapshot: latestSnapshot
      ) {
        LayeredSourceDocument.needsTranslation(from: detail.snapshots, outputLanguage: language)
      }
      reason = needed ? nil : "原文已经是输出语言，不用翻译。"
    }
    if isUntranscribedMedia { return AppViewModel.untranscribedRunReason }
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
  /// 原文只有几句话：和翻译「无需翻译」同理，脑图按钮直接不出现（2026-10-03）。
  private var mindMapNotNeeded: Bool {
    mindMapUnavailableReason == HistoryViewModel.mindMapTooShortReason
  }
  /// 正文已经是输出语言：翻译不是「暂时不能做」，而是「不需要做」。这时按钮直接不出现，
  /// 不再留一颗永远灰着、要悬停才知道原因的「翻译」（2026-09-24 走查）。
  private var translationNotNeeded: Bool {
    translateUnavailableReason?.contains("无需翻译") == true
  }

  /// 一行说清为什么灰。两颗钮同一原因只写一次；总结能点、翻译不能时写翻译的原因。
  private var runActionBlockedReason: String? {
    if appModel.hasQueuedGeneration(for: detail.task.id) {
      return "已排队，等当前这条做完"
    }
    // 校对进行中时上面已经有一整条提示（进度、剩余时间、停止），这里再写「正在整理…」就重复了（2026-10-04 走查）。
    if model.transcriptTidyState(for: detail.task.id) == .running { return nil }
    if summarizeUnavailableReason != nil, translateUnavailableReason != nil {
      return summarizeUnavailableReason
    }
    return summarizeUnavailableReason ?? (translationNotNeeded ? nil : translateUnavailableReason)
      ?? (mindMapNotNeeded ? nil : mindMapUnavailableReason)
  }
  private var showsRunControls: Bool {
    canRunHistory
      || showsCurrentCapture
      || showsVisibleRun
      || appModel.canEnqueueManualGeneration(for: detail.task.id)
      || appModel.hasQueuedGeneration(for: detail.task.id)
  }
  private var presentsArticleBeforeMedia: Bool {
    if hasInlineArticleVideos { return true }
    guard let latestSnapshot else { return false }
    // 抖音、B站这类作品的主体是视频：播放器（或「暂不可播」状态卡）在上，配文在下。
    // 原来短配文会排到播放器前面，视频反而像附件。
    // 长转写仍置于播放器之后，避免把播放控件推离屏幕。
    // 长文（含旧记录里没有文中标记的）正文在前，避免播放器盖住目录。
    if isLongFormArticleCapture { return true }
    return derivedMemo.value("substantiveWeChat", snapshot: latestSnapshot) {
      RemoteMarkdownImageStagingPolicy.isSubstantiveWeChatArticle(
        platform: latestSnapshot.platform,
        markdown: latestSnapshot.bodyText
      )
    }
  }
  private var hasInlineArticleVideos: Bool {
    guard let snapshot = latestSnapshot else { return false }
    return derivedMemo.value("inlineVideos", snapshot: snapshot) {
      LocalMarkdownImageLayout.firstVideoMarkerRange(in: snapshot.bodyText) != nil
    }
  }
  /// 抖音、小红书这类作品的短配文不是文章：一句话用大号正文字排在开头很怪。
  /// 300 字以内的配文字号不超过 15pt；长文仍走用户选的阅读字号。
  /// 字体跟阅读字体走（2026-09-29 走查：小红书配文黑体、X 帖子宋体，换一条字体就变）。
  /// 所有来源的正文同一字体、同一字号。原来 300 字以内的社交短帖缩到 15 号，
  /// 小红书、知乎短回答和长文章并排看一大一小，像两个 App（2026-10-03 Syc 走查）。
  private func sourcePaneReadingFont(_ snapshot: ContentSnapshot) -> ResolvedReadingFont {
    readingFont
  }

  private var isVideoNativeWork: Bool {
    let platform = latestSnapshot?.platform
    if platform == "douyin" || platform == "bilibili" || platform == "x" || platform == "youtube" {
      return true
    }
    // 本机导入的录音 / 视频（语音备忘录、本地文件）主体也是媒体：播放器在上、转写在下。
    // 不排除的话，十几分钟的转写一过 1200 字就被当成长文，播放器被挤到全文末尾。
    if localMediaFileURL != nil, let platform, LocalImportSource(rawValue: platform) != nil {
      return true
    }
    return YouTubeWatchLink.videoID(from: sourceURL) != nil
  }
  private var isLongFormArticleCapture: Bool {
    guard let snapshot = latestSnapshot, !isVideoNativeWork else { return false }
    return derivedMemo.value("longForm", snapshot: snapshot) {
      let body = MarkdownNoteFrontmatter.parse(snapshot.bodyText).body
      return body.contains("\n## ") || body.count > 1_200
    }
  }
  private var suppressesEmbeddedMedia: Bool {
    latestSnapshot?.platform == "wechat" || hasInlineArticleVideos
  }
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
  /// 只列出真正有内容可读的面板。
  ///
  /// 页签是名词——「已经有的东西」。没跑过翻译就没有「翻译」页签；想要它，表头右边
  /// 有个写着「翻译」的按钮（动词）。两者分开之后，页签不必再为空态留位置。
  ///
  /// 总结和翻译各自独立出现：两者都有就是两格，只有一个就是一格。
  private var availableReadingPanes: [ReadingPane] {
    var panes: [ReadingPane] = []
    if summaryArtifact != nil || liveRunReadingPane == .summary { panes.append(.summary) }
    if translationArtifact != nil || liveRunReadingPane == .translation { panes.append(.translation) }
    if !isDouyinCapture || hasSourceBody || hasLiveTranscription || hasPresentableCaption {
      panes.append(.source)
    }
    return panes
  }
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
    // 菜单栏「内容」里的生成总结 / 翻译：原来这两个核心动作只能用鼠标点（2026-10-02 键盘走查）。
    scrollBody
      .focusedSceneValue(\.summarizeCurrent, isOwnWriting ? nil : RunCurrentAction { startRun(.summarize) })
      .focusedSceneValue(\.translateCurrent, isOwnWriting ? nil : RunCurrentAction { startRun(.translate) })
  }

  private static let detailTopAnchor = "history-detail-top"

  private var scrollBody: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
      // Title → URL → run/capture metadata (top) → action toolbar → reading → tags.
      VStack(alignment: .leading, spacing: 0) {
        // 换条目先回到这里，再由 ReadingScrollContinuity 恢复这一条自己读到的位置。
        // 详情视图不随条目重建，原来上一条的滚动偏移会带过来，没读过的条目也停在
        // 中间、标题被卷走（2026-10-03 Syc 走查）。
        Color.clear.frame(height: 0).id(Self.detailTopAnchor)
        if model.isReadOnly {
          ReadOnlyHistoryCallout(
            reason: model.historyReadOnlyReason,
            recoveryHint: model.historyReadOnlyRecoveryHint
          )
            .padding(.bottom, 16)
        }
        if let stampingStep {
          // 工序做完那一刻：对应的章盖下来（2026-09-28 工序印）。
          HStack(spacing: 12) {
            SealStampView(glyph: stampingStep.glyph, size: 32, color: theme.seal, rotation: stampingStep.rotation)
            VStack(alignment: .leading, spacing: 2) {
              Text(stampingStep.completionMessage)
                .themedFont(.callout, weight: .medium)
                .foregroundStyle(theme.primaryText)
              if let note = completedStepRecords.first(where: { $0.step == stampingStep })?.note, !note.isEmpty {
                Text(note).themedFont(.caption).foregroundStyle(theme.secondaryText)
              }
            }
          }
          .padding(.bottom, 12)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("history-step-stamp-banner")
          .transition(historyBannerTransition(reduceMotion: reduceMotion))
        } else if let completionBanner {
          Label(completionBanner, systemImage: "checkmark.circle.fill")
            .themedFont(.callout, weight: .medium)
            .foregroundStyle(theme.success)
            .padding(.bottom, 10)
            .accessibilityIdentifier("history-run-completion-banner")
            .transition(historyBannerTransition(reduceMotion: reduceMotion))
        }
        // 成功有横幅，失败和中断原来什么都不显示——状态只落在详情下方一个被动的
        // 元数据字段上。关 App 时被打断的那次翻译，表现就是「点了没反应」。
        if completionBanner == nil, stampingStep == nil, let notice = UnfinishedRunNotice.latest(in: detail.runs) {
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
        // 来源信息和互动数放得下就同一行（2026-10-04 详情页精简：原来来源一行、互动一行、
        // 视频时长体积又一行）；窄了互动数退到下一行。
        if !isOwnWriting, sourceFrontmatter.hasEngagementStats {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
              sourceByline.fixedSize(horizontal: true, vertical: false)
              engagementDisclosure(sourceFrontmatter)
              Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
              sourceByline
              engagementDisclosure(sourceFrontmatter)
            }
          }
          .padding(.top, DesignTokens.Space.sm)
        } else if !isOwnWriting {
          sourceByline
            .padding(.top, DesignTokens.Space.sm)
        } else if sourceFrontmatter.hasEngagementStats {
          engagementDisclosure(sourceFrontmatter)
            .padding(.top, DesignTokens.Space.xs)
        }
        // 分类信息（归属 · 素材类型 · 标签）紧跟标题：原来收在整页最后，长转写稿要滚一万多点
        // 才能看到、改到（2026-09-24 走查）。笔记输入框仍在页尾——想法是读完才有的。
        classificationBar
          .padding(.top, DesignTokens.Space.sm)
        // 首次设置横条还在时它已经说了「配置模型」，这里不再说第二遍（2026-10-02 新用户走查）。
        if !providerSettings.hasConfiguredAPIKey, isCaptureOnboardingDismissed {
          Button(action: openSettings) {
            Label("还没配置模型 · 去配置", systemImage: "sparkles")
              .themedFont(.callout, weight: .medium)
          }
          .buttonStyle(.borderless)
          .padding(.top, DesignTokens.Space.sm)
          .accessibilityIdentifier("history-unconfigured-model-banner")
        }
        // 正文表头跟着正文走（见 readingSurface）：视频之后、正文之前。
        // 只有没有任何正文可读、却还有事可做时（比如刚抓到、正文还没落库的当前抓取），
        // 才退回标题下面这个位置——否则按钮没地方放。
        if !isOwnWriting, !showsReadingSurface, showsRunControls {
          actionToolbar
            .padding(.top, DesignTokens.Space.lg)
          Divider().padding(.top, DesignTokens.Space.sm)
        }

        if presentsArticleBeforeMedia, showsReadingSurface {
          readingSurface
            // 笔记 16：首行标题藏掉后（见 displayedSourceMarkdown），正文第一段直接贴着分类行，
            // 原来那段间距是标题自带的上边距（2026-10-01 自查）。
            .padding(.top, isOwnWriting ? DesignTokens.Space.lg : 18)
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
              model: model
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
          } else if model.localMediaCleared, detail.media != nil {
            // 按「转写后清理」删掉的视频：只是说明一下，不是出错。原链接一直在，
            // 需要时用它换一个新的播放地址，再走「保存到本地」下回来。
            videoFetchNotice(.cleared)
          } else if isUnsavedXVideo {
            // 推文明明是视频（封面是 video_thumb），本机却没有文件：保存时下载失败了
            // （2026-10-03：2K 视频超出下载上限，失败后整块消失，看着像这条没有视频）。
            videoFetchNotice(.notSaved)
          } else if let missing = model.localMediaOriginalMissing, missing.taskID == detail.task.id {
            // 本机导入的音视频只引用原文件（2026-09-29）：原文件不在了就说清楚去哪找、怎么接回来。
            VStack(alignment: .leading, spacing: 8) {
              Label(
                missing.fileName.map { "找不到原文件「\($0)」" } ?? "找不到原文件",
                systemImage: "questionmark.folder"
              )
              .foregroundStyle(theme.warning)
              Text("它可能被删除、移到了别的磁盘，或者所在的移动硬盘没有连接。转写文字、总结和笔记都还在，不受影响。接上硬盘后重新打开这条即可；文件换了位置就点「重新定位…」找到它。")
                .themedFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              if let path = missing.lastKnownPath {
                Text("原来的位置：\(path)")
                  .themedFont(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(2)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
              }
              HStack(spacing: DesignTokens.Space.sm) {
                Button {
                  let panel = NSOpenPanel()
                  panel.title = "重新定位原文件"
                  panel.prompt = "就是它"
                  panel.message = "找到「\(missing.fileName ?? "原文件")」现在的位置。只接受和当初导入的同一份文件。"
                  panel.allowsMultipleSelection = false
                  panel.canChooseDirectories = false
                  panel.canChooseFiles = true
                  if let path = missing.lastKnownPath {
                    panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
                  }
                  guard panel.runModal() == .OK, let url = panel.url else { return }
                  model.relocateOriginalMedia(to: url)
                } label: {
                  if model.originalRelocationState == .verifying {
                    HStack(spacing: 6) {
                      ProgressView().controlSize(.small)
                      Text("正在核对…")
                    }
                  } else {
                    Label("重新定位…", systemImage: "scope")
                  }
                }
                .buttonStyle(.appNormal)
                .disabled(model.originalRelocationState == .verifying || model.isReadOnly)
                .accessibilityIdentifier("history-media-original-relocate")
              }
              if case let .failed(message) = model.originalRelocationState {
                Text(message)
                  .themedFont(.caption)
                  .foregroundStyle(theme.warning)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .padding(.top, 14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history-media-original-missing")
          } else if let failure = model.localMediaResolutionFailure {
            VStack(alignment: .leading, spacing: 8) {
              Label(failure, systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(theme.warning)
              Text("请在「设置 → 视频存储」重新选择文件夹，或把已保存的视频移回原位置。")
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
            // 笔记 16：首行标题藏掉后（见 displayedSourceMarkdown），正文第一段直接贴着分类行，
            // 原来那段间距是标题自带的上边距（2026-10-01 自查）。
            .padding(.top, isOwnWriting ? DesignTokens.Space.lg : 18)
        }

        if isOwnWriting, showsRunControls,
           showsVisibleRun || latestSnapshot.map({ !storedNoteBody($0).isEmpty }) == true {
          // 笔记：正文先行；整理/生成不挡编辑。
          noteActionToolbar
            .padding(.top, DesignTokens.Space.lg)
            .accessibilityIdentifier("history-action-toolbar")
        }

        // 脑图是正文的衍生输出，不再挡在阅读内容前面。先读总结／翻译／原文，
        // 再按需查看结构；视频条目仍保持「播放器 → 文字 → 脑图」的顺序。
        // 自己写的东西不挂脑图空状态，避免催促用户对刚写的几行字做结构化。
        if !isOwnWriting {
          MindMapSectionView(taskID: detail.task.id, model: model)
            .padding(.top, DesignTokens.Space.xl)
            .id(ReadingAnchor.module("mindmap"))
        }

        // 导入的图片在落库时已经识别过：不再挂识别卡，改成一条收起的文字小节。
        if let snapshot = latestSourceSnapshot, isImportedImage(snapshot),
           let text = LocalImportDocument.splitImageBody(snapshot.bodyText).recognizedText {
          importedImageTextSection(text)
            .padding(.top, 16)
        } else if !localImageURLs.isEmpty, latestSourceSnapshot.map(isImportedImage) != true {
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
        // 没有摘录时整块不挂：空的 VStack 也吃掉上边距，正文和「添加笔记」之间就空出一大段。
        if !isOwnWriting, !model.taskExcerpts.isEmpty || model.annotationFailureMessage != nil {
          AnnotationSectionView(taskID: detail.task.id, model: model, showsNoteEditor: false)
            .padding(.top, 20)
            .id(ReadingAnchor.module("annotations"))
        }

        // 笔记是读完之后的产物：想法读完才有，所以输入框收在整页最后。
        // 标签和素材类型已移到标题下（classificationBar）。
        if !isOwnWriting {
          noteBar
            .padding(.top, DesignTokens.Space.xl)
          ColophonView(
            text: colophonText,
            link: colophonDownloadSource?.link,
            records: completedStepRecords,
            dateHelp: colophonGregorianHelp,
            readingFont: readingFont,
            secondaryTextColor: theme.secondaryText,
            sealColor: theme.seal,
            hairline: theme.hairline,
            onSelect: { step in openStep(step) }
          )
          // 落款「丙午年九月初八日」很多人看不懂（2026-10-01 走查）：样式不动，悬停给公历日期。
          // 只挂在落款文字上、立刻出（2026-10-03）：原来 `.help` 挂在整块上，要停一秒多才出来。
        }
      }
      // 常规列表保留较宽上限；专注阅读收窄到约 760pt 并居中。
      .frame(
        maxWidth: readingContentMaxWidth,
        alignment: .leading
      )
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, DesignTokens.Layout.readingHorizontalInset)
      // 第一行和中间列搜索框、侧栏「全部」同一高度；原来 32pt 加上工具栏留白，标题位空出一大块。
      .padding(.top, 4)
      .padding(.bottom, 48)
      .subtleScrollers()
    }
    .popover(
      isPresented: $isRegeneratePopoverPresented,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .top
    ) { regeneratePopover }
    .coordinateSpace(name: HistoryDetailView.readingScrollSpace)
    .overlay(alignment: .top) {
      if isReadingHeaderPinned, !isOwnWriting, showsReadingSurface {
        pinnedReadingHeader
      }
    }
    // 视频滚出视野还在播：右下角小窗接着放。放右上角时盖住正在读的那几行的行尾
    //（2026-10-04 实测），右下角是读者视线最少停留的地方。
    .overlay(alignment: .bottomTrailing) {
      MiniVideoPlayerOverlay()
        .padding(.bottom, 16)
        .padding(.trailing, 16 + SubtleScroller.trackWidth)
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
      // 换一条就回到校对稿：朱批是偶尔核对用的，不该带到下一条。
      manuscriptMode = .revised
      // 换条目：记下这一条已有的工序当底数，之后新做完的才盖章。
      stampBaseline = (detail.task.id, completedStepStamps)
      stampingStep = nil
      isProcessPanelPresented = false
      loadTranscriptParagraphs()
      model.loadReformat(taskID: detail.task.id)
      completionBanner = nil
      pendingRunPane = nil
      isCaptionExpanded = false
      isTranscriptExpanded = false
      isImportedImageTextExpanded = false
      isInlineNoteRequested = false
      isSubtitleExpanded = false
      selectedSourceLayer = nil
      selectedTranslationLayer = nil
      // 页签、保活集合、标题高度都按条目记（见 `readingPaneChoice`），换条目不用在这里改回默认。
      // 保活集合不跨条目：上一条访问过哪些面板不该让这一条多付隐藏布局。
      pendingSourceCitation = nil
      ReadingSelectionRouter.shared.formatter = { selected in
        ReadingCitationFormatter.format(selection: selected, title: readingPrimaryTitle, sourceURL: sourceURL)
      }
      isTitleExpanded = false
      // 切换条目时丢弃未保存的转写草稿，避免草稿串到别的记录。
      isEditingTranscription = false
      transcriptionDraft = ""
      sourceEditCaretUTF16 = 0
      // 有正文的笔记先看排版，点字再写；新建的空笔记直接进入编辑。
      if isOwnWriting, let snapshot = latestSnapshot {
        let body = storedNoteBody(snapshot)
        transcriptionDraft = body
        editingNote = (detail.task.id, snapshot.id, body)
        if body.isEmpty, !isInTrash { isEditingTranscription = true }
      }
      noteTitleDraft = DailyNoteTitleFormat.display(title)
      // 没起过标题的笔记，标题栏先显示正文第一行（2026-10-01 Syc 走查：正文开头明明是
      // 「Claude 的使用和付费指南」，标题却一直是「无标题笔记」）。只填进输入框，不落库；
      // 用户点进标题改过、或保存正文时，才按原来的路径写回。
      if isUserNote, let snapshot = latestSnapshot,
         let derived = UserNoteDocument.displayTitle(stored: title, body: storedNoteBody(snapshot)) {
        noteTitleDraft = derived
      }
      // 清洗规则是后加的，早先存下的标题里还留着 U+FFFC 那类显示成方块的字符。
      // 打开时顺手修掉：它们不是内容，用户也删不掉（光标跳过去像没东西）。
      if isOwnWriting {
        let cleaned = UserNoteDocument.sanitizedTitle(title)
        if !cleaned.isEmpty, cleaned != title, !DailyNoteTitleFormat.isISODateTitle(title) {
          model.renameNote(taskID: detail.task.id, title: cleaned)
          noteTitleDraft = DailyNoteTitleFormat.display(cleaned)
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
      Button("知道了") { model.dismissSnapshotEditFailure() }
    } message: { Text(model.snapshotEditFailure ?? "") }
    .onChange(of: hasResultBody) { _, hasResult in
      // Prefer the fresh result when a run lands, but keep 原文 one tap away.
      // 只管「同一条刚出了结果」：换条目时这个值也会变，但新的一条本来就落在默认页签上，
      // 这里再写一次只会让整页多重算一遍（2026-10-05）。清掉手选，页签就回到默认。
      guard hasResult, readingPaneChoice?.taskID == detail.task.id else { return }
      readingPaneChoice = nil
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
        // 上一条／下一条原来是工具栏最前面的两个按钮。工具栏一排九个图标分不清
        // 主次，而它们有 ⌘↑ / ⌘↓，鼠标入口收进「更多」菜单就够了。

        // 阅读设置（字号）和专注阅读 2026-09-23 收进下面的「更多」：顶栏只留收藏、标签、更多。
        // 标签按钮（2026-10-01）撤掉：标题下面那行已经有「添加标签」，两处做同一件事。
        if model.canToggleFavorite {
          ControlGroup {
            let favorited = model.isSelectedFavorite
            Button { model.toggleFavorite() } label: {
              Label(
                favorited ? "取消收藏" : "收藏",
                systemImage: favorited ? "star.fill" : "star")
            }
            .help(favorited ? "取消收藏" : "收藏")
            .accessibilityLabel(favorited ? "取消收藏" : "收藏")
            .accessibilityIdentifier("reading-toggle-favorite")
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
          // 收藏（顶栏星标、⌘D）、改为自有 / 外部（标题下的归属标签）、上一条 / 下一条（⌘↑ / ⌘↓，
          // 菜单栏「显示」里也有）各有固定入口，不再在这里重复（2026-10-04 详情页精简）。
          // 阅读相关六项收进一个子菜单，菜单从 21 项减到 10 项上下。
          Menu {
            Button(action: toggleFocusReading) {
              Label(
                isFocusReading ? "退出专注阅读" : "专注阅读",
                systemImage: isFocusReading ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
              )
            }
            .accessibilityIdentifier("history-focus-reading-toggle")
            if hasReadableBody {
              Button {
                adjustReadingFontSize(by: ReadingFontSize.step)
              } label: {
                Label("放大正文字号", systemImage: "textformat.size.larger")
              }
              .disabled(readingFontSizeRaw >= Double(ReadingFontSize.maximum))
              .accessibilityIdentifier("reading-font-larger")
              Button {
                adjustReadingFontSize(by: -ReadingFontSize.step)
              } label: {
                Label("缩小正文字号", systemImage: "textformat.size.smaller")
              }
              .disabled(readingFontSizeRaw <= Double(ReadingFontSize.minimum))
              .accessibilityIdentifier("reading-font-smaller")
              Button {
                readingFontSizeRaw = Double(ReadingFontSize.default)
              } label: {
                Label("恢复默认字号（当前 \(Self.readingFontSizeLabel(readingFontSizeRaw))）", systemImage: "textformat.size")
              }
              .disabled(abs(readingFontSizeRaw - Double(ReadingFontSize.default)) < 0.01)
              .accessibilityIdentifier("reading-font-reset")
            }
            Toggle(isOn: $readingUsesWideLayout) { Label("加宽正文（⌥⌘\\）", systemImage: "arrow.left.and.right") }
              .accessibilityIdentifier("reading-wide-layout-toggle")
            // 纯文本是「怎么看」，不是「怎么复制」：原来放在「复制」一组里，找不到（2026-09-25 走查）。
            Toggle(isOn: $showsPlainText) { Label("以纯文本查看正文", systemImage: "text.alignleft") }
              .accessibilityIdentifier("history-content-plain-text-toggle")
          } label: {
            Label("阅读设置", systemImage: "textformat")
          }
          .accessibilityIdentifier("history-reading-settings-menu")
          // 合集：「加入合集 ▸」和（正在看某个合集时）「从此合集移出」，和列表右键同一份。
          if model.canEditCollections, model.selectedScope != .trash {
            Section {
              CollectionMenuItems(model: model, taskIDs: [detail.task.id])
            }
          }
          Section("复制") {
            Button { copyFullArticle() } label: { Label("复制全文", systemImage: MenuIcon.copy) }
              .accessibilityIdentifier("history-copy-full-text")
          }
          Section("导出") {
            Button { exportCleanText(.markdown) } label: { Label("导出 Markdown (.md)", systemImage: MenuIcon.export) }
            Button { exportCleanText(.plainText) } label: { Label("导出纯文本 (.txt)", systemImage: MenuIcon.export) }
            Button { exportStyledDocument(.pdf) } label: { Label("导出 PDF (.pdf)", systemImage: MenuIcon.export) }
              .accessibilityIdentifier("history-export-pdf")
            Button { exportStyledDocument(.docx) } label: { Label("导出 Word (.docx)", systemImage: MenuIcon.export) }
              .accessibilityIdentifier("history-export-docx")
            Button { model.requestExport(.json) } label: { Label("导出完整数据 (.json)", systemImage: MenuIcon.export) }
          }
          // 「换个模型重跑…」是对这条内容做的 AI 动作，和重新总结、重新翻译
          // 一起收在正文表头的「处理」菜单里，不再和导出、删除混在窗口工具栏。
          // 只有能重抓时才出这一组：原来无条件画分组标题，本地文件上只剩一行灰字标题（2026-09-25）。
          if canRecaptureSource {
            Section("重新处理") {
              Button { openRecapture(sourceURL) } label: { Label("重新抓取原文…", systemImage: MenuIcon.recapture) }
                .accessibilityIdentifier("history-recapture-source")
            }
          }
          Section {
            Button(role: .destructive) {
              model.requestDeletion(protectedTaskIDs: protectedTaskIDs)
            } label: {
              Label(model.deletionConfirmationActionTitle, systemImage: MenuIcon.trash)
            }
            .disabled(!model.canDelete(protectedTaskIDs: protectedTaskIDs))
            .foregroundStyle(theme.danger)
            .accessibilityIdentifier("delete-history")
          }
        } label: {
          Label("更多", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("阅读设置、加入合集、复制、导出、重新抓取或删除当前条目")
        .accessibilityLabel("更多")
        .accessibilityIdentifier("export-history")
      }
    }
    .accessibilityIdentifier("history-detail")
    .sheet(isPresented: $isCommentPickerPresented) {
      if let url = commentSourceURL {
        CommentPickerSheet(url: url, title: title, onSave: { selected, expected in
          saveSelectedComments(selected, expectedCount: expected)
          isCommentPickerPresented = false
        }, onCancel: { isCommentPickerPresented = false })
      }
    }
    .onChange(of: model.transcriptTidyState(for: detail.task.id) == .completed) { _, completed in
      guard completed else { return }
      let taskID = detail.task.id
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { recentlyCompletedTidyTaskID = taskID }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard recentlyCompletedTidyTaskID == taskID else { return }
        withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { recentlyCompletedTidyTaskID = nil }
      }
    }
    // 挂在详情根上：入口挪进「处理」面板后，说话人那一栏没分过时不在页面上。
    .alert("在线区分说话人", isPresented: $isOnlineDiarizationConfirmPresented) {
      Button("取消", role: .cancel) {}
      Button("上传并区分") { model.diarizeSpeakers(detail: detail, mode: .online) }
    } message: {
      Text("会把这段录音上传到你在「设置 → 模型」里配置的在线服务（模型名带 diarize 的那个），按录音时长计费。在线结果会替换当前的转写文字。")
    }
    .onChange(of: sourceCollapseScrollTarget) { _, target in
      guard let target else { return }
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        scrollProxy.scrollTo(target, anchor: .top)
      }
      sourceCollapseScrollTarget = nil
    }
    .onChange(of: moduleScrollTarget) { _, target in
      guard let target else { return }
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        scrollProxy.scrollTo(target, anchor: .top)
      }
      moduleScrollTarget = nil
    }
    .onChange(of: completedStepStamps) { _, steps in
      noteCompletedSteps(steps)
    }
    .onChange(of: detail.task.id) { _, _ in
      scrollProxy.scrollTo(Self.detailTopAnchor, anchor: .top)
    }
    } // ScrollViewReader
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
  /// 拼装逻辑在 `ReadingDocumentExport`（与界面共用，可测试）；这里只负责弹面板落盘。
  private func exportCleanText(_ format: HistoryExportFormat) {
    guard let composed = model.composeExportMarkdown() else { return }
    let ext = format == .plainText ? "txt" : "md"
    let finalContent = ReadingDocumentExport.cleanTextExport(
      composedMarkdown: composed.markdown,
      format: format,
      context: exportColophonContext
    )
    guard let data = finalContent.data(using: .utf8), !data.isEmpty else { model.failExportSave(); return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "\(composed.baseFilename).\(ext)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url) } catch { model.failExportSave() }
  }

  private func exportStyledDocument(_ kind: StyledExportKind) {
    guard let composed = model.composeExportMarkdown() else { return }
    let attributed = ReadingDocumentExport.styledDocument(
      composedMarkdown: composed.markdown,
      context: exportColophonContext,
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
  /// to several hundred characters. Capture titles default to at most three lines;
  /// overflow is recovered via「展开标题 / 收起标题」instead of an in-title scroller.
  /// Note titles keep the existing editable field (22pt bold).
  private static let noteTitleFontSize: CGFloat = 22
  /// 26pt：自有风格下标题用阅读字体（默认宋体），比正文大出一截，页头才立得住。
  private static let captureTitleFontSize: CGFloat = 26
  /// 26pt 宋体 / 苹方半粗的实测行高（NSLayoutManager.defaultLineHeight）是 37。
  /// 原来写 28（22pt 时代的值），三行标题实高超线，没被截断也会冒出「展开标题」。
  private static let captureTitleLineHeight: CGFloat = 37
  /// 多留半行余量，吸收不同字体行高的小差异；四行（148）仍稳稳超线。
  private static var captureTitleMaximumHeight: CGFloat { captureTitleLineHeight * 3.5 }

  private var titleExceedsCollapsedLimit: Bool {
    measuredTitleHeight > Self.captureTitleMaximumHeight
  }

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
    if isOwnWriting, isInTrash {
      Text(noteTitleDraft.isEmpty ? UserNoteDocument.untitledTitle : noteTitleDraft)
        .font(readingFont.font(size: Self.noteTitleFontSize, weight: .medium))
        .foregroundStyle(theme.primaryText)
        .tracking(-0.4)
        .lineLimit(1...3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history-detail-title")
    } else if isOwnWriting {
      // 自己写的东西标题就地可改。抓取记录的标题保持只读——那是抓来的事实。
      TextField(UserNoteDocument.untitledTitle, text: $noteTitleDraft)
        .textFieldStyle(.plain)
        .font(readingFont.font(size: Self.noteTitleFontSize, weight: .medium))
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
    } else if !hidesRepeatedCaptureHeading {
      VStack(alignment: .leading, spacing: 4) {
        Text(readingPrimaryTitle)
          .font(readingFont.font(size: Self.captureTitleFontSize, weight: .medium))
          .foregroundStyle(theme.primaryText)
          .tracking(-0.4)
          .lineLimit(isTitleExpanded ? nil : 3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background {
            // 隐藏测量完整理想高度：可见标题可被 lineLimit 截断，测量副本不受限。
            Text(readingPrimaryTitle)
              .font(readingFont.font(size: Self.captureTitleFontSize, weight: .medium))
              .tracking(-0.4)
              .fixedSize(horizontal: false, vertical: true)
              .hidden()
              .accessibilityHidden(true)
              .background(
                GeometryReader { proxy in
                  Color.clear.preference(key: TitleHeightPreferenceKey.self, value: proxy.size.height)
                }
              )
          }
          .onPreferenceChange(TitleHeightPreferenceKey.self) { height in
            guard height > 0, height != measuredTitleHeight else { return }
            measuredTitleHeightStore = PerItem(taskID: detail.task.id, value: height)
          }
          .accessibilityIdentifier("history-detail-title")
        if titleExceedsCollapsedLimit {
          Button(isTitleExpanded ? "收起标题" : "展开标题") {
            isTitleExpanded.toggle()
          }
          .buttonStyle(.link)
          .themedFont(.callout, weight: .medium)
          .padding(.top, 2)
          .accessibilityIdentifier("history-detail-title-expand")
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

  /// 笔记：整理排版直达，不挡正文；可选 AI 菜单不抢编辑焦点。
  private var noteActionToolbar: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      HStack(spacing: DesignTokens.Space.sm) {
        actionPill(
          title: "整理排版",
          systemImage: MenuIcon.reformat,
          prominent: true,
          disabled: !model.canTidyNote(taskID: detail.task.id),
          identifier: "tidy-note"
        ) {
          model.requestNoteTidy(taskID: detail.task.id, model: providerSettings.effectiveTidyModelName)
        }
        .help(model.noteTidyUnavailableReason(taskID: detail.task.id) ?? "把段落、列表和标题层级整理一遍，不改文字内容")
        noteTidyStatus
        Spacer(minLength: DesignTokens.Space.sm)
        if showsVisibleRun {
          if appModel.canStopVisibleRun(for: detail.task.id) {
            Button("停止", role: .cancel) { Task { await appModel.stop() } }
              .controlSize(.mini)
              .help("停止当前生成")
              .accessibilityLabel("停止当前生成")
              .accessibilityIdentifier("stop-model-run")
          }
          if appModel.runState.isActive {
            ProgressView().controlSize(.mini)
          }
          Text(appModel.runStatusText)
            .themedFont(.caption, weight: .medium)
            .foregroundStyle(appModel.runHasFailure ? theme.danger : Color.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("model-run-status")
          // 阅读区可能停在别的页签，那时这一行是唯一还看得见运行状态的地方。
          if appModel.runState.isActive, let startedAt = appModel.runStartedAt {
            RunElapsedLabel(startedAt: startedAt)
              .themedFont(.caption, weight: .medium, monospacedDigit: true)
          }
        }
        if canRunHistory || showsVisibleRun {
          aiProcessingMenu
        }
      }
      if let runActionBlockedReason {
        Text(runActionBlockedReason)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .accessibilityIdentifier("history-run-blocked-reason")
      }
      if isRunPanelExpanded {
        captureAndRunControlsExtras
          .transition(historyBannerTransition(reduceMotion: reduceMotion))
      }
    }
  }

  private var aiProcessingMenu: some View {
    Menu {
      Button {
        Task {
          let started = await appModel.summarize(
            historyDetail: detail,
            preferences: providerSettings.runPreferences
          )
          engageReadingPane(.summary, started: started)
        }
      } label: {
        Label(
          appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .summarize)
            ? "已排队总结" : (summaryArtifact == nil ? "生成总结" : "重新生成总结"),
          systemImage: MenuIcon.summarize
        )
      }
      .disabled(summarizeUnavailableReason != nil)
      .accessibilityIdentifier(showsCurrentCapture ? "summarize-current-capture" : "summarize-history-detail")

      Button {
        Task {
          let started = await appModel.translate(
            historyDetail: detail,
            preferences: providerSettings.runPreferences
          )
          engageReadingPane(.translation, started: started)
        }
      } label: {
        Label(
          appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .translate)
            ? "已排队翻译" : (translationArtifact == nil ? "生成翻译" : "重新生成翻译"),
          systemImage: "character.book.closed"
        )
      }
      .disabled(translateUnavailableReason != nil)
      .help(
        appModel.translationUnavailableReason(
          snapshots: detail.snapshots,
          outputLanguage: providerSettings.runPreferences.outputLanguage
        ) ?? "把当前正文翻译为\(providerSettings.runPreferences.outputLanguage)"
      )
      .accessibilityIdentifier(showsCurrentCapture ? "translate-current-capture" : "translate-history-detail")

      if !isOwnWriting, model.mindMapRecord?.taskID != detail.task.id, !mindMapNotNeeded {
        Button {
          if appModel.canEnqueueManualGeneration(for: detail.task.id)
            || appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap) {
            appModel.enqueueOrCancelMindMapGeneration(taskID: detail.task.id)
          } else {
            model.requestMindMapGeneration(taskID: detail.task.id)
          }
        } label: {
          Label(
            appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap) ? "已排队脑图" : "生成脑图",
            systemImage: "brain"
          )
        }
        .disabled(mindMapUnavailableReason != nil)
        .help(
          mindMapUnavailableReason
            ?? (appModel.isManualGenerationQueued(taskID: detail.task.id, kind: .mindMap)
              ? "再点一次取消排队"
              : "把正文发给模型提取结构")
        )
        .accessibilityIdentifier("mind-map-generate")
      }

      // 「整理文稿」只对 2000 字以上、还没分节的长文显示。短帖看不到入口会以为功能没了，
      // 这里留一条灰项说明原因，功能的存在感不随内容长短消失。
      if !isOwnWriting, let snapshot = detail.snapshots.last {
        let eligibility = reformatEligibility(snapshot)
        if !eligibility.canReformat, let message = eligibility.userMessage {
          Button {} label: { Label("整理排版：\(message)", systemImage: "text.append") }
            .disabled(true)
            .accessibilityIdentifier("history-reformat-unavailable")
        }
      }

      Divider()
      if let runActionBlockedReason { Text(runActionBlockedReason) }

      if !providerSettings.arePreferencesReady {
        Button { openSettings() } label: { Label("设置模型", systemImage: MenuIcon.settings) }
          .accessibilityIdentifier("history-open-model-settings")
      } else if !showsVisibleRun {
        let modelName = providerSettings.activeSummaryModelName.isEmpty
          ? "模型未命名"
          : "模型：\(providerSettings.activeSummaryModelName)"
        Button(modelName) {}
          .disabled(true)
      }

      if canRunHistory || showsCurrentCapture || isRunPanelExpanded || hasCollapsedRunMetadata {
        Button(isRunPanelExpanded ? "收起生成记录" : "生成记录") {
          withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isRunPanelExpanded.toggle() }
        }
        .accessibilityIdentifier("history-run-panel-toggle")
      }
    } label: {
      // 和文章页右上的「处理」同名同图标（2026-09-29 走查：原来这里叫「AI 处理」，两处叫法不一）。
      Label("处理", systemImage: "wand.and.stars")
        .themedFont(.callout, weight: .medium)
        .padding(.horizontal, DesignTokens.Space.sm)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .strokeBorder(theme.primaryText.opacity(0.15))
        )
    }
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .fixedSize()
    .help("总结、翻译与脑图")
    .accessibilityLabel("处理")
    .accessibilityIdentifier("history-ai-processing-menu")
  }

  /// 没有正文可读时的兜底位置用的还是同一个表头。
  private var actionToolbar: some View {
    readingHeaderRow(pinned: false)
  }

  // MARK: - 正文表头：看什么 / 做什么

  /// 表头左边的页签：这条内容**已经有**的每一份文字，全平级。
  ///
  /// 「配文」「转写」不再藏在「原文」下面当二级。用户看它们和看总结、翻译是同一个
  /// 动作——换一份读——那就该是同一排、同一种样子。原文只有一层时仍叫「原文」。
  private enum ReadingTab: Hashable, Identifiable {
    case source(SourceLayer?)
    /// 校对过的转写稿的机器原稿：和「校对稿」平级的一个页签（2026-10-04 详情页精简，
    /// 原来是「原文」页签里面再分一排「校对稿 / 原稿」）。
    case sourceOriginal
    case summary
    case translation
    var id: String {
      switch self {
      case .sourceOriginal: "source-original"
      case let .source(layer): "source-\(layer?.rawValue ?? "single")"
      case .summary: "summary"
      case .translation: "translation"
      }
    }
  }

  /// 顺序：原文各层 → 总结 → 翻译。先是抓来的，再是模型做出来的。
  private var readingTabs: [ReadingTab] {
    var tabs: [ReadingTab] = []
    if availableReadingPanes.contains(.source) {
      if showsSourceLayerPicker {
        tabs += availableSourceLayers.map { ReadingTab.source($0) }
      } else {
        tabs.append(.source(nil))
        if splitsManuscriptTabs { tabs.append(.sourceOriginal) }
      }
    }
    if availableReadingPanes.contains(.summary) { tabs.append(.summary) }
    if availableReadingPanes.contains(.translation) { tabs.append(.translation) }
    return tabs
  }

  private var activeReadingTab: ReadingTab {
    switch effectiveReadingPane {
    case .summary: .summary
    case .translation: .translation
    case .source:
      splitsManuscriptTabs && manuscriptMode == .original
        ? .sourceOriginal
        : .source(showsSourceLayerPicker ? activeSourceLayer : nil)
    }
  }

  private func readingTabTitle(_ tab: ReadingTab) -> String {
    switch tab {
    case let .source(layer):
      layer?.tabTitle ?? (singlePaneTranscriptSnapshot != nil
        ? (splitsManuscriptTabs ? TranscriptManuscript.Mode.revised.title : "转写稿")
        : (singleSourceIsCaption ? SourceLayer.caption.tabTitle : "原文"))
    case .sourceOriginal: TranscriptManuscript.Mode.original.title
    case .summary: "总结"
    case .translation: "翻译"
    }
  }

  private func selectReadingTab(_ tab: ReadingTab) {
    switch tab {
    case let .source(layer):
      readingPane = .source
      selectedSourceLayer = layer
      if manuscriptMode == .original { manuscriptMode = .revised }
    case .sourceOriginal:
      readingPane = .source
      manuscriptMode = .original
    case .summary: readingPane = .summary
    case .translation: readingPane = .translation
    }
  }

  static let readingScrollSpace = "history-reading-scroll"

  /// 正文表头：左边「看哪一份」，右边「还能做什么」。
  ///
  /// 三条规则：动词归动词、名词归名词，各一组各一种样子；页签只列已经有的，
  /// 按钮只列还能做的；做完一件事，按钮消失、页签出现——这就是状态，不另写
  /// 一行「已完成 xx」。
  ///
  /// 位置在视频之后、正文之前：顶部留给标题、作者、视频这些信息，表头紧贴着它
  /// 所控制的那段文字。滚过去以后由 `pinnedReadingHeader` 吸在正文区顶端，
  /// 读到哪里都不用滚回来切换。
  @ViewBuilder private func readingHeaderRow(pinned: Bool) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
        readingTabStrip(pinned: pinned)
        if effectiveReadingPane == .source { reformatToggle }
        Spacer(minLength: DesignTokens.Space.md)
        if effectiveReadingPane == .source, splitsManuscriptTabs { manuscriptMarkToggle }
        readingVerbs(pinned: pinned)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !pinned {
        readingHeaderStatusLines
        if isRunPanelExpanded {
          captureAndRunControlsExtras
            .transition(historyBannerTransition(reduceMotion: reduceMotion))
        }
      }
    }
    .accessibilityIdentifier(pinned ? "history-action-toolbar-pinned" : "history-action-toolbar")
  }

  /// 滚过表头之后吸在正文区顶端的那份。只有页签和按钮，不带状态行和运行详情。
  private var pinnedReadingHeader: some View {
    readingHeaderRow(pinned: true)
      .padding(.vertical, DesignTokens.Space.xs)
      .frame(maxWidth: readingContentMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, DesignTokens.Layout.readingHorizontalInset)
      // 吸顶表头叠在滚动区外面，而正文那份在滚动区里面——常驻滚动条占着右边 11pt。
      // 不扣掉这一条，表头一吸顶右边的按钮就往右跳 11pt（2026-09-24 走查）。
      .padding(.trailing, SubtleScroller.trackWidth)
      // 实底，不用 `.bar`：半透明材质下正文从页签底下透出来，被切成半行（2026-09-29 走查）。
      // 底色一直铺到窗口顶、盖住工具栏那段：只铺表头自己时，工具栏的半透明渐变和实底
      // 表头之间露出一条缝，封面大图滚上去会被夹成一条彩色碎片（2026-09-29 Syc 截图）。
      .background {
        Group {
          if theme.isNative {
            Rectangle().fill(.background)
          } else {
            theme.card
          }
        }
        .ignoresSafeArea(edges: .top)
      }
      .overlay(alignment: .bottom) { Divider() }
      .accessibilityIdentifier("history-reading-header-pinned")
  }

  /// 页签用文字加下划线，不用分段控件——和右边的按钮一眼分得开：文字是「看」，
  /// 框起来的是「做」。
  ///
  /// 下划线滑到新页签，而不是原地消失、另一处出现（2026-10-04 走查）。
  private func readingTabStrip(pinned: Bool) -> some View {
    HStack(spacing: DesignTokens.Space.md) {
      ForEach(readingTabs) { tab in
        let isActive = tab == activeReadingTab
        let title = readingTabTitle(tab)
        Button {
          selectReadingTab(tab)
        } label: {
          Text(title)
            .themedFont(.callout, weight: isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)
            .padding(.bottom, 3)
            .anchorPreference(key: ReadingTabBoundsKey.self, value: .bounds) { isActive ? $0 : nil }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "正在看\(title)" : "切换到\(title)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("history-reading-tab-\(tab.id)")
      }
    }
    .overlayPreferenceValue(ReadingTabBoundsKey.self) { anchor in
      GeometryReader { proxy in
        if let anchor {
          let rect = proxy[anchor]
          // 只移动这一条线，而且只用位移和横向缩放——这两样只改绘制、不改排版。第一版把
          // 弹簧动画挂在整排页签上，页签就在正文的滚动区里，每一帧都把整篇长文重排一遍，
          // 切一条要掉十几帧（2026-10-04 Instruments）。
          Rectangle()
            .fill(theme.accent)
            .frame(width: 1, height: 2)
            .scaleEffect(x: max(rect.width, 1), y: 1, anchor: .leading)
            .offset(x: rect.minX, y: rect.maxY - 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: rect)
        }
      }
      .allowsHitTesting(false)
    }
    .accessibilityLabel("阅读内容")
    .accessibilityIdentifier("history-reading-tabs")
  }

  /// 原文只有一层、而且就是本机转写稿（本地视频、录音，或抖音那类只有转写的）。
  private var singlePaneTranscriptSnapshot: ContentSnapshot? {
    guard !isOwnWriting, !showsLayeredSource, !hasLiveTranscription else { return nil }
    let snapshot = (isDouyinCapture && !isDouyinImagePostCapture) ? latestTranscriptionSnapshot : latestSnapshot
    guard let snapshot, !snapshot.bodyText.isEmpty,
          snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue else { return nil }
    return snapshot
  }

  /// 这份转写稿校对过、机器原稿也在，而且按逐字稿排（没分说话人、不是纯文本模式）：
  /// 「校对稿」「原稿」拆成表头上两个平级页签。
  private var splitsManuscriptTabs: Bool {
    guard !showsPlainText, let snapshot = singlePaneTranscriptSnapshot,
          snapshot.captureMethod == Self.tidyCaptureMethod, machineTranscriptSnapshot != nil else { return false }
    return derivedMemo.value("splitsManuscriptTabs", snapshot: snapshot) {
      let body = displayedSourceMarkdown(snapshot, bodyOverride: nil)
      return SpeakerTranscript.turns(in: body).isEmpty && TranscriptManuscript.looksLikeTranscript(body)
    }
  }

  /// 校对稿上的「朱批 · 改字 N 处」开关：原来和「校对稿 / 原稿」一起占正文上方一整行，
  /// 现在挂在表头右边，和「处理」同一排。
  @ViewBuilder private var manuscriptMarkToggle: some View {
    if manuscriptMode != .original, let snapshot = singlePaneTranscriptSnapshot, let machine = machineTranscriptSnapshot {
      let marked = manuscriptMode == .marked
      Button {
        manuscriptMode = marked ? .revised : .marked
      } label: {
        Text(marked ? "收起朱批" : manuscriptSummary(manuscriptRevision(snapshot: snapshot, machine: machine)))
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(theme.seal)
          .lineLimit(1)
      }
      .buttonStyle(.plain)
      .help(marked ? "收起批改记号" : "显示模型相对本机转写改了哪些字")
      .accessibilityIdentifier("transcript-manuscript-mode-marked")
    }
  }

  private func manuscriptRevision(snapshot: ContentSnapshot, machine: ContentSnapshot) -> TranscriptRevision.Result? {
    let body = TranscriptManuscript.splittingComments(displayedSourceMarkdown(snapshot, bodyOverride: nil)).transcript
    let machineBody = TranscriptManuscript.splittingComments(displayedSourceMarkdown(machine, bodyOverride: nil)).transcript
    return TranscriptManuscript.revision(
      originalKey: machine.id.rawValue, original: machineBody,
      revisedKey: snapshot.id.rawValue, revised: body
    )
  }

  /// 「原文 / 重排」是原文页上的显示切换，不是动作；生成重排稿的入口在「⋯」里。
  @ViewBuilder private var reformatToggle: some View {
    if model.reformatRecord != nil {
      Picker("正文版面", selection: $model.showsReformattedBody) {
        Text("原文").tag(false)
        Text("整理排版").tag(true)
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .labelsHidden()
      .frame(maxWidth: 108)
      .accessibilityIdentifier("history-reformat-toggle")
    }
  }

  /// 表头右边的动作：只列**还没做**的。转写、总结、翻译三个动词并排，一种样子。
  /// 当前页签看的是不是带时间码的转写稿（原文的转写 / 画面字幕层，或它们的译文）。
  private var currentPaneHasTimecodes: Bool {
    switch effectiveReadingPane {
    case .source:
      if !transcriptParagraphs.isEmpty { return true }
      return activeSourceLayer == .transcript || activeSourceLayer == .subtitles
    case .translation:
      if activeTranslationLayer == .transcript || activeTranslationLayer == .subtitles { return true }
      guard let body = translationArtifact?.bodyText else { return false }
      return TranscriptReadingText.hasLeadingTimecodes(body)
    case .summary:
      return false
    }
  }

  @ViewBuilder private var timecodeToggle: some View {
    if currentPaneHasTimecodes {
      Button {
        showsTranscriptTimecodes.toggle()
      } label: {
        Image(systemName: showsTranscriptTimecodes ? "clock" : "text.alignleft")
      }
      .buttonStyle(.appIcon)
      .help(showsTranscriptTimecodes
        ? "隐藏时间码，合成段落当文章读"
        : "显示时间码，可以点时间码跳到视频对应位置")
      .accessibilityLabel(showsTranscriptTimecodes ? "隐藏时间码" : "显示时间码")
      .accessibilityIdentifier("reading-timecode-toggle")
    }
  }

  private func readingVerbs(pinned: Bool) -> some View {
    HStack(spacing: DesignTokens.Space.sm) {
      timecodeToggle
      transcribeVerb
      runVerb(.summarize)
      runVerb(.translate)
      processButton(pinned: pinned)
    }
    .controlSize(.small)
  }

  /// 表头上唯一露出来的「下一步」（2026-10-01 走查：原来「生成总结」「生成翻译」「转写」
  /// 和「处理」面板里的同名项各出现两次）。没转写的媒体 → 转写；有正文没总结 → 生成总结；
  /// 都做了 → 不露。其余（翻译、脑图、重做）只在「处理」里，「处理」也不再重复这一项。
  private enum PrimaryReadingVerb { case transcribe, summarize }

  private var primaryReadingVerb: PrimaryReadingVerb? {
    if transcribeAction != nil, !hasCompletedTranscript { return .transcribe }
    if summaryArtifact == nil, showsRunControls { return .summarize }
    return nil
  }

  private func startRun(_ kind: RunKind) {
    // 还没配模型：直接带去「模型服务」。原来会去试一次，失败说明写在一块收起的面板里，
    // 用户只看到按钮闪一下、什么都没发生（2026-10-02 新用户走查）。
    guard providerSettings.hasConfiguredAPIKey else {
      SettingsNavigationRequest.request("service")
      openSettings()
      return
    }
    Task {
      let started: Bool
      switch kind {
      case .summarize:
        started = await appModel.summarize(historyDetail: detail, preferences: providerSettings.runPreferences)
      case .translate:
        started = await appModel.translate(historyDetail: detail, preferences: providerSettings.runPreferences)
      }
      engageReadingPane(pane(for: kind), started: started)
    }
  }

  private func isRunning(_ kind: RunKind) -> Bool {
    showsVisibleRun && appModel.runState.isActive && liveRunReadingPane == pane(for: kind)
  }

  /// 总结 / 翻译按钮。正在跑就变成进度和「停止」；已经有产物就不出现（重做在「⋯」）。
  @ViewBuilder private func runVerb(_ kind: RunKind) -> some View {
    let title = kind == .translate ? "翻译" : "总结"
    let artifactExists = (kind == .translate ? translationArtifact : summaryArtifact) != nil
    if isRunning(kind) {
      HStack(spacing: DesignTokens.Space.xs) {
        ProgressView().controlSize(.mini)
        Text("\(title)中…")
          .themedFont(.caption, weight: .medium)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if appModel.canStopVisibleRun(for: detail.task.id) {
          Button("停止", role: .cancel) { Task { await appModel.stop() } }
            .buttonStyle(.plain)
            .themedFont(.caption)
            .foregroundStyle(theme.accent)
            .help("停止当前生成")
            .accessibilityLabel("停止当前生成")
            .accessibilityIdentifier("stop-model-run")
        }
      }
      .accessibilityIdentifier("model-run-status")
    } else if !artifactExists, kind == .summarize, primaryReadingVerb == .summarize {
      // 翻译不再在表头露按钮，只在跑的时候显示进度和「停止」（上面那支）；入口在「处理」里。
      let isQueued = appModel.isManualGenerationQueued(
        taskID: detail.task.id,
        kind: kind == .translate ? .translate : .summarize
      )
      let blockedReason = kind == .translate ? translateUnavailableReason : summarizeUnavailableReason
      // 按钮写成「生成总结」而不是「总结」：它紧挨着页签，只写两个字像是切到「总结」页，
      // 一点却开始调用模型、花 token（2026-09-29 走查误点过）。
      Button(isQueued ? "已排队\(title)" : "生成\(title)") { startRun(kind) }
        .buttonStyle(.bordered)
        .disabled(blockedReason != nil)
        .help(
          blockedReason ?? (!providerSettings.hasConfiguredAPIKey
            ? "还没配置模型：点一下去配置"
            : (kind == .translate
              ? "把当前正文翻译为\(providerSettings.runPreferences.outputLanguage)"
              : "让模型读完正文，写一份总结"))
        )
        .accessibilityIdentifier(
          kind == .translate
            ? (showsCurrentCapture ? "translate-current-capture" : "translate-history-detail")
            : (showsCurrentCapture ? "summarize-current-capture" : "summarize-history-detail")
        )
    }
  }

  /// 这条记录能不能转写、走哪条路。没有视频就是 nil，按钮整个不出现。
  ///
  /// 本地已存的视频走 `requestTranscription`；刚从扩展抓来、还没落盘的当前抓取
  /// 走带 descriptor 的那组接口。两条路在这里合成一个按钮，视频卡上不再各放一个。
  private struct TranscribeAction {
    let canStart: Bool
    let canStartOnline: Bool
    let help: String
    let start: () -> Void
    let retry: () -> Void
    let startOnline: () -> Void
  }
  private var transcribeAction: TranscribeAction? {
    guard !isOwnWriting else { return nil }
    let taskID = detail.task.id
    let onlineModel = providerSettings.effectiveTranscriptionModelName
    if let localMediaFileURL, LocalMediaExport.isSupportedLocalFile(localMediaFileURL) {
      return .init(
        canStart: model.canTranscribeVideo,
        canStartOnline: model.canTranscribeLocalMediaOnline(taskID: taskID, model: onlineModel),
        help: "在本机识别这段视频里说了什么，不联网、不花钱",
        start: { model.requestTranscription() },
        retry: { model.retryTranscription() },
        startOnline: { model.requestOnlineTranscriptionFromLocalMedia(taskID: taskID, model: onlineModel) }
      )
    }
    if localMediaFileURL == nil, showsCurrentCapture,
       let capture = appModel.currentCapture,
       let captureDescriptor = capture.mediaDescriptor {
      let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID) ?? captureDescriptor
      // HLS 流拿不到整段音频，转写走不通；表头下面的状态行会说明。
      guard descriptor.kind == .directFile else { return nil }
      return .init(
        canStart: model.canTranscribeCurrentCapture(descriptor, taskID: taskID),
        canStartOnline: model.canTranscribeCurrentCaptureOnline(descriptor, taskID: taskID, model: onlineModel),
        help: "先把视频拉到本机再识别，不联网、不花钱",
        start: { model.requestRemoteTranscription(descriptor, taskID: taskID) },
        retry: { model.retryRemoteTranscription(descriptor, taskID: taskID) },
        startOnline: { model.requestOnlineTranscription(descriptor, taskID: taskID, model: onlineModel) }
      )
    }
    return nil
  }
  private var showsRemoteCaptureCard: Bool {
    localMediaFileURL == nil && showsCurrentCapture && appModel.currentCapture?.mediaDescriptor != nil
  }
  private var isCurrentCaptureHLS: Bool {
    guard localMediaFileURL == nil, showsCurrentCapture,
          let capture = appModel.currentCapture,
          let captureDescriptor = capture.mediaDescriptor else { return false }
    let descriptor = sessionMediaPlayback.cachedDescriptor(for: capture.taskID) ?? captureDescriptor
    return descriptor.kind != .directFile
  }
  /// 会话态回到 idle 后，仍以落库的 transcriptionStatus 判断「已经转写过」。
  private var hasCompletedTranscript: Bool {
    latestTranscriptionSnapshot != nil
      || model.transcriptionState(for: detail.task.id) == .completed
      || detail.media?.transcriptionStatus == .completed
  }
  private var transcriptTidyBlockedReason: String? {
    model.transcriptTidyUnavailableReason(taskID: detail.task.id)
  }
  /// 已有文稿、整理仍不可用时，在菜单外留一行可见理由（不只靠悬停）。
  private var transcriptTidyVisibleBlockedReason: String? {
    guard hasCompletedTranscript, let reason = transcriptTidyBlockedReason,
          reason != "需先完成转写，才有文稿可整理",
          // 没人说话的那种：正文那里已经写着「没有识别到说话声」，表头下不再说第二遍。
          !reason.hasPrefix("没有识别到说话声") else { return nil }
    return reason
  }
  /// 菜单里禁用的「在线转写」必须自己说明为什么灰。
  private var onlineTranscribeMenuTitle: String {
    let trimmed = providerSettings.effectiveTranscriptionModelName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed?.isEmpty != false {
      // 面板只有 320 宽，整句写进来被截成「见「设置 → 转…」（2026-10-02 自测）；去哪设在悬停提示里。
      return "在线转写（未配置模型）"
    }
    return hasCompletedTranscript ? "重新转写（在线）" : "在线转写"
  }
  private func transcriptionPhaseText(_ state: TranscriptionUIState) -> String {
    switch state {
    case .preparingMedia: "准备媒体…"
    case .checkingModel: "检查离线模型…"
    case .preparingModel: "准备离线模型…"
    case .extractingAudio: "提取音频…"
    case .transcribing:
      model.transcriptionUsesOnlineService
        ? (model.onlineTranscriptionPhase ?? "在线转写中…")
        : "转写中…"
    default: ""
    }
  }

  /// 转写按钮。和总结/翻译站在同一排：都是「把内容交给模型换一份新文本」。
  @ViewBuilder private var transcribeVerb: some View {
    if let action = transcribeAction {
      let state = model.transcriptionState(for: detail.task.id)
      switch state {
      case .preparingMedia, .checkingModel, .preparingModel, .extractingAudio, .transcribing:
        HStack(spacing: DesignTokens.Space.xs) {
          ProgressView().controlSize(.mini)
          Text(transcriptionPhaseText(state))
            .themedFont(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Button("停止", role: .cancel) { model.cancelTranscription() }
            .buttonStyle(.plain)
            .themedFont(.caption)
            .foregroundStyle(theme.accent)
            .accessibilityIdentifier("history-video-transcription-cancel")
        }
        .accessibilityIdentifier("history-video-transcription-running")
      case .awaitingModelDownload:
        Text("等待确认模型下载")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history-video-transcription-awaiting")
      case .failed, .cancelled:
        if !hasCompletedTranscript {
          Button("重试转写", action: action.retry)
            .buttonStyle(.bordered)
            .disabled(!action.canStart)
            .help(action.help)
            .accessibilityIdentifier("history-video-transcription-retry")
        }
      case .idle, .completed:
        if !hasCompletedTranscript {
          Button("转写", action: action.start)
            .buttonStyle(.bordered)
            .disabled(!action.canStart)
            .help(action.help)
            .accessibilityIdentifier("history-video-transcription-start")
        }
      }
    }
  }

  /// 校对提示条的第二行：有分段进度就报进度，长稿大约要几分钟。
  private var tidyRunningDetail: String {
    let progress = model.transcriptTidyProgress.map { "\($0) · " } ?? ""
    let estimate: String = {
      if let remaining = model.transcriptTidyRemainingSeconds {
        return remaining < 90 ? "还要约 1 分钟，" : "还要约 \(Int((Double(remaining) / 60).rounded())) 分钟，"
      }
      guard let seconds = model.transcriptTidyEstimatedSeconds else { return "" }
      return seconds < 90 ? "全部约 1 分钟，" : "全部约 \(Int((Double(seconds) / 60).rounded())) 分钟，"
    }()
    return "\(progress)\(estimate)完成后自动替换成校对稿，不用刷新。"
  }

  /// 校对进行中、正在看的是原文：原稿调淡，一眼看出这还不是最终版。
  private var isShowingUntidiedTranscript: Bool {
    model.transcriptTidyState(for: detail.task.id) == .running && effectiveReadingPane == .source
  }

  /// 表头下面的状态行：只在出了状况时出现（转写失败、整理进行中、只读、HLS）。
  /// 顺利的时候什么都不显示——页签出现就是「完成」。
  @ViewBuilder private var readingHeaderStatusLines: some View {
    let taskID = detail.task.id
    // 当前抓取的远程视频卡自己带一块转写状态（流式预览、计时、清理失败），
    // 这两行只给本地视频用，免得同一句失败原因出现两次。
    if !showsRemoteCaptureCard {
      switch model.transcriptionState(for: taskID) {
      case let .failed(message):
        // 转写失败多是「视频里没人声」这类提醒，不用红：红挨着页边的朱印，像印出了错（2026-09-30 走查）。
        Text(message)
          .themedFont(.caption)
          .foregroundStyle(theme.warning)
          .lineLimit(3)
          .accessibilityIdentifier("history-video-transcription-failed")
      case .cancelled:
        Text(LocalVideoTranscriptionError.cancelled.userMessage)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      default:
        EmptyView()
      }
    }
    switch model.transcriptTidyState(for: taskID) {
    case .running:
      // 校对要几分钟，期间铺在下面的是机器原稿：标点少、有听错的词。只放一行小灰字，
      // 用户会把原稿当成最终结果（2026-09-28 反馈），所以用一条醒目的提示条说清楚。
      HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 2) {
          Text("下面是机器原稿，模型正在补标点、改错字")
            .themedFont(.subheadline)
            .foregroundStyle(.primary)
          Text(tidyRunningDetail)
            .themedFont(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button("停止") { model.cancelTranscriptTidy() }
          .buttonStyle(.plain)
          .themedFont(.caption)
          .foregroundStyle(theme.accent)
          .help("停下这次校对，保留原来的转写稿")
          .accessibilityIdentifier("history-transcript-tidy-cancel")
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
      // contain 而不是 combine：合并后「停止」按钮被吞进一整段文字，读屏和键盘都够不着（2026-10-04 走查）。
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("history-transcript-tidy-running")
    case .completed:
      // 只在刚做完的那几秒出现（2026-10-04 详情页精简）：原来一直挂着，连带一串
      // 「用量 133180（输入 … / 输出 …）」，下次打开这条还在。用量放进悬停提示。
      if recentlyCompletedTidyTaskID == taskID {
        Label("校对稿已保存", systemImage: "checkmark.circle.fill")
          .themedFont(.caption)
          .foregroundStyle(theme.success)
          .help(model.transcriptTidyTokenSummary(for: taskID) ?? "校对稿已保存为最新原文")
          .transition(.opacity)
      }
    case .cancelled:
      Text(TranscriptTidyError.cancelled.userMessage).themedFont(.caption).foregroundStyle(.secondary)
    case let .failed(message):
      Text(message).themedFont(.caption).foregroundStyle(theme.danger).lineLimit(3)
    case .idle:
      EmptyView()
    }
    if case .running = model.reformatState(for: taskID) {
      HStack(spacing: DesignTokens.Space.xs) {
        ProgressView().controlSize(.mini)
        Text("正在整理排版…").themedFont(.caption).foregroundStyle(.secondary)
        Button("停止") { model.cancelArticleReformat() }
          .buttonStyle(.plain)
          .themedFont(.caption)
          .foregroundStyle(theme.accent)
      }
      .accessibilityIdentifier("history-reformat-running")
    }
    if model.isReadOnly, transcribeAction != nil {
      Text("只读模式不能保存转写结果；恢复可写存储后可重试。")
        .themedFont(.caption)
        .foregroundStyle(theme.warning)
        .accessibilityIdentifier("history-video-transcription-read-only")
    }
    if isCurrentCaptureHLS {
      Text("这段视频是流媒体（HLS），暂不支持转写")
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history-video-transcription-hls")
    }
    if let reason = transcriptTidyVisibleBlockedReason {
      Text(reason)
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history-transcript-tidy-blocked-reason")
    }
  }

  /// 表头右端的「处理」：工序和次要动作（2026-09-28 工序印）。
  ///
  /// 原来是系统菜单，只能放单色小图标；现在是自己画的面板，每道工序前面一枚印：
  /// 没做的是印位（虚线框、空心字）写「去做」，做过的是盖好的章写时间，正在做写进度，
  /// 上次失败写原因。分隔线下面是不算工序的动作：在线转写、整理排版、换模型重跑、运行详情。
  ///
  /// 表头在原位和吸顶各有一份；面板只挂在当前看得见的那一份上，不会两个抢一个开关。
  private func processButton(pinned: Bool) -> some View {
    Button {
      isProcessPanelPresented.toggle()
    } label: {
      Label("处理", systemImage: "wand.and.stars")
        .labelStyle(.titleAndIcon)
    }
    // 和旁边的「总结」「翻译」同一种有边框按钮（2026-09-25）。
    .buttonStyle(.bordered)
    .fixedSize()
    .help("转写、校对、评论、总结、翻译、脑图，以及整理排版、换个模型重跑、生成记录")
    .accessibilityLabel("处理")
    .accessibilityIdentifier("history-more-actions-menu")
    .popover(
      isPresented: Binding(
        get: { isProcessPanelPresented && pinned == isReadingHeaderPinned },
        set: { if !$0 { isProcessPanelPresented = false } }
      ),
      arrowEdge: .bottom
    ) {
      processPanel
    }
  }

  /// 面板里点了会弹出另一个窗口的动作（抓评论、换模型重跑），先把面板收起再弹，免得两个浮层叠在一起。
  private func closeProcessPanel(then action: @escaping () -> Void) {
    isProcessPanelPresented = false
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 180_000_000)
      action()
    }
  }

  private var processPanel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("工序")
        .themedFont(.caption)
        .tracking(2)
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
      ForEach(processStepRows, id: \.step) { row in
        ProcessStepRow(
          step: row.step, title: row.title, state: row.state, isEnabled: row.isEnabled, help: row.help,
          subtitle: row.subtitle,
          sealColor: theme.seal, primaryText: theme.primaryText, secondaryText: theme.secondaryText,
          identifier: row.identifier, action: row.action
        )
      }
      processPanelExtras
    }
    .padding(6)
    .frame(width: 320)
    .accessibilityIdentifier("history-process-panel")
  }

  private struct ProcessStepRowModel {
    let step: ProcessStep
    let title: String
    let state: ProcessStepRow.State
    let isEnabled: Bool
    let help: String
    var subtitle: String? = nil
    let identifier: String
    let action: () -> Void
  }

  /// 面板里每一步写上它实际用的模型名（只写最后一段，「antigravity/gemini-3.8-flash」→「gemini-3.8-flash」）。
  private func processModelSubtitle(_ name: String?) -> String? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
    return "模型：" + (name.split(separator: "/").last.map(String.init) ?? name)
  }

  /// 这一条能做的工序，按「录 校 评 摘 译 图」排。做不了的（没有视频、没有评论源）不列。
  private var processStepRows: [ProcessStepRowModel] {
    let taskID = detail.task.id
    let records = Dictionary(uniqueKeysWithValues: completedStepRecords.map { ($0.step, $0) })
    func doneText(_ step: ProcessStep) -> String {
      records[step]?.date.map { ProcessStepRecord.shortFormat($0) } ?? "已做"
    }
    var rows: [ProcessStepRowModel] = []

    // 面板列全部工序，顺序和设置里的「工序总览」一致（2026-10-04 Syc 确认）。原来表头上露着的
    // 那一步（转写 / 生成总结）不在这里列，结果设置里有「总结」、面板里却找不到。
    if let action = transcribeAction {
      let state: ProcessStepRow.State = {
        let ui = model.transcriptionState(for: taskID)
        if ui.isActive { return .running("转写中…") }
        if case let .failed(reason) = ui { return .failed(reason) }
        return hasCompletedTranscript ? .done(doneText(.record)) : .pending
      }()
      rows.append(.init(
        step: .record,
        title: hasCompletedTranscript ? "重新转写（本机）" : "转写（本机）",
        state: state,
        isEnabled: action.canStart && !model.transcriptionState(for: taskID).isActive,
        help: action.help,
        identifier: hasCompletedTranscript ? "history-more-retranscribe" : "history-process-transcribe",
        action: { isProcessPanelPresented = false; action.start() }
      ))
    }

    if hasCompletedTranscript {
      let tidy = model.transcriptTidyState(for: taskID)
      let done = records[.proof] != nil
      let state: ProcessStepRow.State = {
        if tidy.isActive { return .running(model.transcriptTidyProgress ?? "校对中…") }
        if case let .failed(reason) = tidy { return .failed(reason) }
        return done ? .done(doneText(.proof)) : .pending
      }()
      rows.append(.init(
        step: .proof,
        // 叫「校对」，和进度提示「正在用模型校对」同一个词（2026-09-28 反馈）。
        title: done ? "重新校对转写稿" : "校对转写稿",
        state: state,
        isEnabled: transcriptTidyBlockedReason == nil && !tidy.isActive,
        help: "把转写文字校对一遍并重新分段，不改说了什么",
        subtitle: transcriptTidyBlockedReason
          ?? processModelSubtitle(providerSettings.effectiveTidyModelName ?? providerSettings.activeSummaryModelName),
        identifier: "history-ai-transcript-tidy",
        action: {
          isProcessPanelPresented = false
          model.requestTranscriptTidy(taskID: taskID, model: providerSettings.effectiveTidyModelName)
        }
      ))
    }

    if commentSourceURL != nil {
      let done = records[.comments] != nil
      rows.append(.init(
        step: .comments,
        title: done ? "重新抓取评论…" : "抓取评论…",
        state: done ? .done(doneText(.comments)) : .pending,
        isEnabled: true,
        help: "打开原文读取前几条评论，勾选后写进正文末尾",
        identifier: "history-fetch-comments",
        action: { closeProcessPanel { isCommentPickerPresented = true } }
      ))
    }

    for (step, kind) in [(ProcessStep.summary, RunKind.summarize), (.translation, .translate)] {
      if kind == .translate, translationNotNeeded, translationArtifact == nil { continue }
      let done = (kind == .translate ? translationArtifact : summaryArtifact) != nil
      let blocked = kind == .translate ? translateUnavailableReason : summarizeUnavailableReason
      let queued = appModel.isManualGenerationQueued(taskID: taskID, kind: kind == .translate ? .translate : .summarize)
      let state: ProcessStepRow.State = {
        if isRunning(kind) { return .running("\(step.title)中…") }
        if queued { return .running("已排队") }
        if !done, let notice = UnfinishedRunNotice.latest(in: detail.runs), notice.kind == kind {
          return .failed(notice.message)
        }
        return done ? .done(doneText(step)) : .pending
      }()
      rows.append(.init(
        step: step,
        title: done ? "重新\(step.title)" : step.title,
        state: state,
        isEnabled: blocked == nil && !isRunning(kind),
        help: blocked ?? (done ? "用本机已保存的正文再\(step.title)一次" : (kind == .translate
          ? "把当前正文翻译为\(providerSettings.runPreferences.outputLanguage)"
          : "让模型读完正文，写一份总结")),
        subtitle: blocked ?? processModelSubtitle(
          kind == .translate ? providerSettings.effectiveTranslationModelName : providerSettings.activeSummaryModelName
        ),
        identifier: kind == .translate
          ? (done ? "history-more-retranslate" : "history-process-translate")
          : (done ? "history-more-resummarize" : "history-process-summarize"),
        action: { isProcessPanelPresented = false; startRun(kind) }
      ))
    }

    if !isOwnWriting {
      let done = model.mindMapRecord?.taskID == taskID
      let queued = appModel.isManualGenerationQueued(taskID: taskID, kind: .mindMap)
      let state: ProcessStepRow.State = {
        if model.mindMapState(for: taskID).isActive { return .running("生成中…") }
        if queued { return .running("已排队") }
        if case let .failed(reason) = model.mindMapState(for: taskID) { return .failed(reason) }
        return done ? .done(doneText(.mindMap)) : .pending
      }()
      rows.append(.init(
        step: .mindMap,
        title: done ? "重新生成脑图" : "生成脑图",
        state: state,
        isEnabled: mindMapUnavailableReason == nil,
        help: mindMapUnavailableReason ?? (queued ? "再点一次取消排队" : "把正文发给模型提取结构"),
        subtitle: mindMapUnavailableReason ?? processModelSubtitle(providerSettings.activeSummaryModelName),
        identifier: "mind-map-generate",
        action: {
          isProcessPanelPresented = false
          if appModel.canEnqueueManualGeneration(for: taskID) || queued {
            appModel.enqueueOrCancelMindMapGeneration(taskID: taskID)
          } else {
            model.requestMindMapGeneration(taskID: taskID)
          }
        }
      ))
    }
    return rows
  }

  /// 分隔线下面：不算工序的动作，沿用线性图标。
  @ViewBuilder private var processPanelExtras: some View {
    Divider().padding(.horizontal, 8).padding(.vertical, 4)
    VStack(alignment: .leading, spacing: 0) {
      // 只列点得动的：没配在线转写、不适合整理排版时原来各留一行灰字（2026-10-04 详情页精简）。
      if let action = transcribeAction, action.canStartOnline {
        processExtraButton(onlineTranscribeMenuTitle, systemImage: MenuIcon.transcribeOnline, identifier: "history-more-online-transcribe") {
          isProcessPanelPresented = false
          action.startOnline()
        }
      }
      if canOfferSpeakerDiarization {
        processExtraButton("区分说话人（本机）", systemImage: "person.2", identifier: "history-diarize-local",
                           help: "免费，录音不离开这台 Mac") {
          isProcessPanelPresented = false
          model.diarizeSpeakers(detail: detail, mode: .local)
        }
        processExtraButton("区分说话人（在线）…", systemImage: "person.2.wave.2", identifier: "history-diarize-online",
                           help: "上传录音到你配置的在线服务，按时长计费，通常更准") {
          closeProcessPanel { isOnlineDiarizationConfirmPresented = true }
        }
      }
      // 「整理排版」只对 2000 字以上、还没分节的长文可用；短帖留一条灰项说明原因。
      if !isOwnWriting, model.reformatRecord == nil, let snapshot = latestSnapshot {
        let eligibility = reformatEligibility(snapshot)
        if eligibility.canReformat {
          processExtraButton("整理排版", systemImage: MenuIcon.reformat, identifier: "history-reformat-button",
                             enabled: model.reformatUnavailableReason(taskID: detail.task.id) == nil,
                             help: model.reformatUnavailableReason(taskID: detail.task.id) ?? "给这篇长文分节、加上小标题；原文不会被改动，随时可以切回") {
            isProcessPanelPresented = false
            model.requestArticleReformat(taskID: detail.task.id, bodyText: snapshot.bodyText, model: providerSettings.effectiveTidyModelName)
          }
        }
      }
      processExtraButton("换个模型重跑…", systemImage: MenuIcon.rerun, identifier: "regenerate-history",
                         enabled: !(summarizeUnavailableReason != nil && translateUnavailableReason != nil),
                         help: "用本机已保存的正文，临时换一个模型重新总结或翻译") {
        closeProcessPanel { isRegeneratePopoverPresented = true }
      }
      // 和某一步自己那行小字说的是同一件事（比如「不用翻译」）时不再写第二遍。
      if let runActionBlockedReason,
         runActionBlockedReason != translateUnavailableReason,
         runActionBlockedReason != summarizeUnavailableReason {
        Text(runActionBlockedReason).themedFont(.caption).foregroundStyle(theme.secondaryText).padding(.horizontal, 10).padding(.vertical, 4)
      }
      if !providerSettings.arePreferencesReady {
        processExtraButton("设置模型", systemImage: MenuIcon.model, identifier: "history-open-model-settings") {
          isProcessPanelPresented = false
          openSettings()
        }
      }
      if canRunHistory || showsCurrentCapture || isRunPanelExpanded || hasCollapsedRunMetadata {
        processExtraButton(isRunPanelExpanded ? "收起生成记录" : "生成记录", systemImage: MenuIcon.runDetails, identifier: "history-run-panel-toggle") {
          isProcessPanelPresented = false
          withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { isRunPanelExpanded.toggle() }
        }
      }
    }
  }

  private func processExtraButton(
    _ title: String, systemImage: String, identifier: String, enabled: Bool = true, help: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 13))
          .foregroundStyle(theme.secondaryText)
          .frame(width: 28)
        Text(title).themedFont(.body).foregroundStyle(theme.primaryText).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
    .help(help ?? title)
    .accessibilityIdentifier(identifier)
  }

  // MARK: - 工序印

  /// 导出题跋各件的判断逻辑在 `ReadingDocumentExport.ExportColophonContext`（与界面共用，可测试）。
  /// 落款要把每次运行逐条翻一遍，一次十几毫秒，而 body 里要用到它五处——切一条时 body
  /// 又求值好几次，合起来七十毫秒（2026-10-04 Instruments）。详情和脑图没变就复用上一次的结果。
  private var exportColophonContext: ReadingDocumentExport.ExportColophonContext {
    let mindMap = model.mindMapRecord.flatMap { $0.taskID == detail.task.id ? $0 : nil }
    return colophonMemo.value(detail: detail, mindMap: mindMap)
  }

  /// 这一条做过的工序，按「录 校 评 摘 译 图」排；有记录的写上时间和模型，没有的不编。
  private var completedStepRecords: [ProcessStepRecord] {
    exportColophonContext.records
  }

  /// 导出文件末尾的题跋文字：「丙午年九月廿八日　汲录自抖音　录 · 校 · 评 · 摘」。笔记不加。
  private var exportColophonLine: String? {
    exportColophonContext.colophonLine
  }

  /// PDF / Word 末尾的题跋：右对齐一行小字，后面画出真的章（渲染成图片放进去）。
  @MainActor
  private func exportColophonAttributed() -> NSAttributedString? {
    ReadingDocumentExport.exportColophonAttributed(context: exportColophonContext, readingFont: readingFont)
  }

  /// 点页尾的章：跳到那份内容。
  private func openStep(_ step: ProcessStep) {
    switch step {
    case .record, .proof, .comments:
      readingPane = .source
    case .summary:
      readingPane = .summary
    case .translation:
      readingPane = .translation
    case .mindMap:
      moduleScrollTarget = ReadingAnchor.module("mindmap")
    }
  }

  /// 每道做过的工序和它的完成时间（秒）；没有时间记录的记 0。
  private var completedStepStamps: [ProcessStep: Double] {
    Dictionary(uniqueKeysWithValues: completedStepRecords.map { ($0.step, $0.date?.timeIntervalSince1970 ?? 0) })
  }

  /// 看着这一条时，某道工序新做完（或重做完、完成时间变新）就盖一下；换条目只更新底数，不盖。
  private func noteCompletedSteps(_ steps: [ProcessStep: Double]) {
    defer { stampBaseline = (detail.task.id, steps) }
    guard let baseline = stampBaseline, baseline.taskID == detail.task.id else { return }
    let refreshed = steps.filter { step, time in baseline.steps[step].map { time > $0 } ?? true }
    guard let step = ProcessStep.allCases.first(where: { refreshed[$0] != nil }) else { return }
    withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) { stampingStep = step }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
        if stampingStep == step { stampingStep = nil }
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
        .padding(.horizontal, 4)
        .frame(minHeight: 28)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(prominent && !disabled ? theme.accent : theme.secondaryText)
    .controlSize(.small)
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(title)
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
        Text("用本机已保存的正文生成；另存一份新结果，旧的保留。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          settingsModelButton(providerSettings.activeSummaryModelName)
          if providerSettings.usesSeparateTranslationModel {
            settingsModelButton(providerSettings.effectiveTranslationModelName)
          }
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
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      if isOwnWriting {
        if showsReadingPanePicker { readingPanePicker }
      } else {
        // 表头就是正文的表头：标明「下面这段是哪一份」，紧贴着它控制的文字。
        // 它在滚动坐标系里的位置上报给外层，滚出顶部后由吸顶副本接手。
        //
        // 表头滚出顶部就吸住；滚回来落回原位。只把「吸不吸」这一位交出去：原来是用
        // preference 每帧上报纵坐标，滑动的每一帧都要沿整棵正文视图树传一遍值，
        // 哪怕结论没变。`onGeometryChange` 只在这一位翻转时才回调。
        readingHeaderRow(pinned: false)
          .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .named(HistoryDetailView.readingScrollSpace)).minY < 0
          } action: { pinned in
            if isReadingHeaderPinned != pinned { isReadingHeaderPinned = pinned }
          }
        Divider()
          .overlay(alignment: .leading) { readingSeamSeal }
      }
      content
        .opacity(isShowingUntidiedTranscript ? 0.6 : 1)
        // 评论区据此给作者本人的回复标上「作者」。
        .environment(\.commentPostAuthor, sourceFrontmatter.author)
    }
    .animation(historyUIAnimation(reduceMotion: reduceMotion), value: showsLiveRunInReadingPane)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 0)
    .padding(.bottom, DesignTokens.Space.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 骑缝章（2026-09-29 Syc 选定方案 C2）：一枚「汲 / 作」压在页头和正文之间那条缝的起头，
  /// 挂进左页边，分隔线从印身后接出去。页签、按钮都不让位；左页边本来就是挂东西的地方
  /// （逐字稿的时间码也挂在这里）。整页只这一枚归属印，工序印仍在处理面板和页尾题跋。
  private var readingSeamSeal: some View {
    let size: CGFloat = 28
    let gap: CGFloat = 8
    return HStack(spacing: 0) {
      SealMark(glyph: colophonGlyph, size: size, color: theme.seal, style: .stamped, rotation: -4)
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: gap, height: 1)
    }
    .offset(x: -(size + gap))
    .help(colophonGlyph == .own ? "作：自己写下的" : "汲：从外面收来的")
    .accessibilityIdentifier("history-reading-seam-seal")
  }

  private var showsReadingSurface: Bool {
    showsLiveRunInReadingPane || hasResultBody || hasSourceBody || isDouyinCapture
  }

  /// 译文里的层切换。和原文用**同一个**控件，不是长得像的另一个。
  ///
  /// 两处是同一件事：先选看哪种产物（总结/翻译/原文），再选看哪一层内容。
  /// 翻译页原来把各层纵向叠着，读者要滚过整份配文才够得着转写稿的译文。
  private var translationLayerPicker: some View {
    layerPicker(
      title: "译文对应",
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
    // `Binding` 的 set 在 SwiftUI 里是 `@Sendable` 的，而调用方传进来的
    // `select` 要改视图状态（MainActor）。标成 `@MainActor` 之后它是 Sendable 的，
    // 两边就都对得上了；闭包体里再补一道 assumeIsolated 说明它确实在主线程跑。
    select: @escaping @MainActor (SourceLayer) -> Void
  ) -> some View {
    // 二级切换用文字标签，不再用和一级同款的分段控件。
    //
    // 两者形状一样时，「总结 | 翻译 | 原文」和「配文 | 视频转写」看起来就是
    // 并列的两组选择，可后者其实活在前者的「原文」里。轻一档的样式把这层
    // 从属关系直接写在外观上，不用靠人去推。
    //
    // 对齐写在这里、而不是交给各自的父容器：原文页的父容器是
    // `VStack(alignment: .leading)`、翻译页的不是，同一个控件在两处一个靠左
    // 一个居中，看起来像两个不同的东西。
    // 2026-09-24 走查：原来二级也是「文字 + 下划线」，和上面一级页签长得一样，
    // 看上去是两排并列的页签、「配文」出现两次。改成前面一个小字说明 + 小胶囊，
    // 名字和一级页签同一套短名（配文 / 转写 / 字幕），从属关系写在外观上。
    HStack(spacing: DesignTokens.Space.sm) {
      Text(title)
        .themedFont(.caption)
        .foregroundStyle(theme.secondaryText)
      ForEach(layers) { layer in
        let isActive = (active ?? layers.first) == layer
        Button {
          MainActor.assumeIsolated { select(layer) }
        } label: {
          Text(layer.tabTitle)
            .themedFont(.caption, weight: isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? theme.selectionText : theme.secondaryText)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(
              isActive ? AnyShapeStyle(theme.selectionFill) : AnyShapeStyle(theme.primaryText.opacity(0.05)),
              in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isActive ? "正在看\(layer.heading)的译文" : "看\(layer.heading)的译文")
        // 每颗胶囊读自己的名字；原来整组的「译文对应」盖到了每颗上，读屏听到两个一样的按钮。
        .accessibilityLabel(layer.tabTitle)
        .accessibilityAddTraits(isActive ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }

  private var readingPanePicker: some View {
    // 只切换已有原文/摘要/译文，不会发起付费生成。重新生成在「AI 处理」。
    HStack(spacing: DesignTokens.Space.sm) {
      Picker("阅读内容", selection: Binding(get: { readingPane }, set: { readingPane = $0 })) {
        ForEach(availableReadingPanes) { pane in
          Text(paneLabel(pane)).tag(pane)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("history-reading-pane-picker")
      if readingPane == .source { reformatControl }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 整理排版的入口。
  ///
  /// **手动按钮，不进自动管线**：重排是主观的，自动跑会攒下一堆用户不想要的
  /// 重排稿，而一条任务只留最新一份——覆盖掉的那份就找不回来了。
  ///
  /// 只在「看原文」时出现：重排的是原文，总结和翻译各有自己的产物。
  @ViewBuilder private var reformatControl: some View {
    let taskID = detail.task.id
    if model.reformatRecord != nil {
      // 已有产物：给切换，不再重复提供生成入口。
      Picker("正文版面", selection: $model.showsReformattedBody) {
        Text("原文").tag(false)
        Text("整理排版").tag(true)
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .labelsHidden()
      .frame(maxWidth: 108)
      .accessibilityIdentifier("history-reformat-toggle")
    } else if case .running = model.reformatState(for: taskID) {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Button("停止") { model.cancelArticleReformat() }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(theme.accent)
      }
      .accessibilityIdentifier("history-reformat-running")
    } else if let snapshot = latestSnapshot, reformatEligibility(snapshot).canReformat {
      Button {
        model.requestArticleReformat(
          taskID: taskID,
          bodyText: snapshot.bodyText,
          model: providerSettings.effectiveTidyModelName
        )
      } label: {
        Label("整理排版", systemImage: "text.append")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.accent)
      .disabled(model.reformatUnavailableReason(taskID: taskID) != nil)
      .help(model.reformatUnavailableReason(taskID: taskID) ?? "给这篇长文分节、加上小标题；原文不会被改动，随时可以切回")
      .accessibilityIdentifier("history-reformat-button")
    }
  }

  private func reformatEligibility(_ snapshot: ContentSnapshot) -> ArticleReformatEligibility {
    model.reformatEligibility(
      bodyText: snapshot.bodyText,
      platform: snapshot.platform,
      isTranscript: snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
    )
  }

  /// 生成中的总结/翻译正文。就是这一页的内容，不再另挂一张预览卡。
  ///
  /// 单独成叶子视图并观察 `LiveRunTextModel`：流式拍点（正文纯增长）只
  /// 重绘这一小块，外层详情的元数据、工具栏、评论区不再每 80ms 跟着
  /// 重求值——那是生成期间滚动持续卡顿的来源。状态行等低频输入以值
  /// 传入，切换时由父视图整体刷新带过来。
  private var liveRunReadingBody: some View {
    LiveRunReadingBody(
      live: appModel.liveRunText,
      statusText: appModel.runStatusText,
      isActive: appModel.runState.isActive,
      startedAt: appModel.runStartedAt,
      hasFailure: appModel.runHasFailure,
      modelFixAction: ModelFailureFix(runState: appModel.runState).map { fix in
        (title: fix.buttonTitle, action: { openSettings() })
      },
      dangerColor: theme.danger,
      font: readingFont.nsFont(),
      color: NSColor(theme.primaryText),
      lineSpacing: MarkdownPresentation.bodyLineSpacing
    )
  }

  // MARK: - 翻译进行中

  /// 翻译进行中的翻译页：和翻完后同一套排版，边翻边换（2026-10-04 Syc）。
  ///
  /// 还没写完第一行时（开始、思考、失败）沿用原来的状态页。之后：顶上一行进度，
  /// 下面按层显示——转写层已译的段落按逐字稿排，没译到的原文淡色接在后面，译文
  /// 到一段替换一段。只有「多写完一行」才重排，流式的每个拍点不碰这一大块。
  private var liveTranslationReadingBody: some View {
    LiveCompletedTextObserver(
      live: appModel.liveRunText,
      key: liveTranslationRenderKey,
      empty: { liveRunReadingBody },
      content: { completed in liveTranslationContent(completed) }
    )
  }

  /// 外层状态变了（换层、开关时间码、运行结束）就要重排；只看译文的话这些变化会被挡掉。
  private var liveTranslationRenderKey: String {
    [
      selectedTranslationLayer?.rawValue ?? "",
      showsTranscriptTimecodes ? "t" : "",
      showsPlainText ? "p" : "",
      appModel.runState.isActive ? "a" : "",
      appModel.runHasFailure ? "f" : "",
    ].joined(separator: "|")
  }

  /// 进行中也给「译文对应」：层取原文那边有的层（译文里还没出现的层也列着，点开就是待译的原文）。
  private var liveTranslationLayers: [SourceLayer] {
    availableSourceLayers.count > 1 ? availableSourceLayers : []
  }

  private func activeLiveTranslationLayer(_ completed: String) -> SourceLayer? {
    let layers = liveTranslationLayers
    if let selected = selectedTranslationLayer, layers.contains(selected) { return selected }
    // 没选过就跟着翻译走：停在正在翻的那一层。
    if let current = LiveTranslationPreview.translatedLayerHeadings(in: completed).last
      .flatMap(SourceLayer.init(heading:)), layers.contains(current) {
      return current
    }
    return layers.first
  }

  private func sourceSnapshot(for layer: SourceLayer) -> ContentSnapshot? {
    switch layer {
    case .caption: latestSourceSnapshot
    case .subtitles: latestSubtitleSnapshot
    case .transcript: latestTranscriptionSnapshot
    }
  }

  @ViewBuilder
  private func liveTranslationContent(_ completed: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      liveTranslationStatusRow
      let layers = liveTranslationLayers
      let active = activeLiveTranslationLayer(completed)
      if layers.count > 1 {
        layerPicker(
          title: "译文对应",
          layers: layers,
          active: active,
          identifier: "history-translation-layer-picker",
          select: { selectedTranslationLayer = $0 }
        )
        .padding(.bottom, 4)
      }
      if let active {
        liveTranslationLayerBody(active, completed: completed)
      } else {
        // 没分层的文章：已写完的段落照常按 Markdown 排。
        liveTranslationMarkdown(LiveTranslationPreview.unlayeredBody(in: completed) ?? completed)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("model-run-output")
  }

  /// 顶上一行：转圈 + 状态 + 已用时；失败或停下时只留状态（红字）。
  private var liveTranslationStatusRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if appModel.runState.isActive {
        ProgressView().controlSize(.small)
        Text("正在翻译，译好的段落会逐段替换下面的原文")
          .themedFont(.callout)
          .foregroundStyle(theme.secondaryText)
        if let startedAt = appModel.runStartedAt {
          RunElapsedLabel(startedAt: startedAt)
            .themedFont(.callout, monospacedDigit: true)
            .foregroundStyle(theme.secondaryText)
        }
      } else {
        Text(appModel.runStatusText)
          .themedFont(.callout)
          .foregroundStyle(appModel.runHasFailure ? theme.danger : theme.secondaryText)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func liveTranslationLayerBody(_ layer: SourceLayer, completed: String) -> some View {
    let translated = LiveTranslationPreview.translatedBody(of: layer.heading, in: completed)
    let source = sourceSnapshot(for: layer).map(LayeredSourceDocument.body(of:))
    if layer == .transcript || layer == .subtitles, !showsPlainText,
       let source, TranscriptManuscript.looksLikeTranscript(source) {
      let pending = LiveTranslationPreview.untranslatedSource(source, afterTranslated: translated)
      VStack(alignment: .leading, spacing: 16) {
        if let translated {
          liveManuscript(translated.replacingOccurrences(
            of: #"\n[ \t]*(?=(?:\d{1,2}:)?\d{1,2}:\d{2}\s)"#, with: "\n\n", options: .regularExpression
          ))
        }
        if let pending, !pending.isEmpty {
          liveManuscript(pending)
            .opacity(0.45)
            .accessibilityLabel("尚未翻译的原文")
        }
      }
    } else if let translated {
      liveTranslationMarkdown(translated)
    } else if let source {
      // 这一层还没轮到：先放原文（淡色），轮到时整段换成译文。
      liveTranslationMarkdown(source).opacity(0.45)
    }
  }

  private func liveManuscript(_ text: String) -> some View {
    TranscriptManuscriptView(
      paragraphs: TranscriptManuscript.paragraphs(of: text),
      showsTimecodes: showsTranscriptTimecodes,
      showsNotes: false,
      readingFont: readingFont,
      primaryTextColor: theme.primaryText,
      secondaryTextColor: theme.secondaryText,
      sealColor: theme.seal,
      onSeek: hasSeekableMedia ? { seconds in model.requestMediaSeek(toSeconds: seconds) } : nil
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func liveTranslationMarkdown(_ text: String) -> some View {
    MarkdownContentView(
      source: translationTimecodesApplied(
        ReadingRenderCache.paneBody(source: text, strippingEchoedMetadata: true),
        pane: .translation
      ),
      sourceURL: URL(string: sourceURL),
      localImageURLs: localImageURLs,
      localMediaFileURL: nil,
      appendsUnusedLocalImages: false,
      groupsConsecutiveImages: !readingFormat.keepsImagePositions,
      readingFont: readingFont,
      primaryTextColor: theme.primaryText,
      secondaryTextColor: theme.secondaryText,
      accentColor: theme.accent,
      showsPlainText: $showsPlainText,
      showsInlinePlainTextToggle: false,
      navigationModules: [],
      anchorScope: anchorScope(for: .translation),
      onFollowWikiLink: { title in model.followWikiLink(toTitle: title) }
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 标题下的一行浅字：作者 · 日期 · 站点。打开/复制链在同一行末尾，不再单独占三行表单。
  private var sourceByline: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text(sourceBylineText)
        .themedFont(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      // 动作和元信息分开：原来「打开」「复制链接」和作者、日期同字号同灰色排在
      // 一行，读起来像四段元信息。改成两个图标按钮，悬停才浮出底色。
      // 只有网页来源才有「原文」可开、可复制；笔记和本机导入的地址是内部地址，
      // 点了没反应、复制出来也没用，干脆不显示（2026-09-24 走查）。
      if Self.isWebURL(sourceURL) {
        Button { openSourceURL() } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(AppIconButtonStyle(size: 22))
        .foregroundStyle(theme.accent)
        .help("在浏览器中打开原文")
        .accessibilityLabel("打开")
        .accessibilityIdentifier("history-source-url-open")
        Button { CopyFeedbackController.shared.copy(sourceURL) } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(AppIconButtonStyle(size: 22))
        .foregroundStyle(theme.accent)
        .help("复制链接")
        .accessibilityLabel("复制链接")
        .accessibilityIdentifier("history-source-url-copy")
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("来源 \(sourceBylineText)")
    .accessibilityIdentifier("history-capture-metadata")
    .help(sourceURL)
  }

  private enum VideoFetchNoticeKind { case cleared, notSaved }

  /// X 推文是视频，但本机没有文件：封面图是视频截帧（`…video_thumb…`）就能认出来。
  private var isUnsavedXVideo: Bool {
    guard detail.media == nil, !model.localMediaCleared,
          (latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform) == "x",
          let cover = sourceFrontmatter.coverImage
    else { return false }
    return cover.contains("video_thumb")
  }

  /// 视频不在本机时的一行说明 + 两个同级按钮（2026-10-03 发布前走查）：原来是一张大卡片
  /// 压在正文上方，次要信息占了首屏；两个动作一个是按钮、一个是文字链接，层级看起来不一样。
  @ViewBuilder
  private func videoFetchNotice(_ kind: VideoFetchNoticeKind) -> some View {
    let full = kind == .cleared
      ? "视频文件已按设置清理，转写文字、评论和笔记都保留着。"
      : "这条有视频，但保存时没下载下来。"
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: DesignTokens.Space.sm) {
        Label {
          ViewThatFits(in: .horizontal) {
            Text(full)
            Text(kind == .cleared ? "视频已按设置清理，文字和笔记都在" : "视频没下载下来")
            Text(kind == .cleared ? "视频已清理" : "视频未保存")
          }
          .lineLimit(1)
        } icon: {
          Image(systemName: kind == .cleared ? "checkmark.circle" : "play.rectangle")
        }
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .help(full)
        .layoutPriority(-1)
        Spacer(minLength: DesignTokens.Space.sm)
        Button {
          let taskID = detail.task.id
          let platform = latestSourceSnapshot?.platform ?? detail.snapshots.last?.platform
          let author = sourceFrontmatter.author
          let source = sourceURL
          model.redownloadClearedVideo(
            taskID: taskID,
            snapshotID: latestSourceSnapshot?.id ?? detail.snapshots.last?.id ?? ContentSnapshotID()
          ) {
            try await sessionMediaPlayback.fetchDescriptor(
              taskID: taskID, platform: platform, sourceURL: source, author: author
            )
          }
        } label: {
          if model.clearedVideoRedownloadState == .running {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("正在下载…")
            }
          } else {
            Label(kind == .cleared ? "重新下载视频" : "下载视频", systemImage: "arrow.down.circle")
          }
        }
        .buttonStyle(.appNormal)
        .disabled(model.clearedVideoRedownloadState == .running || model.isReadOnly)
        .accessibilityIdentifier("history-video-local-cleared-redownload")
        .fixedSize()
        if let url = URL(string: sourceURL), url.scheme?.hasPrefix("http") == true {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Label("打开原页面", systemImage: "safari")
          }
          .buttonStyle(.appNormal)
          .fixedSize()
          .help("在浏览器中打开原页面")
          .accessibilityIdentifier("history-video-local-cleared-open-source")
        }
      }
      if case let .failed(message) = model.clearedVideoRedownloadState {
        Text(message)
          .themedFont(.caption)
          .foregroundStyle(theme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    .padding(.top, 14)
    // 容器自己的标识不能盖掉里面按钮的标识。
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(kind == .cleared ? "history-video-local-cleared" : "history-video-not-saved")
  }

  /// 是不是能在浏览器里打开的网页地址。
  static func isWebURL(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    return lower.hasPrefix("https://") || lower.hasPrefix("http://")
  }

  private var sourceBylineText: String {
    var parts: [String] = []
    if let account = sourceFrontmatter.accountName?.trimmedNonEmpty {
      parts.append(account)
    }
    if let author = sourceFrontmatter.author?.trimmedNonEmpty,
       author != sourceFrontmatter.accountName {
      parts.append(HistoryAuthorDisplay.text(author))
    }
    // 列表行尾是「存入」日期（列表按存入时间分组），这里原来只写发布时间、不带前缀，
    // 同一条在列表里是 8月10日、点开是 8月7日，像数据错了（2026-10-03 发布前走查）。
    // 两个日期都写明是什么；同一天存的不重复。
    if let published = sourceFrontmatter.published {
      parts.append("发布 " + historyPublishedDate(published))
      let saved = HistoryPublishedTimestampFormatter.compactDate(
        Date(timeIntervalSince1970: Double(detail.task.createdAtMilliseconds) / 1_000)
      )
      if saved != HistoryPublishedTimestampFormatter.compactText(published) {
        parts.append("存于 " + saved)
      }
    } else {
      parts.append("存于 " + historyDate(detail.task.createdAtMilliseconds))
    }
    if let host = HistorySourceLinkPresentation.host(sourceURL) {
      parts.append(host)
    }
    // 视频时长、体积原来在视频卡上单独一行（2026-10-04 详情页精简，并进这一行）。
    if localMediaFileURL != nil, let media = HistoryVideoPlayerCard.bylineText(for: detail.media) {
      parts.append(media)
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

  private var showsInlineNote: Bool {
    !isOwnWriting && (isInlineNoteRequested || !model.taskNoteDraft.isEmpty)
  }

  /// 正文底部的笔记、素材类型、标签收成一行（2026-09-23 功能区分层第二批）。
  ///
  /// 原来是一整块常驻展开的表单：笔记输入框、7 个素材类型按钮、标签、一行提示，
  /// 不用也一直占着地方。现在只露三个入口，点了才展开；已经写过的笔记和已有标签照常显示。
  /// 标题下的分类行：归属（自有 / 外部，可改）· 素材类型 · 标签。
  private var classificationBar: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.md) {
      // 无边框菜单自带约 4pt 内边距：不抵掉的话这一行的第一个图标比标题、来源行往右缩一截（2026-10-04 走查）。
      ownershipMenu
        .padding(.leading, -4)
      if model.canEditTags {
        materialTypeMenu
      }
      HistoryTagEditor(tags: detail.tags, model: model, showsMaterialTypes: false, composerInPopover: true)
        .id(ReadingAnchor.module("tags"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .themedFont(.callout)
    .foregroundStyle(theme.secondaryText)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("history-classification-bar")
  }

  /// 归属写在明处：原来只能从右键 / 「更多」里的「改为自有 / 外部」反推现在算什么。
  private var ownershipMenu: some View {
    let host = HistoryPlatformRegistry.canonicalHost(for: URLComponents(string: detail.task.canonicalURL)?.host ?? "")
    let current = ContentOwnership.resolve(
      canonicalURL: detail.task.canonicalURL, host: host, tagNames: detail.tags.map(\.name)
    )
    return Menu {
      OwnershipToggleButton(
        model: model, taskID: detail.task.id, canonicalURL: detail.task.canonicalURL,
        host: host, tagNames: detail.tags.map(\.name)
      )
    } label: {
      Label(current.rawValue, systemImage: current == .own ? OwnershipIcon.own : OwnershipIcon.external)
        .labelStyle(.titleAndIcon)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    // 和同一行的「素材类型」「添加标签」同色：它是一个属性，不是这一页的主操作（2026-09-25）。
    .tint(theme.secondaryText)
    .fixedSize()
    .disabled(!model.canEditTags)
    .help("这条算「\(current.rawValue)」，点一下可以改")
    .accessibilityIdentifier("history-ownership-menu")
  }

  /// 页尾的笔记：读完之后写想法。
  @ViewBuilder private var noteBar: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
      if !showsInlineNote {
        Button {
          isInlineNoteRequested = true
          DispatchQueue.main.async { isInlineNoteFocused = true }
        } label: {
          Label("添加笔记", systemImage: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .themedFont(.callout)
        .foregroundStyle(theme.secondaryText)
        .accessibilityIdentifier("history-inline-note-add")
      }
      if showsInlineNote {
        TextField("这篇内容的笔记", text: $model.taskNoteDraft, axis: .vertical)
          .textFieldStyle(.plain)
          .themedFont(.callout)
          .lineLimit(2...6)
          .padding(8)
          .background(theme.badge, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
          .focused($isInlineNoteFocused)
          .onChange(of: model.taskNoteDraft) { _, _ in
            model.scheduleNoteSave(taskID: detail.task.id)
          }
          .accessibilityLabel("这篇内容的笔记")
          .accessibilityIdentifier("history-inline-note")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("history-note-tag-bar")
  }

  /// 素材类型收成一个下拉：贴了哪些就直接写在按钮上，没贴时只显示「素材类型」。
  /// 预置名字就是普通标签，侧栏筛选、搜索、MCP 读到的都是同一回事。
  private var materialTypeMenu: some View {
    let present = Set(detail.tags.map(\.normalizedName))
    let entries = MaterialCatalog.MaterialType.allCases.map { ($0.tagName, $0.systemImage) }
    let chosen = entries.map(\.0).filter { name in
      present.contains(HistoryTagNormalizer.normalized(name)?.normalizedName ?? name)
    }
    return Menu {
      ForEach(entries, id: \.0) { name, symbol in
        let normalized = HistoryTagNormalizer.normalized(name)?.normalizedName ?? name
        let isOn = present.contains(normalized)
        Button {
          if isOn, let tag = detail.tags.first(where: { $0.normalizedName == normalized }) {
            model.removeTag(tag)
          } else {
            model.addTag(name)
          }
        } label: {
          Label(name, systemImage: isOn ? "checkmark" : symbol)
        }
        .disabled(!isOn && detail.tags.count >= HistoryTagNormalizer.maximumTagsPerTask)
        .accessibilityIdentifier("history-material-\(name)")
      }
    } label: {
      // 没选时写成动作「选择素材类型」并调淡：只写「素材类型」看着像已选了一个叫这个的值
      // （2026-10-01 走查）；改成「素材类型：未设置」又像一张没填完的表，每条都在提醒
      // 「这里缺了」。和同一行的「添加标签」一样用动词（2026-10-03 发布前走查）。
      Label(chosen.isEmpty ? "选择素材类型" : chosen.joined(separator: "、"), systemImage: "square.grid.2x2")
    }
    .menuStyle(.borderlessButton)
    // 无边框菜单默认用强调色画成蓝字；和同一行的「添加笔记」「添加标签」统一成次要灰。
    .tint(chosen.isEmpty ? theme.secondaryText.opacity(0.6) : theme.secondaryText)
    .fixedSize()
    .help("标记这条是哪类素材：观点、案例、数据……")
    .accessibilityIdentifier("history-material-types")
  }

  /// 同一组互动数据只显示一次，而且退到背景：点赞数对「读这篇」几乎没有帮助，
  /// 原来和作者行一样显眼，视线要先跨过一排数字才落到正文。
  /// 「采集时快照」不再占位置，只在悬停时说明。
  private func engagementDisclosure(_ note: MarkdownNoteFrontmatter) -> some View {
    engagementCompactChips(note)
      .themedFont(.caption2)
      .help("互动数据是保存时的数字，不会随原帖更新")
      .accessibilityIdentifier("history-engagement-more")
  }

  @ViewBuilder
  private func engagementCompactChips(_ note: MarkdownNoteFrontmatter) -> some View {
    let host = engagementHost
    let slots = CreatorWorkMetricLayout.visibleSlots(forHost: host) { $0.value(from: note) }
    if slots.isEmpty {
      EmptyView()
    } else {
      // 互动数据对「理解内容」是次级信息：收成一行弱化纯文本，不再让带图标的
      // 指标在正文上方争注意力。整行作为一个无障碍值读出。
      // 次要文字色而不是 .tertiary：三级灰在白底上约 2:1，「点赞 3508」几乎读不出来（2026-10-03 走查）。
      // 退到背景靠的是小一号字，不是把字压到看不清。
      Text(engagementSummaryText(slots: slots, host: host, note: note))
        .themedFont(.footnote)
        .foregroundStyle(theme.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("互动数据")
        .accessibilityValue(engagementSummaryText(slots: slots, host: host, note: note))
        .accessibilityIdentifier("history-engagement-stats")
    }
  }

  /// 互动数据的一行式文本：只呈现抓到的指标，沿用原有胶囊的顺序与文案。
  private func engagementSummaryText(
    slots: [CreatorWorkMetricKind],
    host: String,
    note: MarkdownNoteFrontmatter
  ) -> String {
    slots
      .map { slot in "\(slot.title(forHost: host)) \(CreatorWorkMetricLayout.displayValue(slot.value(from: note)).visible)" }
      .joined(separator: "  ·  ")
  }

  private var engagementHost: String {
    if let host = URL(string: sourceURL)?.host, !host.isEmpty {
      return host
    }
    return isWeChatCapture ? "mp.weixin.qq.com" : ""
  }

  private func compactEngagementCount(_ value: String) -> String {
    HistoryEngagementCount.compact(value)
  }

  /// 互动数单独一行。作者/发布/公众号已经收进 byline，这里不再重复。
  /// 弱化为一行小字，不再让带图标的指标在正文上方争注意力。
  @ViewBuilder
  private func notePropertiesStrip(_ note: MarkdownNoteFrontmatter) -> some View {
    let host = engagementHost
    let slots = CreatorWorkMetricLayout.visibleSlots(forHost: host) { $0.value(from: note) }
    if !slots.isEmpty {
      // 次要文字色而不是 .tertiary：三级灰在白底上约 2:1，「点赞 3508」几乎读不出来（2026-10-03 走查）。
      // 退到背景靠的是小一号字，不是把字压到看不清。
      Text(engagementSummaryText(slots: slots, host: host, note: note))
        .themedFont(.footnote)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("互动数据")
        .accessibilityValue(engagementSummaryText(slots: slots, host: host, note: note))
        .accessibilityIdentifier("history-engagement-stats")
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
    // 只在上下方向裁：左右各放出一条边，标题左侧的收起三角（`SectionFoldToggle`）
    // 画在正文左边界外，原来的 `.clipped()` 会把它整个裁掉。
    .clipShape(HorizontalBleedClip(bleed: 32))
    // 初始面板由 `pane == effectiveReadingPane` 条件挂载（visited 起始为空，
    // 惰性成立）；这里只负责把后续切换过的面板记入保活集合。
    .onChange(of: effectiveReadingPane) { _, pane in
      var visited = visitedReadingPanes
      if visited.insert(pane).inserted {
        visitedReadingPanesStore = PerItem(taskID: detail.task.id, value: visited)
      }
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
        // 只动透明度，容器高度照旧一步到位，不触发长文重排。旧的一页立刻收掉、只让新的一页
        // 淡入：两页同时半透明叠在一起时，标题压着正文，字糊成一片（2026-10-04 真机录屏）。
        // 用限定范围的动画：只给这一层透明度加动画。`.animation(_:value:)` 会把同一拍里面板
        // 内部的尺寸变化也一起动画，每帧重排整篇长文（2026-10-04 Instruments）。
        .animation(reduceMotion || !isActive ? nil : .easeOut(duration: 0.16)) {
          $0.opacity(isActive ? 1 : 0)
        }
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
    }
  }

  /// 必须是**一个**视图：它放在 `mountedReadingPane` 的 ZStack 里，外面挂的 opacity、
  /// 高度测量都按「一个面板」算。原来这里 `@ViewBuilder` 直接吐出「不完整提示 + 层切换 +
  /// 正文」几个兄弟视图，在 ZStack 里各自成一层叠在同一个位置——翻译页的「配文 / 视频转写」
  /// 和正文的「目录 · N 个模块」于是压在一起，面板高度也只量到其中一块。
  private func readingPaneBody(_ pane: ReadingPane) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      readingPaneContent(pane)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func readingPaneContent(_ pane: ReadingPane) -> some View {
    switch pane {
    case .summary, .translation:
      if showsLiveRunInReadingPane, liveRunReadingPane == pane {
        if pane == .translation { liveTranslationReadingBody } else { liveRunReadingBody }
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
        if pane == .translation, let transcriptBody = translatedTranscriptBody {
          // 译出来的转写稿按逐字稿排，和「转写」页同一个样子：时间码挂左页边、段距一致、
          // 点时间码跳视频（2026-10-04 走查：原来时间码夹在正文里，有的行紧挨、有的空一行）。
          TranscriptManuscriptView(
            paragraphs: TranscriptManuscript.paragraphs(of: transcriptBody),
            showsTimecodes: showsTranscriptTimecodes,
            showsNotes: false,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            sealColor: theme.seal,
            onSeek: hasSeekableMedia ? { seconds in model.requestMediaSeek(toSeconds: seconds) } : nil
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-reading-result")
        } else {
        // 旧版翻译把元数据块也翻了一遍，块卡在译文中段（前面是翻译后的标题），
        // 开头剥离对它无效。显示时按白名单再清一次；只清翻译——总结里出现
        // 同构块的可能性低，且误删的代价是丢正文。
        // 剥离与清理都是整篇扫描，走备忘缓存，正文没变不重付。
        // Summaries rarely carry images; still allow local map if present.
        MarkdownContentView(
          source: translationTimecodesApplied(
            (pane == .summary ? MarkdownPresentation.strippingSummaryPreamble : { $0 })(displayedArtifactMarkdown(
              ReadingRenderCache.paneBody(
                // 分层时只喂当前那一层，元数据清理仍按整篇的规则走。
                source: (pane == .translation ? activeTranslationBody : nil) ?? artifact.bodyText,
                strippingEchoedMetadata: pane == .translation
              )
            )),
            pane: pane
          ),
          sourceURL: URL(string: sourceURL),
          localImageURLs: localImageURLs,
          localMediaFileURL: nil,
          appendsUnusedLocalImages: !readingFormat.keepsImagePositions,
          groupsConsecutiveImages: !readingFormat.keepsImagePositions,
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
        }
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
        sourceLayerHeading(displayHeading(LayeredSourceDocument.transcriptHeading))
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
        // 配文 / 字幕 / 转写各是表头上的一个页签（见 readingTabs），这里只画选中的那层。
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
              heading: displayHeading(LayeredSourceDocument.transcriptHeading),
              snapshot: transcript,
              isExpanded: $isTranscriptExpanded,
              showsSpeakerBar: true
            )
          }
        case nil:
          EmptyView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .swapReveal(on: activeSourceLayer)
      .accessibilityIdentifier("history-reading-source")
    } else if let snapshot = (isDouyinCapture && !isDouyinImagePostCapture)
      ? latestTranscriptionSnapshot
      : latestSnapshot, !snapshot.bodyText.isEmpty {
      if snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue {
        collapsibleSourceSection(
          heading: displayHeading(LayeredSourceDocument.transcriptHeading),
          snapshot: snapshot,
          isExpanded: $isTranscriptExpanded,
          showsSpeakerBar: true
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
      } else if LayeredSourceDocument.placeholderCaptionMethods.contains(snapshot.captureMethod),
                latestTranscriptionSnapshot == nil {
        // 还没转写的录音：那段「点转写…」只是占位说明，不当正文大字印出来。
        Label("还没有转写。点右上角「转写」，在本机把录音转成文字。", systemImage: "waveform")
          .themedFont(.callout)
          .foregroundStyle(theme.secondaryText)
          .padding(.vertical, DesignTokens.Space.sm)
          .accessibilityIdentifier("history-reading-source-untranscribed")
      } else {
        // 单层网页正文不再挂「正文」小标题：页签上已经写着「原文」，同一件事说两遍（2026-09-25 走查）。
        // 有多层（配文 / 字幕 / 转写）时各层仍带自己的名字。
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

  /// 转写稿的时间码挂在左页边（44pt 宽 + 14pt 间距），「展开全文 / 收起」跟正文栏对齐，
  /// 不要缩在页边的时间码底下。
  private func sourceGutterInset(_ snapshot: ContentSnapshot) -> CGFloat {
    guard !showsPlainText, showsTranscriptTimecodes,
          snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue else { return 0 }
    // 没有时间码的转写走普通阅读区，没有页边。
    let body = displayedSourceMarkdown(snapshot, bodyOverride: nil)
    guard TranscriptManuscript.looksLikeTranscript(body) || !SpeakerTranscript.turns(in: body).isEmpty else { return 0 }
    return 58
  }

  @ViewBuilder
  private func collapsibleSourceSection(
    heading: String,
    snapshot: ContentSnapshot,
    isExpanded: Binding<Bool>,
    showsSpeakerBar: Bool = false
  ) -> some View {
    let body = LayeredSourceDocument.body(of: snapshot)
    let long = isLongSource(snapshot)
    let collapsed = long && !isExpanded.wrappedValue && !isEditingTranscription
    // 有切换控件时不再重复一遍层名：控件上就写着「配文 / 视频转写」，
    // 底下再来一行同样的字只是多占一行高度。没有控件的路径（只有一层、
    // 或者非分层来源）仍然要这个标题，否则那段正文就没有名字了。
    // 页签已经叫「转写稿 / 校对稿」时，再印一行「视频转写」也是同一件事说两遍（2026-10-04）。
    let showsHeading = !showsSourceLayerPicker && singlePaneTranscriptSnapshot?.id != snapshot.id
    let showsExpandControl = long && !isEditingTranscription
    let collapseAnchor = "source-collapse-\(heading)"
    VStack(alignment: .leading, spacing: 8) {
      if showsHeading {
        sourceLayerHeading(heading)
      }
      // 说话人一栏属于这份转写，排在「录音转写」小标题之下；原来排在上面，小标题像是夹在两块中间。
      if showsSpeakerBar {
        speakerBar(transcript: snapshot)
      }
      if collapsed {
        sourceSnapshotReader(snapshot, bodyOverride: sourcePreview(body))
        Button("展开全文") { isExpanded.wrappedValue = true }
          .buttonStyle(.plain)
          .themedFont(.callout, weight: .medium)
          // 可点的文字统一用靛青（2026-09-29 走查：原来是正文色粗体，看不出能点）。
          .foregroundStyle(theme.accent)
          .padding(.top, 4)
          .padding(.leading, sourceGutterInset(snapshot))
          .accessibilityIdentifier("history-source-expand-inline")
      } else {
        sourceSnapshotReader(snapshot)
        if showsExpandControl {
          Button("收起") {
            isExpanded.wrappedValue = false
            sourceCollapseScrollTarget = collapseAnchor
          }
          .buttonStyle(.plain)
          .themedFont(.callout, weight: .medium)
          // 可点的文字统一用靛青（2026-09-29 走查：原来是正文色粗体，看不出能点）。
          .foregroundStyle(theme.accent)
          .padding(.top, 4)
          .padding(.leading, sourceGutterInset(snapshot))
          .accessibilityIdentifier("history-source-collapse-inline")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .id(collapseAnchor)
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

  /// 译文 / 总结开头如果是一行和页头标题同名的 `# 标题`，不再印第二遍。
  ///
  /// 翻译产物几乎总是以「# 译后标题」开头，而页头显示的正是这个译后标题——
  /// 同一句话在屏幕上下相隔 40pt 出现两次。只认 ATX 标题行（`# `），正文首段
  /// 恰好等于标题的情况不动。
  private func displayedArtifactMarkdown(_ body: String) -> String {
    guard !isOwnWriting else { return body }
    return CapturedSourceBodyPresentation.strippingEchoedOpening(
      title: readingPrimaryTitle, from: body, style: .stripSyntheticTitleHeadingOnly
    )
  }

  /// 机器听写的那份转写稿（校对前）。朱批和「原稿」都拿它当底。
  private var machineTranscriptSnapshot: ContentSnapshot? {
    detail.snapshots.last {
      $0.sourceKind == CapturedDocument.Origin.localTranscription.rawValue
        && $0.captureMethod != Self.tidyCaptureMethod
    }
  }

  private static let tidyCaptureMethod = ProcessStepRecord.tidyCaptureMethod

  @ViewBuilder
  private func transcriptManuscript(snapshot: ContentSnapshot, body fullBody: String, previewLimit: Int?) -> some View {
    let split = TranscriptManuscript.splittingComments(fullBody)
    let body = split.transcript
    let machine = snapshot.captureMethod == Self.tidyCaptureMethod ? machineTranscriptSnapshot : nil
    let mode = machine == nil ? TranscriptManuscript.Mode.revised : manuscriptMode
    let machineBody = machine.map { TranscriptManuscript.splittingComments(displayedSourceMarkdown($0, bodyOverride: nil)).transcript }
    // 朱批开关上要写改了几处，所以只要有机器原稿就算一遍（按快照缓存，只算一次）。
    let revision: TranscriptRevision.Result? = {
      guard let machine, let machineBody else { return nil }
      return TranscriptManuscript.revision(
        originalKey: machine.id.rawValue, original: machineBody,
        revisedKey: snapshot.id.rawValue, revised: body
      )
    }()
    let shown = mode == .original ? (machineBody ?? body) : body
    VStack(alignment: .leading, spacing: 18) {
      // 表头已经拆成「校对稿 / 原稿」两个页签、朱批开关也在表头时，这里不再画第二排。
      if machine != nil, !splitsManuscriptTabs {
        manuscriptModePicker(current: mode, revision: revision)
      }
      TranscriptManuscriptView(
        paragraphs: TranscriptManuscript.paragraphs(of: shown, revision: mode == .marked ? revision : nil)
          .filter { previewLimit == nil || $0.offset < previewLimit! },
        showsTimecodes: showsTranscriptTimecodes,
        showsNotes: mode == .marked,
        readingFont: sourcePaneReadingFont(snapshot),
        primaryTextColor: mode == .original ? theme.primaryText.opacity(0.8) : theme.primaryText,
        secondaryTextColor: theme.secondaryText,
        sealColor: theme.seal,
        onSeek: hasSeekableMedia ? { seconds in model.requestMediaSeek(toSeconds: seconds) } : nil
      )
      .simultaneousGesture(
        TapGesture().onEnded {
          // 只有看的就是这份正文时才进编辑：朱批和原稿里点一下不该改到校对稿。
          guard mode == .revised, canEditSource(snapshot), !model.isReadOnly else { return }
          beginSourceEditing(snapshot, displayedSnippet: nil)
        }
      )
      // 评论单独成一节，用评论组件排；折叠预览时不露（它在全文最后）。
      if previewLimit == nil, mode != .original, let comments = split.comments {
        MarkdownContentView(
          source: comments,
          sourceURL: URL(string: sourceURL),
          localImageURLs: localImageURLs,
          localMediaFileURL: nil,
          readingFont: sourcePaneReadingFont(snapshot),
          primaryTextColor: theme.primaryText,
          secondaryTextColor: theme.secondaryText,
          accentColor: theme.accent,
          showsPlainText: .constant(false),
          showsInlinePlainTextToggle: false,
          anchorScope: anchorScope(for: .source) + ".comments"
        )
        .padding(.leading, showsTranscriptTimecodes ? 58 : 0)
        .accessibilityIdentifier("transcript-comments")
      }
    }
  }

  /// 「校对稿 / 原稿」两个选项，右边一个「朱批」开关（2026-09-28 Syc 选定）。
  ///
  /// 朱批是同一篇校对稿加上批改记号，不单独成一页：平时读干净的，想核对时点开。
  private func manuscriptModePicker(current: TranscriptManuscript.Mode, revision: TranscriptRevision.Result?) -> some View {
    let showsOriginal = current == .original
    return HStack(spacing: DesignTokens.Space.lg) {
      ForEach([TranscriptManuscript.Mode.revised, .original]) { mode in
        let selected = (mode == .original) == showsOriginal
        Button { manuscriptMode = mode } label: {
          Text(mode.title)
            .themedFont(.callout, weight: selected ? .medium : .regular)
            .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) {
              Rectangle().fill(selected ? theme.accent : Color.clear).frame(height: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("transcript-manuscript-mode-\(mode.rawValue)")
      }
      Spacer(minLength: 0)
      if showsOriginal {
        Text("Apple 本机听写原样")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
      } else {
        Button {
          manuscriptMode = current == .marked ? .revised : .marked
        } label: {
          Text(current == .marked ? "收起朱批" : manuscriptSummary(revision))
            .themedFont(.caption, weight: .medium)
            .foregroundStyle(theme.seal)
        }
        .buttonStyle(.plain)
        .help(current == .marked ? "收起批改记号" : "显示模型相对本机转写改了哪些字")
        .accessibilityIdentifier("transcript-manuscript-mode-marked")
      }
    }
    .accessibilityIdentifier("transcript-manuscript-modes")
  }

  private func manuscriptSummary(_ revision: TranscriptRevision.Result?) -> String {
    let changes = revision?.changes.count ?? 0
    let deletions = revision?.deletions.count ?? 0
    if changes == 0, deletions == 0 { return "朱批 · 只补了标点" }
    return deletions > 0 ? "朱批 · 改字 \(changes) 处 · 删去 \(deletions) 处" : "朱批 · 改字 \(changes) 处"
  }

  /// 题跋：何时从哪里汲来（或自己记下）、经过哪些加工。
  private var colophonText: String {
    exportColophonContext.text
  }

  /// 落款日期的公历写法，给悬停提示用。
  private var colophonGregorianHelp: String {
    let date = Date(timeIntervalSince1970: Double(detail.task.createdAtMilliseconds) / 1_000)
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "公历\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
  }

  /// 本地文件导入时读到的下载来源（没有下载标记、或不是本地文件时为 nil）。有网址时题跋可以点开。
  private var colophonDownloadSource: LocalFileProvenance? {
    exportColophonContext.downloadSource
  }

  private var colophonGlyph: SealMark.Glyph {
    exportColophonContext.glyph
  }

  /// 阅读卡里不再重复印标题。笔记是用户自己写的，开头的标题要留着。
  /// 正文展示稿。按快照记住结果：7 万字的转写稿每过一遍这些清洗要几十毫秒，
  /// 而详情页的 body 一次会调它好几次（原稿、校对稿、朱批各一份），悬停、吸顶等
  /// 小状态一变就整页重求值——不记住的话每次都重算，滑动时主线程被占满（2026-10-04）。
  /// 记住同一个 String 实例还有一个好处：下游按内容比对的缓存遇到同一块内存，比对是瞬时的。
  private func displayedSourceMarkdown(_ snapshot: ContentSnapshot, bodyOverride: String?) -> String {
    let key = "displayedSource|\(bodyOverride?.count ?? -1)|\(title)|\(isUserNote ? noteTitleDraft : "")|\(showsCaptionTitleAbove ? readingPrimaryTitle : "")"
    return derivedMemo.value(key, snapshot: snapshot) {
      computeDisplayedSourceMarkdown(snapshot, bodyOverride: bodyOverride)
    }
  }

  private func computeDisplayedSourceMarkdown(_ snapshot: ContentSnapshot, bodyOverride: String?) -> String {
    var cleaned = bodyOverride ?? ReadingRenderCache.paneBody(
      source: snapshot.bodyText,
      strippingEchoedMetadata: false
    )
    // 导入的图片：正文只放图，识别出的文字在下面单独一条可展开的小节里。
    if isImportedImage(snapshot) { cleaned = LocalImportDocument.splitImageBody(cleaned).image }
    cleaned = CapturedSourceBodyPresentation.inliningReferenceLinks(cleaned)
    // 笔记正文首行的 `# 标题` 和上面的标题框是同一句话：读的时候藏掉这一行，编辑时照常在。
    // 标题从正文首行派生后，页面顶上原来连着两个一样的大标题（2026-10-01 走查）。
    if isUserNote { return DailyNoteTitleFormat.strippingLeadingHeading(cleaned, matching: noteTitleDraft) }
    guard !isOwnWriting else { return cleaned }
    let style: CapturedSourceBodyPresentation.EchoedOpeningStyle =
      .stripSyntheticTitleHeadingOnly
    // 早先导入的备忘录里，被格式切碎的标题已经存进库了；读的时候按导入同一套规则合回来。
    // 要在剥「和标题同一句」的开头之前合：合完才认得出它就是标题（标题见 `title`）。
    if snapshot.platform == "applenotes" {
      cleaned = AppleNoteHTML.mergingFragmentedHeadings(cleaned.components(separatedBy: "\n")).joined(separator: "\n")
    }
    cleaned = MarkdownNoteFrontmatter.strippingViewCountUnderLeadingHeading(cleaned)
    var body = CapturedSourceBodyPresentation.strippingEchoedOpening(title: title, from: cleaned, style: style)
    // 标题翻译成中文后，正文开头那行英文原标题和上面的标题不再「同一句话」，
    // 照样重复了一遍（YouTube，2026-10-03 走查）。再按原标题剥一次。
    for original in [snapshot.title, MarkdownNoteFrontmatter.parse(snapshot.bodyText).originalTitle] {
      guard let original, original != title else { continue }
      body = CapturedSourceBodyPresentation.strippingEchoedOpening(title: original, from: body, style: style)
    }
    body = CapturedSourceBodyPresentation.readableTranscriptSections(body)
    body = CapturedSourceBodyPresentation.strippingBackNavigationLinks(body)
    if showsCaptionTitleAbove, snapshot.id == latestSourceSnapshot?.id {
      body = CapturedSourceBodyPresentation.strippingLeadingLine(body, equalTo: readingPrimaryTitle)
    }
    return CapturedSourceBodyPresentation.preservingCaptionParagraphs(body, platform: snapshot.platform)
  }

  @ViewBuilder
  private func sourceSnapshotReader(_ snapshot: ContentSnapshot, bodyOverride: String? = nil) -> some View {
        if let notice = captureCompletenessNotice(snapshot.completeness) {
          Label(notice, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            .accessibilityIdentifier("capture-truncated-notice")
        }
        // 浏览器扩展那条路不经过「添加链接」的报错页拦截，报错页会被原样存下来
        // （2026-09-25 走查：一条 GitHub 记录正文是「Uh oh! There was an error while loading」）。
        // 读的时候至少说清楚，并给出路。
        if bodyOverride == nil, capturedErrorPageNotice(snapshot) != nil {
          Label(capturedErrorPageNotice(snapshot) ?? "", systemImage: "exclamationmark.triangle")
            .foregroundStyle(theme.warning)
            .padding(.bottom, 6)
            .accessibilityIdentifier("capture-error-page-notice")
        }
        // 可写正文：本机转写、笔记、稿、作品。网页捕获保持只读。
        // 默认看排版，单击进源码；新建空笔记直接进入编辑。
        if bodyOverride == nil, canEditSource(snapshot), isEditingTranscription {
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Space.sm) {
              Text(noteEditorStatusText(isDirty: sourceDraftIsDirty(snapshot)))
                .themedFont(.caption)
                .foregroundStyle(.tertiary)
                .animation(historyUIAnimation(reduceMotion: reduceMotion), value: noteSaveIndicator)
                .accessibilityIdentifier("history-note-save-state")
              if isOwnWriting {
                Text("\(noteCharacterCount) 字")
                  .themedFont(.caption)
                  .foregroundStyle(.tertiary)
                  .accessibilityIdentifier("history-note-word-count")
              }
            }
            Button("保存") { saveTranscriptionDraft(snapshot, exiting: false) }
              .keyboardShortcut("s", modifiers: .command)
              .hidden()
              .frame(width: 0)
              .accessibilityIdentifier("history-transcription-edit-save")
          }
          .frame(height: isOwnWriting || sourceDraftIsDirty(snapshot) || noteSaveIndicator ? nil : 0)
          .clipped()
          .padding(.bottom, isOwnWriting || sourceDraftIsDirty(snapshot) || noteSaveIndicator ? DesignTokens.Space.sm : 0)
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
        } else if bodyOverride == nil,
                  snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue,
                  LocalTranscriptQuality.isNoSpeechArtifact(snapshot.bodyText) {
          // 早先存下的「00:00 you」这类：没有人说话，听写只凭空出了一个词，不当正文印出来。
          Label(LocalVideoTranscriptionError.emptyTranscript.userMessage, systemImage: "waveform.slash")
            .themedFont(.callout)
            .foregroundStyle(theme.secondaryText)
            .padding(.vertical, DesignTokens.Space.sm)
            .accessibilityIdentifier("history-transcript-no-speech")
        } else if model.showsReformattedBody, let reformatted = model.reformatRecord?.bodyText {
          // 重排稿：原文一个字没动，这里只是换一份正文来渲染。用户随时切回。
          MarkdownContentView(
            source: reformatted,
            sourceURL: URL(string: sourceURL),
            localImageURLs: localImageURLs,
            localMediaFileURL: localMediaFileURL,
            appendsUnusedLocalImages: !readingFormat.keepsImagePositions,
            groupsConsecutiveImages: !readingFormat.keepsImagePositions,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            accentColor: theme.accent,
            showsPlainText: $showsPlainText,
            showsInlinePlainTextToggle: false,
            navigationModules: navigationModules,
            anchorScope: anchorScope(for: .source),
            revealText: pendingSourceCitation,
            onFollowWikiLink: { title in model.followWikiLink(toTitle: title) },
            onRequestEdit: nil
          )
        } else if !showsPlainText,
                  case let turns = SpeakerTranscript.turns(in: displayedSourceMarkdown(snapshot, bodyOverride: bodyOverride)),
                  !turns.isEmpty {
          // 分过说话人：按一轮轮发言排，名字和时间单独一行（时间码开关照常生效）。
          SpeakerTranscriptView(
            turns: turns,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            accentColor: theme.accent,
            showsTimecodes: showsTranscriptTimecodes,
            onSeek: { seconds in model.requestMediaSeek(toSeconds: seconds) }
          )
        } else if !showsPlainText,
                  snapshot.sourceKind == CapturedDocument.Origin.localTranscription.rawValue,
                  case let manuscriptBody = displayedSourceMarkdown(snapshot, bodyOverride: nil),
                  TranscriptManuscript.looksLikeTranscript(manuscriptBody) {
          // 逐字稿按书排：时间码挂左页边；有校对稿时可看朱批（2026-09-28 自有风格）。
          // 长稿折叠时只排预览长度以内的段落；朱批位置照旧按整篇算，不会错位。
          transcriptManuscript(snapshot: snapshot, body: manuscriptBody, previewLimit: bodyOverride?.count)
        } else if !showsPlainText, showsTranscriptTimecodes, !transcriptParagraphs.isEmpty,
                  snapshot.id == transcriptParagraphsSnapshotID {
          // 有分段时间的转写稿走时间线视图；纯文本模式仍回普通阅读区，那是
          // 「我只想看字」的入口，不该被锚点打断。
          TranscriptTimelineView(
            paragraphs: transcriptParagraphs,
            readingFont: readingFont,
            primaryTextColor: theme.primaryText,
            secondaryTextColor: theme.secondaryText,
            accentColor: theme.accent,
            onSeek: { milliseconds in
              model.requestTranscriptSeek(taskID: detail.task.id, milliseconds: milliseconds)
            }
          )
        } else {
          MarkdownContentView(
            // 链接化放在**最外层**：先让 paneBody 做完它的清理，再把时间码变成
            // 链接，免得清理步骤把刚生成的链接语法拆掉。
            source: showsTranscriptTimecodes
              ? timestampLinked(displayedSourceMarkdown(snapshot, bodyOverride: bodyOverride))
              : TranscriptReadingText.removingTimecodes(from: displayedSourceMarkdown(snapshot, bodyOverride: bodyOverride)),
            sourceURL: URL(string: sourceURL),
            localImageURLs: localImageURLs,
            localMediaFileURL: localMediaFileURL,
            appendsUnusedLocalImages: !readingFormat.keepsImagePositions,
            groupsConsecutiveImages: !readingFormat.keepsImagePositions,
            readingFont: sourcePaneReadingFont(snapshot),
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
            onRequestEdit: bodyOverride == nil && canEditSource(snapshot) && !model.isReadOnly && !isInTrash
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

  /// 译文里的转写稿同样受「时间码」开关控制；总结不动。
  private func translationTimecodesApplied(_ text: String, pane: ReadingPane) -> String {
    guard pane == .translation, !showsTranscriptTimecodes else { return text }
    return TranscriptReadingText.removingTimecodes(from: text)
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

  /// 回收站里的东西只读：要改先「恢复」。原来删掉的空笔记打开就是编辑态，
  /// 光标在闪、写着「在这里写下你的想法…」（2026-10-04 走查）。
  private var isInTrash: Bool { model.selectedScope == .trash }

  private func beginSourceEditing(_ snapshot: ContentSnapshot, displayedSnippet: String?) {
    guard !model.isReadOnly, !isInTrash, !isEditingTranscription else { return }
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
  /// 读当前转写稿的分段时间。
  ///
  /// 读的是**这一条正在显示的**转写 snapshot：一条任务可能有原稿和整理稿两份，
  /// 只有原稿带分段。读不到就清空，退回普通阅读区。
  private func loadTranscriptParagraphs() {
    guard let snapshot = latestTranscriptionSnapshot else {
      transcriptParagraphs = []
      transcriptParagraphsSnapshotID = nil
      return
    }
    transcriptParagraphs = model.transcriptParagraphs(snapshotID: snapshot.id)
    transcriptParagraphsSnapshotID = transcriptParagraphs.isEmpty ? nil : snapshot.id
  }

  /// 按当前正文重算排版档案。
  ///
  /// 取的是**正在显示的那份**正文：整理稿、翻译稿和原稿的形态可以完全不同
  /// （模型整理会把一堵段落墙分出标题），照旧稿的档案排版就会错。
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
    noteLastSavedAt = Date()
    noteSaveIndicator = true
    if isOwnWriting {
      // 存过之后这条笔记的「库里那份」就是刚写的内容了，切走时不该再存一遍。
      editingNote = (detail.task.id, snapshot.id, savedDraft)
      // 标题还是默认值时，用正文首个一级标题补上：写笔记的人极少先想标题。
      // 写回库只认一级标题（derivedTitle），不用显示时那套宽规则：自动保存发生在打字中途，
      // 拿第一行当标题会把刚敲下的半句话钉成标题。
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
        // 这一格只在生成刚起步、还没有字的时候露面：页签只列已经有的东西，
        // 生成入口是表头右边的按钮，这里不再重复放一个。
        if canRunHistory || showsCurrentCapture {
          Text(pane == .translation ? "点表头右边的「翻译」生成" : "点表头右边的「总结」生成")
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
          Text("点上方的「转写」开始")
            .themedFont(.callout)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 24)
    .accessibilityIdentifier(pane == .source ? "history-reading-source-empty" : "history-reading-result-empty")
  }

  /// 转写稿上方的「说话人」一行（2026-09-23）：还没分过就给两个入口（本机 / 在线），
  /// 分过就列出说话人，点名字改名。只在有本机音频的条目上出现——分离要读录音本身。
  /// 还没分说话人时不占正文上方一行：入口在「处理」面板里（2026-10-04 详情页精简）。
  /// 分过（列出说话人、点名字改名）、正在分、分失败时才出现。
  @ViewBuilder private func speakerBar(transcript: ContentSnapshot) -> some View {
    let speakers = SpeakerTranscript.speakers(in: transcript.bodyText)
    let state = model.speakerDiarizationState(for: detail.task.id)
    if localMediaFileURL != nil, !speakers.isEmpty || state != .idle {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: DesignTokens.Space.sm) {
          Image(systemName: "person.2")
            .foregroundStyle(theme.secondaryText)
          if case let .running(message) = state {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(theme.secondaryText)
          } else if speakers.isEmpty {
            Text("区分说话人").foregroundStyle(theme.secondaryText)
            speakerModeButton("本机", help: "免费，录音不离开这台 Mac") { model.diarizeSpeakers(detail: detail, mode: .local) }
              .accessibilityIdentifier("history-diarize-local")
            speakerModeButton("在线", help: "上传录音到你配置的在线服务，按时长计费，通常更准") { isOnlineDiarizationConfirmPresented = true }
              .accessibilityIdentifier("history-diarize-online")
          } else {
            ForEach(speakers, id: \.self) { name in
              Button {
                speakerNameDraft = name
                renamingSpeaker = name
              } label: {
                Text(name)
                  .padding(.horizontal, 8).padding(.vertical, 2)
                  .background(theme.primaryText.opacity(0.06), in: Capsule())
              }
              .buttonStyle(.plain)
              .help("点击改名，比如改成「张总」")
              .popover(isPresented: Binding(
                get: { renamingSpeaker == name },
                set: { if !$0 { renamingSpeaker = nil } }
              )) {
                HStack(spacing: 8) {
                  TextField("名字", text: $speakerNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(commitSpeakerRename)
                  Button("改名", action: commitSpeakerRename)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
              }
              .accessibilityIdentifier("history-speaker-\(name)")
            }
            // 紧跟在说话人后面：原来前后各一个 Spacer，按钮被推到行中间偏右，
            // 跟哪一边都对不上（2026-09-24 走查）。
            Menu {
              Button("本机重新区分") { model.diarizeSpeakers(detail: detail, mode: .local) }
              Button("在线重新区分…") { isOnlineDiarizationConfirmPresented = true }
            } label: {
              Label("重新区分", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(theme.secondaryText)
            .fixedSize()
          }
          Spacer(minLength: 0)
        }
        .themedFont(.callout)
        if case let .failed(message) = state {
          HStack(spacing: 8) {
            Text(message).foregroundStyle(theme.danger)
            Button("知道了") { model.dismissSpeakerDiarizationFailure() }
              .buttonStyle(.plain)
              .foregroundStyle(theme.secondaryText)
          }
          .themedFont(.caption)
        }
      }
      .padding(.bottom, DesignTokens.Space.xs)
      .accessibilityIdentifier("history-speaker-bar")
    }
  }

  /// 「处理」面板里的区分说话人：有本机音视频、转写过、还没分过时出现。
  private var canOfferSpeakerDiarization: Bool {
    guard localMediaFileURL != nil, hasCompletedTranscript, !model.isReadOnly,
          model.speakerDiarizationState(for: detail.task.id) == .idle,
          let transcript = latestTranscriptionSnapshot ?? singlePaneTranscriptSnapshot else { return false }
    return SpeakerTranscript.speakers(in: transcript.bodyText).isEmpty
  }

  private func speakerModeButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(theme.accent.opacity(0.08), in: Capsule())
    }
    .buttonStyle(.plain)
    .help(help)
    .disabled(model.isReadOnly)
  }

  private func commitSpeakerRename() {
    guard let old = renamingSpeaker else { return }
    model.renameSpeaker(detail: detail, from: old, to: speakerNameDraft)
    renamingSpeaker = nil
  }

  private func isImportedImage(_ snapshot: ContentSnapshot) -> Bool {
    snapshot.captureMethod == "local_file_image"
  }

  /// 导入图片识别出的文字。图本身才是素材，文字是用来搜索、复制的附属信息，
  /// 默认收起成一行，不和图片抢版面。
  private func importedImageTextSection(_ text: String) -> some View {
    let lineCount = text.split(separator: "\n", omittingEmptySubsequences: true).count
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { isImportedImageTextExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .rotationEffect(.degrees(isImportedImageTextExpanded ? 90 : 0))
            Image(systemName: "text.viewfinder")
            Text("图片里的文字")
            Text("\(lineCount) 行").foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("imported-image-text-toggle")
        Spacer(minLength: 0)
        Button("复制文字") { CopyFeedbackController.shared.copy(text) }
          .buttonStyle(.plain)
          .foregroundStyle(theme.secondaryText)
      }
      .themedFont(.callout)
      .foregroundStyle(.secondary)
      if isImportedImageTextExpanded {
        Text(text)
          .themedFont(.callout)
          .foregroundStyle(theme.secondaryText)
          .lineSpacing(4)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("imported-image-text")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
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
      Text("换个模型重跑").themedFont(.headline)
      Text("直接使用本机保存的正文，不会重新抓取网页。这里选的模型只对这一次生效。")
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

  private func capturedErrorPageNotice(_ snapshot: ContentSnapshot) -> String? {
    guard let url = URL(string: snapshot.sourceURL) else { return nil }
    let head = String(snapshot.bodyText.prefix(2_000))
    if GitHubErrorPagePolicy.matches(url: url, extractedText: head) {
      return "这次存下来的是 GitHub 的报错页，不是文件内容。点右上角「更多 → 重新抓取原文」再抓一次。"
    }
    if VerificationPagePolicy.matches(url: url, extractedText: head) {
      return "这次存下来的是网站的验证页，不是正文。在浏览器里完成验证后，点「更多 → 重新抓取原文」。"
    }
    return nil
  }

  private func captureCompletenessNotice(_ completeness: String) -> String? {
    switch completeness.lowercased() {
    case "visible_only":
      return "仅保存当前页面可见内容，可能不是全文。"
    case "selection_only":
      return "仅保存所选内容。"
    default:
      return nil
    }
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

/// 当前页签的位置，给下划线用。
private struct ReadingTabBoundsKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
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
  @Bindable var model: HistoryViewModel
  /// 从工具栏快捷入口打开时直接展开输入框，点开即可打字；内联在详情里时保持收起。
  var autoExpandComposer = false
  /// 正文底部那一行已经有独立的「素材类型」下拉，这里不再重复一排按钮；标签弹窗里照旧显示。
  var showsMaterialTypes = true
  /// 详情页头里用弹出小窗装输入框：原来在原地展开，整页正文往下跳一截（2026-09-25 走查）。
  var composerInPopover = false
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

  private var hasChipTags: Bool {
    tags.contains { !MaterialCatalog.systemTagNormalizedNames.contains($0.normalizedName) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Chips-first: tags sit on the metadata density row, not a heavy form.
      // 系统标记（已使用、自有…）不是主题标签，不画成胶囊（2026-09-24）。
      let chipTags = tags.filter { !MaterialCatalog.systemTagNormalizedNames.contains($0.normalizedName) }
      if !chipTags.isEmpty {
        // 换行排而不是横向滚动：弹窗很窄，横排时第 4、5 个标签被截断或整个看不见（2026-09-24 走查）。
        TagPillFlowLayout(spacing: 6) {
            ForEach(chipTags.dropLast()) { tag in
              HistoryTagChip(tag: tag, canRemove: model.canEditTags) { model.removeTag(tag) }
            }
            // 「＋」和最后一个标签绑成一组换行：标签刚好排满一行时，「＋」原来
            // 孤零零掉到第二行开头（2026-10-01 走查）。
            if let last = chipTags.last {
              HStack(spacing: 6) {
                HistoryTagChip(tag: last, canRemove: model.canEditTags) { model.removeTag(last) }
                if canOpenComposer {
                  addTagControl
                }
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

      if isComposerExpanded && model.canEditTags && !composerInPopover {
        composer
      }

      if model.canEditTags, showsMaterialTypes {
        materialTypeRow
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

  /// 输入框 + 常用标签。原地展开或装进弹出小窗，两处共用。
  @ViewBuilder private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
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
      // 推荐按用得多少排、名字不截断：原来按字母排，空输入时只看到「Agent / Agent Fram…」
      // 这类半截名字，而不是自己常用的标签（2026-09-24 走查）。
      let suggestions = model.suggestedTags(matching: input, excluding: tags)
      if !suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(input.trimmingCharacters(in: .whitespaces).isEmpty ? "常用标签" : "已有标签")
            .themedFont(.caption).foregroundStyle(.secondary)
          TagPillFlowLayout(spacing: 6) {
            ForEach(suggestions.prefix(8)) { tag in
              // 做成可点的小胶囊：原来是一排链接样式的小字，看不出能点（2026-09-25 走查）。
              Button {
                input = tag.name
                add()
              } label: {
                Text(tag.name)
                  .themedFont(.caption)
                  .padding(.horizontal, 8).padding(.vertical, 3)
                  .background(.quaternary.opacity(0.6), in: Capsule())
              }
              .buttonStyle(.plain)
              .fixedSize()
              .accessibilityIdentifier("history-tag-suggestion-\(tag.normalizedName)")
            }
          }
        }
        .accessibilityIdentifier("history-tag-suggestions")
      }
    }
  }

  /// 一排素材类型：点一下贴上，再点一下摘掉。
  /// 预置名字就是普通标签，所以侧栏筛选、搜索、MCP 读到的都是同一回事。
  private var materialTypeRow: some View {
    let present = Set(tags.map(\.normalizedName))
    let entries = MaterialCatalog.MaterialType.allCases.map { ($0.tagName, $0.systemImage) }
    // 换行排列而不是横向滚动：标签弹窗很窄，横排时后几个类型被挤出可视区，
    // 用户根本不知道还有「数据」「选题」。
    return VStack(alignment: .leading, spacing: 4) {
      Text("素材类型").themedFont(.caption).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
        ForEach(entries, id: \.0) { name, symbol in
          let normalized = HistoryTagNormalizer.normalized(name)?.normalizedName ?? name
          let isOn = present.contains(normalized)
          Button {
            if isOn, let tag = tags.first(where: { $0.normalizedName == normalized }) {
              model.removeTag(tag)
            } else {
              model.addTag(name)
            }
          } label: {
            Label(name, systemImage: isOn ? "checkmark" : symbol)
              .labelStyle(.titleAndIcon)
              .themedFont(.caption)
              .lineLimit(1)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(isOn ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
          }
          .buttonStyle(.plain)
          .disabled(!isOn && tags.count >= HistoryTagNormalizer.maximumTagsPerTask)
          .help(isOn ? "取消「\(name)」" : "标为「\(name)」")
          .accessibilityIdentifier("history-material-\(name)")
        }
      }
    }
    .accessibilityIdentifier("history-material-types")
  }

  /// 输入框展开后就不再显示：旁边已有「取消」，原来「× 收起」和「取消」两个按钮做同一件事（2026-09-24 走查）。
  @ViewBuilder private var addTagControl: some View {
    if composerInPopover {
      Button { isComposerExpanded = true } label: {
        // 已经有标签时只留一个「＋」：四五个标签加上「添加标签」四个字放不下一行，
        // 这四个字常常单独掉到第二行（2026-10-01 走查）。没有标签时照旧写全，告诉人这里能加。
        if hasChipTags {
          Image(systemName: "plus")
            .font(.system(size: DesignTokens.IconSize.inline, weight: .semibold))
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        } else {
          Label("添加标签", systemImage: "tag")
            .themedFont(.callout)
            .labelStyle(.titleAndIcon)
        }
      }
      .buttonStyle(.borderless)
      .help("添加标签")
      .accessibilityLabel("添加标签")
      .accessibilityIdentifier("history-tag-add-toggle")
      .popover(isPresented: $isComposerExpanded, arrowEdge: .bottom) {
        composer
          .padding(DesignTokens.Space.lg)
          .frame(width: 300, alignment: .leading)
      }
    } else if !isComposerExpanded {
      Button {
        withAnimation(historyUIAnimation(reduceMotion: reduceMotion)) {
          isComposerExpanded = true
        }
      } label: {
        // 和上面「为这篇内容添加笔记」同一级：同样的字号、同样的强调色，
        // 原来一个大字带笔、一个小灰字带加号，看起来像两类东西。
        Label("添加标签", systemImage: "tag")
          .themedFont(.callout)
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier("history-tag-add-toggle")
    }
  }

  private func add() {
    guard canAdd else { return }
    model.addTag(input)
    input = ""
    isComposerExpanded = false
  }
}

/// 详情里的一个标签胶囊。× 只在鼠标移上去时出现：一排五个标签各带一个常亮的 ×，
/// 页头满是删除按钮，也容易误点（2026-09-25 走查）。键盘和旁白用户仍可从无障碍动作里删。
private struct HistoryTagChip: View {
  let tag: HistoryTag
  let canRemove: Bool
  let remove: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 4) {
      Text(tag.name).lineLimit(1)
      if canRemove {
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill").imageScale(.small)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .accessibilityLabel("移除标签 \(tag.name)")
      }
    }
    .themedFont(.caption)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(.quaternary, in: Capsule())
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: "移除标签") { if canRemove { remove() } }
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
    let suffix = disclosure.identity.isLocalEndpoint ? Text("（本机服务）").foregroundStyle(.secondary) : Text("")
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

/// 菜单命令句柄：返回上一层（⌘[ / Esc）。没有上一层时为 nil，菜单项灰掉。
struct GoBackAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct GoBackKey: FocusedValueKey { typealias Value = GoBackAction }

struct RunCurrentAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}
struct SummarizeCurrentKey: FocusedValueKey { typealias Value = RunCurrentAction }
struct SelectPreviousItemKey: FocusedValueKey { typealias Value = RunCurrentAction }
struct SelectNextItemKey: FocusedValueKey { typealias Value = RunCurrentAction }
struct TranslateCurrentKey: FocusedValueKey { typealias Value = RunCurrentAction }

extension FocusedValues {
  var summarizeCurrent: RunCurrentAction? {
    get { self[SummarizeCurrentKey.self] }
    set { self[SummarizeCurrentKey.self] = newValue }
  }
  var translateCurrent: RunCurrentAction? {
    get { self[TranslateCurrentKey.self] }
    set { self[TranslateCurrentKey.self] = newValue }
  }
  var selectPreviousItem: RunCurrentAction? {
    get { self[SelectPreviousItemKey.self] }
    set { self[SelectPreviousItemKey.self] = newValue }
  }
  var selectNextItem: RunCurrentAction? {
    get { self[SelectNextItemKey.self] }
    set { self[SelectNextItemKey.self] = newValue }
  }
}

extension FocusedValues {
  var goBack: GoBackAction? {
    get { self[GoBackKey.self] }
    set { self[GoBackKey.self] = newValue }
  }
}

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

/// 正文宽度偏好：标准（有可读上限）/ 加宽（铺满可用宽度）。
enum ReadingLayoutWidth {
  static let storageKey = "com.syc.linkdigest.reading-wide-layout"
}

/// 菜单图标（2026-09-25）：顶栏「更多」、正文「处理」、列表右键三个菜单里，同一个动作用同一个图标，
/// 每一项都带图标——原来一半有、一半只有字，同一件事（总结）在两个菜单里还是两种图。
enum MenuIcon {
  static let comments = "text.bubble"
  static let summarize = "text.badge.checkmark"
  static let translate = "character.book.closed"
  static let transcribe = "waveform"
  static let transcribeOnline = "network"
  static let mindMap = "brain"
  static let tidy = "text.redaction"
  static let reformat = "text.alignleft"
  static let rerun = "arrow.triangle.2.circlepath"
  static let settings = "gearshape"
  static let model = "cpu"
  static let runDetails = "info.circle"
  static let copy = "doc.on.doc"
  static let export = "square.and.arrow.up"
  static let recapture = "arrow.clockwise"
  static let trash = "trash"
}

/// 「自有 / 外部」在侧栏、详情页头、右键菜单里用同一对图标（2026-09-25）：
/// 「外部」是收进来的，和「全部」的收纳盒同一个画法；「自有」是一个人，和「博主」的两个人同一套。
enum OwnershipIcon {
  static let own = "person"
  static let external = "tray.and.arrow.down"
}

/// 菜单命令句柄：收藏 / 取消收藏当前条目（⌘D，与 Tolaria 一致）。
struct ToggleFavoriteAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct ToggleFavoriteKey: FocusedValueKey { typealias Value = ToggleFavoriteAction }

/// 菜单命令句柄：新建合集（文件菜单）。侧栏的「＋」挂在分组标题里，辅助功能会把它并进标题，
/// 读屏和自动化按不到；菜单项给它们一个能直接按的入口。
struct NewCollectionAction: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
  let run: () -> Void
}

struct NewCollectionKey: FocusedValueKey { typealias Value = NewCollectionAction }

extension FocusedValues {
  var newNote: NewNoteAction? {
    get { self[NewNoteKey.self] }
    set { self[NewNoteKey.self] = newValue }
  }
  var todayNote: TodayNoteAction? {
    get { self[TodayNoteKey.self] }
    set { self[TodayNoteKey.self] = newValue }
  }
  var toggleFavorite: ToggleFavoriteAction? {
    get { self[ToggleFavoriteKey.self] }
    set { self[ToggleFavoriteKey.self] = newValue }
  }
  var newCollection: NewCollectionAction? {
    get { self[NewCollectionKey.self] }
    set { self[NewCollectionKey.self] = newValue }
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
/// 模型本身用不了（下架、仅限官方客户端、需充值、密钥无效…）导致的失败：给一个直达设置的出口。
/// 暂时不可用、网络中断这类稍后重试就好的，不给这个按钮。
struct ModelFailureFix: Equatable {
  let status: ModelHealthStatus

  init?(runState: RunState) {
    let code: String
    switch runState {
    case let .failed(_, failureCode): code = failureCode
    case let .incomplete(_, _, failureCode): code = failureCode
    default: return nil
    }
    guard let providerCode = ModelProviderErrorCode(rawValue: code),
          let status = ModelHealthStatus(failure: providerCode),
          status != .temporarilyUnavailable, status != .available
    else { return nil }
    self.status = status
  }

  var buttonTitle: String {
    switch status {
    case .keyInvalid: "去更换密钥"
    case .billingLimited: "去设置换模型或查看额度"
    default: "去「模型服务」换一个模型"
    }
  }
}

private struct LiveRunReadingBody: View {
  @ObservedObject var live: LiveRunTextModel
  let statusText: String
  let isActive: Bool
  let startedAt: Date?
  let hasFailure: Bool
  var modelFixAction: (title: String, action: () -> Void)? = nil
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
          // 这一屏是整个生成过程里最长的一段静止画面：思考阶段还没有正文可长，
          // 转圈之外没有任何东西在动。读数放在这里最要紧。
          if isActive, let startedAt {
            RunElapsedLabel(startedAt: startedAt)
              .themedFont(.body, monospacedDigit: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        if hasFailure, let modelFixAction {
          Button(modelFixAction.title, action: modelFixAction.action)
            .controlSize(.regular)
            .accessibilityIdentifier("run-failure-fix-model")
        }
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

/// 翻译进行中的叶子视图：观察流式正文，但只把「已写完的行」交给内容。
///
/// 流式每 250ms 一个拍点，多数拍点只是当前这行长了几个字；逐字稿整页重排一次要遍历
/// 几万字。闸门按「已写完的行 + 外层状态」判等，没变就整块跳过。
private struct LiveCompletedTextObserver<Empty: View, Content: View>: View {
  @ObservedObject var live: LiveRunTextModel
  let key: String
  @ViewBuilder let empty: () -> Empty
  @ViewBuilder let content: (String) -> Content

  var body: some View {
    let completed = LiveTranslationPreview.completedText(of: live.text)
    if completed.isEmpty {
      empty()
    } else {
      LiveCompletedTextGate(completed: completed, key: key, content: content).equatable()
    }
  }
}

private struct LiveCompletedTextGate<Content: View>: View, Equatable {
  let completed: String
  let key: String
  let content: (String) -> Content

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.key == rhs.key && lhs.completed == rhs.completed
  }

  var body: some View { content(completed) }
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

/// 阅读区「更多」里的「上一条 / 下一条」。
///
/// 单独成一个视图：能不能往前后翻要在列表 `rows` 里找当前条目的位置，这个读取
/// 若写在详情页 body 里，详情页就订阅了整张列表——列表往下滚一次加载下一页，
/// 整个详情页（长文要排版九万字）跟着重算一遍，正是 2026-09-24 实测列表滚动里
/// 几百毫秒卡顿的来源之一。放在这里，列表变化只重算这两个按钮。
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

/// 保留平台已有单位；纯数字使用中文紧凑计数，完整值仍由视图 help 提供。
/// 作者的显示名。X 存的是「显示名 (@账号)」；不少账号显示名就是账号名，
/// 「ClaudeDevs (@ClaudeDevs)」同一个词写两遍，只留「@ClaudeDevs」（2026-10-03 走查）。
enum HistoryAuthorDisplay {
  static func text(_ author: String) -> String {
    guard let match = author.wholeMatch(of: /^(.+?)\s*\(@([^()\s]+)\)$/) else { return author }
    let name = String(match.1).trimmingCharacters(in: .whitespaces)
    let handle = String(match.2)
    guard name.caseInsensitiveCompare(handle) == .orderedSame
      || name.caseInsensitiveCompare("@" + handle) == .orderedSame else { return author }
    return "@" + handle
  }
}

enum HistoryEngagementCount {
  static func compact(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let numeric = trimmed.replacingOccurrences(of: ",", with: "")
    guard !numeric.isEmpty, numeric.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          let count = Double(numeric), count.isFinite, count >= 10_000 else { return trimmed }
    let divisor = count >= 100_000_000 ? 100_000_000.0 : 10_000.0
    let number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), count / divisor)
    return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + (divisor == 10_000 ? "万" : "亿")
  }
}


/// 搜索框自己持有草稿：每个按键只重排这个小视图，不再让整个主界面跟着重排。
/// 模型侧的 200ms 查库防抖保留；模型里的值被外部改掉（清空筛选）时回灌到草稿。
struct DebouncedSearchField: View {
  let placeholder: String
  let committed: String
  let onChange: (String) -> Void
  @State private var draft = ""

  var body: some View {
    TextField(placeholder, text: $draft)
      .textFieldStyle(.plain)
      .onAppear { draft = committed }
      .onChange(of: draft) { _, value in
        if value != committed { onChange(value) }
      }
      .onChange(of: committed) { _, value in
        if value != draft { draft = value }
      }
  }
}

/// 详情页派生值备忘。键 = 用途 + 快照 id + 正文字节数；换条目自然失效，
/// 同一条目上界面其它状态变化时直接命中。
///
/// 同一次 body 里会先后用到两份快照（原文快照和最新快照——带转写、字幕的条目
/// 两者不同）。原来只记一份快照的结果，换一份就整个清空，两边轮流把对方清掉，
/// 这类条目每次重绘都从头扫全文，备忘一次都命不中。现在按快照分别保存，
/// 只保留最近用到的几份。
final class DetailDerivedMemo {
  private var entries: [String: Any] = [:]
  private var recentSnapshotKeys: [String] = []
  static let snapshotCapacity = 4

  func value<T>(_ purpose: String, snapshot: ContentSnapshot?, compute: () -> T) -> T {
    let snapshotKey = "\(snapshot?.id.rawValue ?? "-")|\(snapshot?.bodyText.utf8.count ?? 0)"
    let key = "\(snapshotKey)|\(purpose)"
    if let cached = entries[key] as? T { return cached }
    if !recentSnapshotKeys.contains(snapshotKey) {
      recentSnapshotKeys.append(snapshotKey)
      if recentSnapshotKeys.count > Self.snapshotCapacity {
        let evicted = recentSnapshotKeys.removeFirst() + "|"
        entries = entries.filter { !$0.key.hasPrefix(evicted) }
      }
    }
    let value = compute()
    entries[key] = value
    return value
  }
}

/// 只对某一条内容有效的界面状态。换了一条就当作「没设过」，读的地方回落到默认值。
struct PerItem<Value> {
  let taskID: TaskID
  let value: Value
  func value(for current: TaskID) -> Value? { taskID == current ? value : nil }
}

/// 落款上下文的备忘：详情（含运行记录）和脑图都没变，就不重算。
final class ColophonContextMemo {
  private var key: (HistoryDetailProjection, TaskMindMapRecord?)?
  private var cached: ReadingDocumentExport.ExportColophonContext?

  func value(detail: HistoryDetailProjection, mindMap: TaskMindMapRecord?) -> ReadingDocumentExport.ExportColophonContext {
    if let key, let cached, key.0 == detail, key.1 == mindMap { return cached }
    let context = ReadingDocumentExport.ExportColophonContext(detail: detail, mindMap: mindMap)
    key = (detail, mindMap)
    cached = context
    return context
  }
}

/// 把菜单内容推迟到真正显示时再求值。
///
/// `.contextMenu { … }` 和 `Menu { … }` 的内容闭包在挂修饰符那一刻就会执行：列表
/// 每一行、每次重绘都把整份右键菜单（标签归一化、查稿件、判断能不能总结）算一遍，
/// 哪怕从来没人右键。2026-09-24 列表滚动采样里它就在主线程热点上。包进一个视图后，
/// 闭包只在这个视图的 body 被求值——也就是菜单弹出时——才执行。
struct DeferredMenuContent<Content: View>: View {
  let build: () -> Content

  init(@ViewBuilder _ build: @escaping () -> Content) {
    self.build = build
  }

  var body: some View { build() }
}

struct HistoryListSectionModel: Identifiable {
  let title: String?
  let entries: [(index: Int, row: HistoryRowProjection)]
  var id: String { title ?? "all" }
}

/// 「改为自有 / 改为外部」：列表右键与阅读区「更多」共用。
private struct OwnershipToggleButton: View {
  @Bindable var model: HistoryViewModel
  let taskID: TaskID
  let canonicalURL: String
  let host: String
  let tagNames: [String]

  var body: some View {
    let current = ContentOwnership.resolve(canonicalURL: canonicalURL, host: host, tagNames: tagNames)
    let target: ContentOwnership = current == .own ? .external : .own
    Button {
      model.setOwnership(target, taskID: taskID, canonicalURL: canonicalURL, host: host)
    } label: {
      Label("改为\(target.rawValue)", systemImage: target == .own ? OwnershipIcon.own : OwnershipIcon.external)
    }
    .disabled(model.isReadOnly || model.isDeleting)
    .help("现在算「\(current.rawValue)」")
    .accessibilityIdentifier("history-context-ownership")
  }
}

/// 竖直方向按框裁、水平方向向两边多留 `bleed` 的裁剪形状。
struct HorizontalBleedClip: Shape {
  let bleed: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(rect.insetBy(dx: -bleed, dy: 0))
  }
}

/// 三步卡「看个示例」打开的只读示例（2026-10-01 走查：新用户打开空库只看得到空壳，
/// 不知道保存之后会得到什么）。原文、总结都内置在这里，用阅读页同一个
/// `MarkdownContentView` 渲染；不建任务、不写资料库，关掉就没了。
struct SampleReadingPreviewSheet: View {
  enum Layer: String, CaseIterable, Identifiable {
    case summary = "总结"
    case source = "原文"
    var id: String { rawValue }
  }

  let theme: HistoryThemeTokens
  @State private var layer: Layer = .summary
  @State private var showsPlainText = false
  @Environment(\.dismiss) private var dismiss

  static let sampleTitle = "为什么写下来的东西更容易记住"

  static let sampleSource = """
  很多人读完一篇文章，过两天就只剩一个模糊的印象。不是记性不好，而是读的时候只做了「输入」。

  ## 输入和提取

  记忆研究里有个反复被验证的结论：主动回想比反复阅读更能留住东西。读完合上书，试着用自己的话说一遍，哪怕说得磕磕绊绊，留下来的也比再读一遍多。

  ## 写下来为什么有用

  写作逼着人把模糊的感觉变成具体的句子。写不出来的地方，往往就是没真正懂的地方。

  - 用自己的话复述一遍要点；
  - 记下一个能用上的场景；
  - 过几天再翻出来看一眼。

  > 读过的东西，要经过自己的手，才算真正收进来。
  """

  static let sampleSummary = """
  **一句话**：主动回想和动笔复述，比反复阅读更能记住读过的东西。

  ## 要点

  1. 只读不想只是「输入」，几天后多半只剩模糊印象。
  2. 主动回想（合上书用自己的话说一遍）比再读一遍更有效。
  3. 写作能暴露没弄懂的地方：写不出来的，往往就是没懂的。

  ## 可以怎么做

  - 读完用两三句话复述要点；
  - 记下一个自己能用上的场景；
  - 隔几天回看一次。
  """

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
        VStack(alignment: .leading, spacing: 3) {
          Text("示例").themedFont(.caption, weight: .semibold).foregroundStyle(theme.secondaryText)
          Text(Self.sampleTitle).themedFont(.title3, weight: .semibold)
        }
        Spacer(minLength: 0)
        Picker("查看", selection: $layer) {
          ForEach(Layer.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("sample-preview-layer")
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 12)
      Divider()
      ScrollView {
        MarkdownContentView(
          source: layer == .summary ? Self.sampleSummary : Self.sampleSource,
          primaryTextColor: theme.primaryText,
          secondaryTextColor: theme.secondaryText,
          accentColor: theme.accent,
          showsPlainText: $showsPlainText,
          showsInlinePlainTextToggle: false,
          anchorScope: "sample-preview"
        )
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack {
        Text("这只是示例，不会存进资料库。保存自己的链接后，原文、总结会以同样的样子出现在右侧。")
          .themedFont(.caption)
          .foregroundStyle(theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: DesignTokens.Space.sm)
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("sample-preview-close")
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }
    .frame(width: 620, height: 600)
    .background(theme.card)
    .foregroundStyle(theme.primaryText)
    .environment(\.appTheme, theme)
    .accessibilityIdentifier("sample-preview-sheet")
  }
}

extension View {
  /// 把一段修饰符交给函数处理，用来拆开过长的修饰符链（编译器类型推断会超时）。
  func apply<Transformed: View>(@ViewBuilder _ transform: (Self) -> Transformed) -> Transformed {
    transform(self)
  }
}

/// 卡片墙、博主页的工具栏是整窗一条，返回键紧跟在侧栏开关后面，落在左栏上方；
/// 「返回全部博主」这种长一点的字，左栏和内容的分隔线正好从按钮中间穿过（2026-10-01 走查）。
/// 在按钮前垫一段空白，让它从内容区左缘起排——和三栏里列头标题同一条线。
private struct ToolbarContentEdgeAlignment: ViewModifier {
  let sidebarWidth: CGFloat
  @State private var originX: CGFloat = 0

  func body(content: Content) -> some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: max(0, sidebarWidth + DesignTokens.Layout.columnInset - originX), height: 1)
      content
    }
    // 工具栏项各自挂在单独的宿主视图里，SwiftUI 的 .global 量出来不是窗口坐标；
    // 用 AppKit 直接量这段在窗口里的横坐标。
    .background(WindowOriginXReader { originX = $0 })
  }
}

private struct WindowOriginXReader: NSViewRepresentable {
  let onChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
    view.report()
  }

  final class ReaderView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var last: CGFloat = .nan
    private var beforeLast: CGFloat = .nan

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
    override func layout() { super.layout(); report() }

    /// 量到的位置会反过来改垫片宽度、垫片又挪动按钮：工具栏重排后位置差零点几个点，
    /// 两边来回追，卡片墙静止时主线程一直在重排，CPU 40%（2026-10-04 走查）。
    /// 取整到整点、不到 1 点的变化不报、在两个值之间来回跳时停下。
    func report() {
      guard window != nil else { return }
      let x = convert(bounds, to: nil).minX.rounded()
      if !last.isNaN, abs(x - last) < 1 { return }
      if x == beforeLast { return }
      beforeLast = last
      last = x
      DispatchQueue.main.async { [weak self] in self?.onChange?(x) }
    }
  }
}

/// 详情还没内容时（载入中、出错）工具栏里留灰着的「收藏」「更多」，布局和有内容时一致。
private struct PlaceholderDetailToolbar: ViewModifier {
  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {} label: { Label("收藏", systemImage: "star") }.disabled(true)
        Button {} label: { Label("更多", systemImage: "ellipsis") }.disabled(true)
      }
    }
  }
}
