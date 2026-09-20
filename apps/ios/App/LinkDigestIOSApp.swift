import LinkDigestIOS
import LinkDigestShared
import SwiftUI

@main
struct LinkDigestIOSApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: NotesViewModel?

  var body: some Scene {
    WindowGroup {
      Group {
        if let model {
          NotesRootView(model: model)
        } else {
          ProgressView("加载本地笔记…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await bootstrap() }
        }
      }
      .onOpenURL { url in
        guard url.scheme?.lowercased() == "linkdigest" else { return }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
          .lowercased()
        if host == "settings" {
          NotificationCenter.default.post(name: .linkDigestOpenSettings, object: nil)
          return
        }
        guard let model else { return }
        Task { await model.importShareInbox() }
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active, let model else { return }
        Task { await model.importShareInbox() }
      }
    }
  }

  @MainActor
  private func bootstrap() async {
    // Personal Team 真机 entitlements 为空时不能开 CloudKit（会 SIGTRAP）。
    // App Group 用于 Share Extension 暂存；无 Group 时 ShareInbox 降级 Pasteboard。
    let sync = CloudKitNoteCardSync(enabled: CloudKitCapability.isContainerEntitled())
    do {
      let store = try await LocalJSONNoteCardStore.applicationSupportStore(subdirectory: "LinkDigestIOS")
      let next = NotesViewModel(store: store, sync: sync)
      model = next
      await next.importShareInbox()
    } catch {
      let next = NotesViewModel(store: InMemoryNoteCardStore(), sync: sync)
      model = next
      await next.importShareInbox()
    }
  }
}
