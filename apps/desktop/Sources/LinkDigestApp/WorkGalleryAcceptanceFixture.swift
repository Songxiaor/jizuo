#if DEBUG
import AppKit
import Combine
import SwiftUI
import LinkDigestCore

/// Opt-in UI acceptance surface using production widgets and no capture/network.
/// Requires the existing temp-root + sentinel visual-fixture gate as well.
@MainActor
enum WorkGalleryAcceptanceFixture {
  static let ids = (1...4).map { "123456789010\($0)" }
  private static var window: NSWindow?
  private static var selection: AnyCancellable?
  private static var activationObserver: NSObjectProtocol?

  static func show(manualLink: ManualLinkViewModel) {
    guard window == nil, AppApplicationSupportRoot.shouldUseVisualFixture(),
          ProcessInfo.processInfo.environment["LINKDIGEST_DEBUG_WORK_GALLERY"] == "1",
          let path = ProcessInfo.processInfo.environment[AppApplicationSupportRoot.smokeOverrideEnvironmentKey]
    else { return }
    let root = URL(fileURLWithPath: path).deletingLastPathComponent()
    let model = makeModel(root: root)
    selection = model.$selectedIDs.sink { ids in
      if let data = try? JSONSerialization.data(withJSONObject: Array(ids).sorted()) {
        try? data.write(to: root.appendingPathComponent("selection.json"), options: .atomic)
      }
    }
    let images = GalleryAcceptanceImages(root: root)
    let pagination = GalleryPaginationAcceptanceState(root: root)
    let view = TabView {
      DouyinProfileImportSheet(external: model, manualLink: manualLink)
        .tabItem { Text("导入排序") }
      GalleryAcceptanceImagePanel(images: images).tabItem { Text("图片与点击") }
      GalleryPaginationAcceptancePanel(fixture: pagination).tabItem { Text("分页恢复") }
    }.frame(width: 980, height: 760)
    let panel = NSWindow(contentRect: NSRect(x: 150, y: 80, width: 980, height: 790),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    panel.title = "汲作 · 隔离验收（不连接真实资料）"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: view)
    window = panel
    // Keep the acceptance window addressable when this App is explicitly activated.
    // Do not use a floating level: desktop tools may exclude floating windows.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak panel] _ in
      MainActor.assumeIsolated { panel?.makeKeyAndOrderFront(nil) }
    }
    panel.makeKeyAndOrderFront(nil)
  }

  static func makeModel(root: URL) -> DouyinProfileImportViewModel {
    let creatorID = CreatorID()
    let model = DouyinProfileImportViewModel(alreadySaved: { _ in false },
      enqueue: { urls, downloads, _ in
        if let data = try? JSONSerialization.data(withJSONObject: ["urls": urls, "downloadsVideo": downloads]) {
          try? data.write(to: root.appendingPathComponent("queue.json"), options: .atomic)
        }
        return .init(queued: urls.count, skipped: 0)
      }, ensureCreator: { _, _, _ in creatorID }, refreshCreatorName: { _, _, _ in }, attachExisting: { _, _ in })
    model.input = "https://x.com/fixture_author"
    let titles = ["A · 点赞缺失／时间缺失", "B · 点赞 0", "C · 点赞 1.2万", "D · 点赞 20"]
    let dates: [String?] = [nil, "2026-09-07", "2026-09-05", "2026-09-08"]
    _ = model.mergeExternalCandidates(.init(requestId: "isolated-ui", profileURL: model.input,
      authorID: "fixture_author", profileName: "隔离排序验收", items: ids.enumerated().map { index, id in
        .init(id: id, url: "https://x.com/fixture_author/status/\(id)", previewText: titles[index], publishedText: dates[index])
      }))
    for (index, likes) in [nil, "0", "1.2万", "20"].enumerated() {
      model.updateMetrics(.init(status: "ready", workID: ids[index], likes: likes, comments: nil,
        collects: nil, source: "isolated_fixture", readAt: nil, authorID: "fixture_author"), expectedWorkID: ids[index])
    }
    return model
  }
}

@MainActor
private final class GalleryAcceptanceImages: ObservableObject {
  @Published var parentClicks = 0
  let loader: WorkThumbnailLoader
  init(root: URL) {
    let probe = GalleryAcceptanceImageFetch(root: root)
    loader = WorkThumbnailLoader(fetch: { try await probe.fetch($0) })
  }
}
private actor GalleryAcceptanceImageFetch {
  let root: URL
  var failures = 0
  init(root: URL) { self.root = root }
  func fetch(_ url: URL) async throws -> Data {
    if url.lastPathComponent == "fail", failures == 0 { failures += 1; throw CocoaError(.fileReadUnknown) }
    if url.lastPathComponent == "loading" {
      while !FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-image").path) {
        try await Task.sleep(for: .milliseconds(250))
      }
    }
    return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
  }
}
@MainActor
private struct GalleryAcceptanceImagePanel: View {
  @ObservedObject var images: GalleryAcceptanceImages
  var body: some View {
    VStack(spacing: 20) {
      Text("隔离图片状态 · 父卡片点击 \(images.parentClicks)")
      HStack(spacing: 16) {
        tile("无图文字预览", path: nil, text: "这段预览应能点击父卡片")
        tile("无图无文字", path: nil, text: nil)
        tile("延迟加载", path: "loading", text: nil)
        tile("首次失败／点击重试", path: "fail", text: nil)
      }
    }.padding(20)
  }
  private func tile(_ title: String, path: String?, text: String?) -> some View {
    VStack {
      Text(title)
      Button { images.parentClicks += 1 } label: {
        DouyinProfilePreviewImage(url: path.map { URL(string: "https://fixture.invalid/\($0)")! },
          previewText: text, thumbnailLoader: images.loader)
          .frame(width: 210, height: 150).clipped()
      }.buttonStyle(.plain)
    }
  }
}
#endif
