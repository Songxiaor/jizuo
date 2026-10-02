import AppKit
import LinkDigestCore
import SwiftUI
import UniformTypeIdentifiers

/// 脑图区：位于媒体卡与原文之间。展示、主题切换、节点文本编辑与导出都在
/// 本地完成；只有「生成/重新生成」会把文字发给已配置的模型，且必经确认。
struct MindMapSectionView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  let taskID: TaskID
  @Bindable var model: HistoryViewModel

  @State private var isEditorPresented = false
  @State private var svgExport: MindMapExportFile?
  @State private var htmlExport: MindMapExportFile?

  var body: some View {
    Group {
      if let record = model.mindMapRecord, record.taskID == taskID {
        mapCard(record)
      } else if model.canGenerateMindMap(taskID: taskID) || model.mindMapState(for: taskID).isActive {
        // 生成中也要留着这一行。`canGenerateMindMap` 在运行期间是 false，
        // 只按它判断的话，点完「生成脑图」这一块就整个消失，看不到「正在生成…」，
        // 也看不到失败原因。
        generatePrompt
      }
    }
    .alert("将正文发送给聊天模型生成脑图？", isPresented: $model.isMindMapConfirmationPresented) {
      Button("取消", role: .cancel) { model.cancelMindMapConfirmation() }
      Button("同意并生成") { model.confirmMindMapGeneration() }
    } message: {
      Text("App 只发送文字内容（优先总结，其次正文）用于提取脑图结构，不发送视频、音频或链接。生成后可本地编辑、换主题和导出，不再消耗 token。")
    }
    .sheet(isPresented: $isEditorPresented) {
      if let record = model.mindMapRecord {
        MindMapOutlineEditor(outline: record.outline) { edited in
          model.updateMindMapOutline(taskID: taskID, outline: edited)
        }
      }
    }
    .fileExporter(
      isPresented: Binding(get: { svgExport != nil }, set: { if !$0 { svgExport = nil } }),
      document: svgExport,
      contentType: .svg,
      defaultFilename: exportBaseName + ".svg"
    ) { _ in svgExport = nil }
    .fileExporter(
      isPresented: Binding(get: { htmlExport != nil }, set: { if !$0 { htmlExport = nil } }),
      document: htmlExport,
      contentType: .html,
      defaultFilename: exportBaseName + "-脑图与原文.html"
    ) { _ in htmlExport = nil }
  }

  private var exportBaseName: String {
    let title = model.mindMapRecord?.outline.title ?? "\(ProductDisplay.name)脑图"
    return title.replacingOccurrences(of: "/", with: "-")
  }

  /// 大纲 → 纯文本清单：中心主题、分支为标题、要点为缩进条目。
  static func outlinePlainText(_ outline: MindMapOutline) -> String {
    var lines: [String] = [outline.title]
    if let subtitle = outline.subtitle { lines.append(subtitle) }
    for branch in outline.branches {
      lines.append("")
      lines.append("■ \(branch.title)")
      lines.append(contentsOf: branch.leaves.map { "  · \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  /// 还没有脑图时，这里只剩状态（正在生成／失败原因），没有按钮。
  ///
  /// 「生成脑图」挪去了详情页顶部那排动作里，和总结、翻译并列——三者是同一类事：
  /// 把正文交给模型换回一份新产物，前置条件、花费和确认流程都一样。原来它单独
  /// 待在媒体和正文之间，是一行很容易滚过去的小按钮。
  ///
  /// 状态留在原地不动：它说的是「这一块正在长出来」，就该在这一块的位置上。
  @ViewBuilder private var generatePrompt: some View {
    HStack(spacing: 10) {
      stateText
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private func themePicker(_ record: TaskMindMapRecord) -> some View {
    Picker("主题", selection: Binding(
      get: { record.themeID },
      set: { model.updateMindMapTheme(taskID: taskID, themeID: $0) }
    )) {
      ForEach(MindMapTheme.all, id: \.id) { theme in
        Text(theme.displayName).tag(theme.id)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 200)
    .labelsHidden()
    // 只读时拨了也不会落库，让它可拨等于无声丢弃。ViewModel 那边有兜底闸，
    // 这里灰掉是为了让「改不了」看得见。
    .disabled(model.isReadOnly)
    .accessibilityLabel("脑图主题")
  }

  @ViewBuilder private func mapActions() -> some View {
    Button("重新生成") { model.requestMindMapGeneration(taskID: taskID) }
      .controlSize(.small)
      .disabled(model.mindMapUnavailableReason(taskID: taskID) != nil)
      .help(model.mindMapUnavailableReason(taskID: taskID) ?? "重新把文字发送给模型提取脑图结构；会覆盖当前脑图（含手动编辑）。")
      .accessibilityLabel("重新生成脑图")
      .accessibilityIdentifier("mind-map-regenerate")
    if let reason = model.mindMapUnavailableReason(taskID: taskID) {
      Text(reason)
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("mind-map-blocked-reason")
    }
    Button("编辑") { isEditorPresented = true }
      .controlSize(.small)
      .fixedSize()
      .disabled(model.isReadOnly)
      .help(model.isReadOnly ? "这份历史当前只能浏览" : "编辑脑图结构")
      .accessibilityLabel("编辑脑图")
      .accessibilityIdentifier("mind-map-edit")
    Menu {
      Button("导出脑图 SVG") {
        if let svg = model.mindMapSVG() {
          svgExport = MindMapExportFile(text: svg)
        }
      }
      Button("导出脑图 + 原文 (HTML)") {
        if let html = model.mindMapCombinedExportHTML() {
          htmlExport = MindMapExportFile(text: html)
        }
      }
    } label: {
      Label("导出", systemImage: "square.and.arrow.up")
    }
    .controlSize(.small)
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("导出脑图")
    .accessibilityLabel("导出脑图")
    .accessibilityIdentifier("mind-map-export")
  }

  @ViewBuilder private func mapCard(_ record: TaskMindMapRecord) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // 窄窗口（笔记本分屏 ~900pt）一行放不下时，按钮整排折到标题下面，
      // 不再把「脑图」挤成竖排两行（2026-09-29 发布前走查）。
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          Text("脑图").themedFont(.headline).fixedSize()
          if record.userEdited {
            Text("已编辑").themedFont(.caption2).foregroundStyle(.secondary).fixedSize()
          }
          Spacer(minLength: 0)
          themePicker(record)
          mapActions()
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            Text("脑图").themedFont(.headline).fixedSize()
            if record.userEdited {
              Text("已编辑").themedFont(.caption2).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            themePicker(record)
          }
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            mapActions()
          }
        }
      }
      if let svg = Self.renderedSVG(record) {
        MindMapCanvasView(
          svg: svg,
          taskID: taskID,
          themeID: record.themeID,
          outlineText: Self.outlinePlainText(record.outline)
        )
      }
      // 用量是给排障看的，不常驻：原来卡底一直挂着「993 tokens（输入 576 / 输出 417）」，
      // 读者看不懂也用不上（2026-09-29 发布前走查）。挪到卡片的悬停说明里。
      HStack(spacing: 12) {
        stateText
        Spacer(minLength: 0)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
    )
    .help(model.mindMapTokenSummary.map { "生成用量：\($0)" } ?? "")
    .accessibilityIdentifier("mind-map-card")
  }

  /// 同一份大纲、同一个主题只渲染一次 SVG。
  ///
  /// 原来每次重画都调 `model.mindMapSVG()`（2026-10-01 体检）：排版 + 拼几十 KB 的
  /// SVG 字符串，而详情页的悬停、滚动、进度刷新都会让这里重画；新字符串又会让下面
  /// 画布的 `.task(id: svg)` 判等一遍全文。按大纲 + 主题记住结果，改了大纲或换了
  /// 主题键就变，自然重渲。
  private static let svgMemo = ContentMemo<SVGKey, String>(capacity: 4)

  private struct SVGKey: Equatable {
    let outline: MindMapOutline
    let themeID: String
  }

  static func renderedSVG(_ record: TaskMindMapRecord) -> String? {
    let key = SVGKey(outline: record.outline, themeID: record.themeID)
    if let hit = svgMemo.value(for: key) { return hit }
    let svg = MindMapSVGRenderer.render(outline: record.outline, theme: MindMapTheme.named(record.themeID))
    svgMemo.store(svg, for: key)
    return svg
  }

  /// SVG 根节点上的 height="…"。渲染器总会写；读不到就交回默认占位。
  static func declaredHeight(of svg: String) -> CGFloat? {
    guard let open = svg.range(of: "<svg"),
          let close = svg[open.upperBound...].firstIndex(of: ">") else { return nil }
    let header = svg[open.upperBound..<close]
    guard let attribute = header.range(of: #"\sheight="([0-9.]+)""#, options: .regularExpression) else { return nil }
    let digits = header[attribute].drop { $0 != "\"" }.dropFirst().prefix { $0 != "\"" }
    return Double(digits).map { CGFloat($0) }
  }

  @ViewBuilder private var stateText: some View {
    switch model.mindMapState(for: taskID) {
    case .idle: EmptyView()
    case .running:
      ProgressView().controlSize(.small)
      // 已等秒数 + 停止：最长要等三分钟，原来只有一句「生成中…」也停不下来（2026-10-01）。
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let waited = Int(context.date.timeIntervalSince(model.mindMapStartedAt ?? context.date))
        Text(waited >= 3 ? "正在生成脑图… 已等 \(waited) 秒" : "正在生成脑图…")
          .themedFont(.caption)
          .monospacedDigit()
      }
      Button("停止") { model.cancelMindMapGeneration() }
        .buttonStyle(.plain)
        .themedFont(.caption)
        .foregroundStyle(appTheme.accent)
        .accessibilityIdentifier("mind-map-cancel")
    case .completed:
      Label("脑图已保存", systemImage: "checkmark.circle.fill")
        .themedFont(.caption).foregroundStyle(appTheme.success)
    case .cancelled: EmptyView()
    case let .failed(message):
      Text(message).themedFont(.caption).foregroundStyle(appTheme.danger).lineLimit(2)
    }
  }

}

/// 卡内脑图视口：固定高度、带边框，宽度撑满卡片；图先按视口宽等比缩放，
/// 超出部分滚轮/触控板双轴滚动；单击栅格化为 2x PNG 进现有图片灯箱放大。
private struct MindMapCanvasView: View {
  let svg: String
  let taskID: TaskID
  let themeID: String
  /// 大纲的纯文本形态；灯箱「识别文字」直接用它，不 OCR。
  let outlineText: String
  @State private var image: NSImage?

  private static let viewportHeight: CGFloat = 380

  var body: some View {
    GeometryReader { proxy in
      Group {
        if let image, image.size.width > 0 {
          let scale = min(1, proxy.size.width / image.size.width)
          let displaySize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
          )
          ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .frame(width: displaySize.width, height: displaySize.height)
          }
          .onTapGesture { presentLightbox() }
          .help("点击放大查看")
          .accessibilityLabel("脑图")
          .accessibilityValue(outlineText)
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("点击放大查看")
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    // 高度直接按 SVG 自己声明的尺寸定，不等解码：原来先占 200pt、图到了再跳成
    // 实际高度，下面整篇正文跟着往下一蹦（2026-10-01 体检）。
    .frame(height: min(Self.viewportHeight, max(160, (image?.size.height ?? MindMapSectionView.declaredHeight(of: svg)) ?? 200)))
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .accessibilityIdentifier("mind-map-canvas")
    .task(id: svg) {
      // SVG 解析放到后台（2026-10-01 体检）：NSImage(data:) 对 SVG 是同步解析整份
      // 文档，大脑图在主线程上要卡一下。只把字节送出去、在后台建好图再交回来。
      let data = Data(svg.utf8)
      let decoded = await Task.detached(priority: .userInitiated) {
        SendableImage(NSImage(data: data))
      }.value
      guard !Task.isCancelled else { return }
      image = decoded.image
    }
  }

  private func presentLightbox() {
    guard let url = Self.rasterizedPNG(svg: svg, taskID: taskID, themeID: themeID) else { return }
    InlineImageLightboxController.shared.present(url, preparedText: outlineText)
  }

  /// 2x 栅格化：灯箱与后续分享都要位图；文件按任务+主题落在临时目录，
  /// 每次点击重写，编辑后的最新内容永远即时生效。
  static func rasterizedPNG(svg: String, taskID: TaskID, themeID: String) -> URL? {
    guard let image = NSImage(data: Data(svg.utf8)), image.size.width > 0 else { return nil }
    let scale: CGFloat = 2
    let pixelSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
      in: NSRect(origin: .zero, size: pixelSize),
      from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-mindmap-\(taskID.rawValue)-\(themeID).png")
    do { try data.write(to: url, options: .atomic) } catch { return nil }
    return url
  }
}

/// 把后台建好的 NSImage 交回主线程。建好后不再改它，只读地交出去是安全的。
private struct SendableImage: @unchecked Sendable {
  let image: NSImage?
  init(_ image: NSImage?) { self.image = image }
}

/// 纯文本导出载体：SVG 与 HTML 共用。
struct MindMapExportFile: FileDocument {
  static let readableContentTypes: [UTType] = [.svg, .html, .plainText]
  let text: String

  init(text: String) { self.text = text }
  init(configuration: ReadConfiguration) throws {
    text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
  }
  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

/// 节点文本编辑器：改错别字用。表单化编辑 → 保存后本地重渲染。
struct MindMapOutlineEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var subtitle: String
  @State private var branches: [EditableBranch]
  private let onSave: (MindMapOutline) -> Void

  struct EditableBranch: Identifiable {
    let id = UUID()
    var title: String
    var leaves: [EditableLeaf]
  }
  struct EditableLeaf: Identifiable {
    let id = UUID()
    var text: String
  }

  init(outline: MindMapOutline, onSave: @escaping (MindMapOutline) -> Void) {
    _title = State(initialValue: outline.title)
    _subtitle = State(initialValue: outline.subtitle ?? "")
    _branches = State(initialValue: outline.branches.map { branch in
      EditableBranch(title: branch.title, leaves: branch.leaves.map { EditableLeaf(text: $0) })
    })
    self.onSave = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("编辑脑图").themedFont(.headline).padding(.bottom, 12)
      Form {
        Section("中心") {
          TextField("中心主题", text: $title)
          TextField("副标题（可空）", text: $subtitle)
        }
        ForEach($branches) { $branch in
          Section {
            TextField("分支标题", text: $branch.title)
            ForEach($branch.leaves) { $leaf in
              TextField("要点", text: $leaf.text)
            }
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") {
          let outline = MindMapOutline(
            title: title,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subtitle,
            branches: branches.map { branch in
              MindMapOutline.Branch(
                title: branch.title,
                leaves: branch.leaves.map(\.text).filter {
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
              )
            }
          )
          onSave(outline)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 12)
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 520)
  }
}
