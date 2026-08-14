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
  @ObservedObject var model: HistoryViewModel

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
    let title = model.mindMapRecord?.outline.title ?? "\(ProductDisplay.name) 脑图"
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

  @ViewBuilder private func mapCard(_ record: TaskMindMapRecord) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("脑图").font(.headline)
        if record.userEdited {
          Text("已编辑").font(.caption2).appSecondaryText()
        }
        Spacer(minLength: 0)
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
        .accessibilityLabel("脑图主题")
        Button("重新生成") { model.requestMindMapGeneration(taskID: taskID) }
          .controlSize(.small)
          .disabled(!model.canGenerateMindMap(taskID: taskID))
          .help("重新把文字发送给模型提取脑图结构；会覆盖当前脑图（含手动编辑）。")
          .accessibilityLabel("重新生成脑图")
          .accessibilityIdentifier("mind-map-regenerate")
        Button("编辑") { isEditorPresented = true }
          .controlSize(.small)
          .help("编辑脑图结构")
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
        .frame(width: 84)
        .help("导出脑图")
        .accessibilityLabel("导出脑图")
        .accessibilityIdentifier("mind-map-export")
      }
      if let svg = model.mindMapSVG() {
        MindMapCanvasView(
          svg: svg,
          taskID: taskID,
          themeID: record.themeID,
          outlineText: Self.outlinePlainText(record.outline)
        )
      }
      HStack(spacing: 12) {
        stateText
        if let tokens = model.mindMapTokenSummary {
          Text(tokens).font(.caption).appSecondaryText()
        }
        Spacer(minLength: 0)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
    )
    .accessibilityIdentifier("mind-map-card")
  }

  @ViewBuilder private var stateText: some View {
    switch model.mindMapState(for: taskID) {
    case .idle: EmptyView()
    case .running:
      ProgressView().controlSize(.small)
      Text("正在生成脑图…").font(.caption)
    case .completed:
      Label("脑图已保存", systemImage: "checkmark.circle.fill")
        .font(.caption).foregroundStyle(appTheme.success)
    case .cancelled: EmptyView()
    case let .failed(message):
      Text(message).font(.caption).foregroundStyle(appTheme.danger).lineLimit(2)
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
    .frame(height: image.map { min(Self.viewportHeight, max(160, $0.size.height)) } ?? 200)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .accessibilityIdentifier("mind-map-canvas")
    .task(id: svg) { image = NSImage(data: Data(svg.utf8)) }
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
      Text("编辑脑图").font(.headline).padding(.bottom, 12)
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
