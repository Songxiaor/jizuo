import AppKit
import Carbon.HIToolbox
import LinkDigestCore
import SwiftUI

/// 快速记录：在任何 App 里按 ⌃⌥N，弹一个小窗记一句，存进「我的笔记」。
///
/// 语音备忘录解决「说」，这里解决「写」——灵感来的时候最大的摩擦是切到汲作、
/// 找到新建笔记、再想标题。小窗只要求打字，标题取第一行，类型默认「灵感」。
///
/// 全局快捷键用 Carbon 的 `RegisterEventHotKey`：它只拦截这一个组合键，不需要
/// 「辅助功能」或「输入监控」权限，也读不到用户按的其它任何键。
@MainActor
final class QuickCaptureController: ObservableObject {
  static let shortcutDescription = "⌃⌥N"

  /// C 回调拿不到上下文，只能经由这个静态引用找回控制器；只在主线程读写。
  nonisolated(unsafe) private static weak var current: QuickCaptureController?

  @Published var text = ""
  @Published var type: MaterialCatalog.MaterialType = .inspiration
  @Published private(set) var isSaving = false
  @Published var errorMessage: String?

  private weak var manualLink: ManualLinkViewModel?
  private weak var historyModel: HistoryViewModel?
  private var history: HistoryApplicationService?
  private var panel: NSPanel?
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  func configure(history: HistoryApplicationService?, manualLink: ManualLinkViewModel, historyModel: HistoryViewModel) {
    self.history = history
    self.manualLink = manualLink
    self.historyModel = historyModel
    registerHotKeyIfNeeded()
  }

  var canSave: Bool {
    !isSaving && history != nil && manualLink?.ingestor != nil
      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: 快捷键

  private func registerHotKeyIfNeeded() {
    guard hotKeyRef == nil else { return }
    Self.current = self
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { QuickCaptureController.current?.show() }
      }
      return noErr
    }, 1, &spec, nil, &handlerRef)
    let identifier = EventHotKeyID(signature: OSType(0x4A5A_5143), id: 1) // "JZQC"
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_N),
      UInt32(controlKey | optionKey),
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    if status != noErr {
      // 组合键被别的 App 占用时静默放弃：菜单里的「快速记录」照样能用。
      hotKeyRef = nil
      AppLog.info(.capture, "quick_capture_hotkey_unavailable", ["status": String(status)])
    }
  }

  // MARK: 小窗

  func show() {
    if panel == nil { panel = makePanel() }
    errorMessage = nil
    NSApp.activate(ignoringOtherApps: true)
    panel?.center()
    panel?.makeKeyAndOrderFront(nil)
  }

  func close() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "快速记录"
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentViewController = NSHostingController(rootView: QuickCaptureView(controller: self))
    return panel
  }

  // MARK: 保存

  func save() {
    guard canSave, let ingestor = manualLink?.ingestor, let history else { return }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let tagName = type.tagName
    isSaving = true
    errorMessage = nil
    Task { [weak self] in
      do {
        let document = try UserNoteDocument.make(title: Self.title(from: body), body: body)
        // 不抢主窗口的焦点：记完就回到原来在做的事。
        let capture = try await ingestor.ingest(document, suppressesAutomaticEnrichment: true, navigationIntent: .keepCurrent)
        _ = try history.addTags([tagName], to: capture.taskID)
        guard let self else { return }
        self.isSaving = false
        self.text = ""
        self.historyModel?.reload()
        self.close()
      } catch {
        self?.isSaving = false
        self?.errorMessage = "没有保存成功，请稍后再试。文字还在，不会丢。"
      }
    }
  }

  /// 标题取第一行，过长截断——列表里一眼认出是哪个念头。
  static func title(from body: String) -> String {
    let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? body
    let cleaned = UserNoteDocument.sanitizedTitle(first.replacingOccurrences(of: "#", with: ""))
    guard !cleaned.isEmpty else { return UserNoteDocument.untitledTitle }
    return cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
  }
}

private struct QuickCaptureView: View {
  @ObservedObject var controller: QuickCaptureController
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextEditor(text: $controller.text)
        .font(.body)
        .focused($focused)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
          if controller.text.isEmpty {
            Text("记下一个灵感、一句金句、一个选题…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 13).padding(.vertical, 8)
              .allowsHitTesting(false)
          }
        }
        .accessibilityIdentifier("quick-capture-text")
      HStack(spacing: 6) {
        ForEach(MaterialCatalog.MaterialType.allCases, id: \.self) { type in
          Button {
            controller.type = type
          } label: {
            Label(type.tagName, systemImage: type.systemImage)
              .font(.caption)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(controller.type == type ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("quick-capture-type-\(type.tagName)")
        }
      }
      if let error = controller.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Text("存到「我的笔记」，全局快捷键 \(QuickCaptureController.shortcutDescription)")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("取消") { controller.close() }
          .keyboardShortcut(.cancelAction)
        Button(controller.isSaving ? "保存中…" : "保存") { controller.save() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!controller.canSave)
          .accessibilityIdentifier("quick-capture-save")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 30)
    .padding(.bottom, 14)
    .frame(minWidth: 460, minHeight: 240)
    .onAppear { focused = true }
  }
}
