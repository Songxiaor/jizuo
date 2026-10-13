import XCTest

/// D 轮（2026-10-13 走查 #20 #21 #22 #3 #8 #4 #23）：工具栏和提示条的一致性。
/// 和这个目录里别的界面测试一样按源码断言：这些是「摆法」问题，改回去时第一时间报出来。
final class ToolbarAndNoticeConsistencyTests: XCTestCase {
  private func appSource(_ fileName: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/LinkDigestApp/\(fileName)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      XCTFail("读不到 \(fileName)")
      return ""
    }
    return text
  }

  private func section(in source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start) else {
      XCTFail("找不到起始标记「\(start)」，源码结构已变，这条断言需要同步更新。")
      return ""
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
      return String(source[startRange.lowerBound...])
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }

  /// #20：胶囊里五个位置固定，不适用的置灰、不消失。
  func testDetailCapsuleKeepsFiveFixedSlotsAndDisablesInsteadOfHiding() {
    let source = appSource("HistoryContentView.swift")
    let capsule = section(in: source, from: "@ViewBuilder private var detailActionsCapsule", to: "/// 胶囊最右的「…」")
    XCTAssertFalse(capsule.contains("if showsFavorite"), "收藏不能因条目类型消失")
    XCTAssertFalse(capsule.contains("if isWeb {"), "来源按钮不能因条目类型消失")
    XCTAssertFalse(capsule.contains("if let mediaFile {\n        Button"), "访达按钮不能因没有媒体文件消失")
    for id in ["reading-toggle-favorite", "history-source-url-open", "history-source-url-copy", "history-reveal-media-file"] {
      XCTAssertTrue(capsule.contains(id), id)
    }
    XCTAssertTrue(capsule.contains(".disabled(!model.canToggleFavorite)"))
    XCTAssertTrue(capsule.contains(".disabled(!isWeb)"))
    XCTAssertTrue(capsule.contains(".disabled(mediaFile == nil)"))
    let order = ["reading-toggle-favorite", "history-source-url-open", "history-source-url-copy",
                 "history-reveal-media-file", "moreActionsMenu"]
      .compactMap { capsule.range(of: $0)?.lowerBound }
    XCTAssertEqual(order.count, 5)
    XCTAssertEqual(order, order.sorted(), "顺序固定：收藏 → 打开原文 → 复制链接 → 访达 → 更多")
    let placeholder = section(in: source, from: "private struct PlaceholderDetailToolbar", to: "\n}\n")
    XCTAssertTrue(placeholder.contains("\"star\", \"safari\", \"link\", \"folder\", \"ellipsis\""), "占位胶囊和有内容时同样五个位置")
  }

  /// #21：列表工具栏固定三个（搜索、卡片视图、添加），全部博主页顶栏也有添加入口。
  func testListToolbarHasSameIconsOnEveryPage() {
    let source = appSource("HistoryContentView.swift")
    let toolbar = section(in: source, from: "@ToolbarContentBuilder private var listColumnToolbar", to: "private var sidebar: some View")
    XCTAssertFalse(toolbar.contains("history-notes-create-toolbar"), "笔记页不再多一个新建笔记图标")
    XCTAssertFalse(toolbar.contains("if !model.selectedHosts.isEmpty {"), "卡片视图不能按页面出现或消失")
    XCTAssertTrue(toolbar.contains(".disabled(model.selectedHosts.isEmpty)"), "没有来源可看时置灰")
    let search = toolbar.range(of: "history-search-toggle")?.lowerBound
    let gallery = toolbar.range(of: "history-platform-gallery-open")?.lowerBound
    let add = toolbar.range(of: "      addMenu")?.lowerBound
    XCTAssertTrue(search != nil && gallery != nil && add != nil && search! < gallery! && gallery! < add!)
    let fullWidth = section(in: source, from: "@ToolbarContentBuilder private var fullWidthSurfaceToolbar", to: "@ToolbarContentBuilder private var listColumnToolbar")
    XCTAssertTrue(fullWidth.contains("if usesFullWidthSurface {") && fullWidth.contains("addMenu"),
                  "全部博主页和博主作品页、卡片墙一样，顶栏右上角要有添加入口")
    XCTAssertTrue(source.contains(".toolbar { fullWidthSurfaceToolbar }"), "挂在详情列上，不挂在窗口顶层")
  }

  /// #22 #3 #8：三个提示条同一个组件；按钮不缩不截；清空是红色并二次确认；30 天只在列表顶写一处。
  func testNoticeBannersShareOneComponent() {
    let source = appSource("HistoryContentView.swift")
    let component = appSource("AppComponents.swift")
    let banner = section(in: component, from: "struct NoticeBanner: View", to: "\n}\n")
    XCTAssertTrue(banner.contains(".fixedSize()"), "按钮文字不截断")
    XCTAssertTrue(banner.contains(".appDestructive(theme.danger)"))
    for id in ["untranscribed-bulk-banner", "unsummarized-auto-summary-banner", "history-trash-banner", "history-trash-detail-banner"] {
      XCTAssertTrue(source.contains("identifier: \"\(id)\""), "\(id) 要走 NoticeBanner")
      XCTAssertFalse(source.contains(".accessibilityIdentifier(\"\(id)\")"), "\(id) 不能再自己画一份")
    }
    let trashList = section(in: source, from: "icon: \"trash\",\n          title: \"回收站里的内容", to: "isEmptyTrashConfirmPresented = true")
    XCTAssertTrue(trashList.contains("actionStyle: .destructive"), "清空用红色")
    XCTAssertTrue(source.contains(".alert(\"清空回收站？\", isPresented: $isEmptyTrashConfirmPresented)"), "清空要二次确认")
    let trashDetail = section(in: source, from: "title: \"这条在回收站里\"", to: "restoreFromTrash")
    XCTAssertFalse(trashDetail.contains("retentionDays"), "30 天后自动删除只在列表顶那条写一处")
  }

  /// #4：筛选条放不下就换行，「清除」固定宽度不被挤出去；开头说清是按域名筛选。
  func testFilterBarWrapsAndExplainsDomainFilter() {
    let source = appSource("HistoryContentView.swift")
    let bar = section(in: source, from: "@ViewBuilder private var activeFilterFlow", to: "private var activeFilterTags")
    XCTAssertTrue(bar.contains("TagPillFlowLayout"))
    XCTAssertFalse(bar.contains("ScrollView(.horizontal"), "不再横向滚动")
    XCTAssertTrue(bar.contains("按域名筛选"))
    XCTAssertTrue(bar.contains("Button(\"清除\")"))
    XCTAssertTrue(bar.contains(".frame(height: 92)"), "筛选片很多时限高、条内滚动")
    XCTAssertTrue(bar.contains(".fixedSize()\n          .padding(.top, 2)\n          .help(\"清除当前搜索和筛选\")"))
  }

  /// #23：没有滚动条的短页面补上滚动条的宽度，和有滚动条的长页面正文同宽。
  func testShortPagesReserveScrollerWidth() {
    let scroller = appSource("SubtleScroller.swift")
    XCTAssertTrue(scroller.contains("onOverflowChange"))
    XCTAssertTrue(scroller.contains("frameDidChangeNotification"))
    let history = appSource("HistoryContentView.swift")
    XCTAssertTrue(history.contains(".padding(.trailing, readingContentOverflows ? 0 : readingScrollerTrackWidth)"))
    XCTAssertTrue(history.contains(".subtleScrollers { overflows, trackWidth in"))
  }
}
