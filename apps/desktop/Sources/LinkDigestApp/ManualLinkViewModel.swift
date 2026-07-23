import AppKit
import Combine
import Foundation
import SwiftUI
import LinkDigestAdapters
import LinkDigestCore

protocol ClipboardReading: Sendable { func string() -> String? }

struct NSPasteboardClipboardReader: ClipboardReading {
  func string() -> String? { NSPasteboard.general.string(forType: .string) }
}

enum ManualLinkState: Equatable { case idle, fetching, saving, failed(String) }

struct ClipboardLinkSuggestion: Equatable {
  let canonicalURL: String
  let host: String

  var displayURL: String { canonicalURL }
}

enum RemoteMarkdownImageStagingPolicy {
  static let minimumProseCharacterCount = 40

  static func isSubstantiveWeChatArticle(platform: String?, markdown: String) -> Bool {
    guard platform == "wechat" else { return false }
    var prose = MarkdownNoteFrontmatter.parse(markdown).body
    for pattern in [
      #"!\[[^\]]*\]\([^)]*\)"#,
      #"<img\b[^>]*>"#,
      #"https?://[^\s)>]+"#,
    ] {
      prose = prose.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    let visibleCount = prose.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) }
    return visibleCount >= minimumProseCharacterCount
  }

  static func allows(_ document: CapturedDocument) -> Bool {
    if document.platform == "douyin" { return false }
    guard document.media != nil else { return true }
    return isSubstantiveWeChatArticle(platform: document.platform, markdown: document.text)
  }
}

@MainActor
final class ManualLinkViewModel: ObservableObject {
  @Published var input = ""
  @Published private(set) var state: ManualLinkState = .idle
  @Published var isPresented = false
  @Published private(set) var clipboardSuggestion: ClipboardLinkSuggestion?

  private let captureService: ManualLinkCaptureService
  private let weChatCapture: any WeChatWebCapturing
  private let clipboard: any ClipboardReading
  private let imageCache: GitHubREADMEImageCache?
  private let imageResources: (any SafeResourceFetching)?
  private let onMediaCaptured: ((CaptureMedia, TaskID, ContentSnapshotID, String) async -> Void)?
  private var ingestor: CaptureIngestService?
  private var history: HistoryApplicationService?
  private var task: Task<Void, Never>?
  private var hasCheckedCurrentActivePhase = false
  private var lastClipboardCanonicalURL: String?
  private var lastHandledClipboardCanonicalURL: String?
  private var pendingClipboardSuggestion: ClipboardLinkSuggestion?

  init(
    captureService: ManualLinkCaptureService = .init(fetcher: ProxyAwareWebPageFetcher()),
    weChatCapture: any WeChatWebCapturing = WeChatWKWebViewCaptureService(),
    clipboard: any ClipboardReading = NSPasteboardClipboardReader(),
    imageCache: GitHubREADMEImageCache? = nil,
    imageResources: (any SafeResourceFetching)? = nil,
    onMediaCaptured: ((CaptureMedia, TaskID, ContentSnapshotID, String) async -> Void)? = nil
  ) {
    self.captureService = captureService
    self.weChatCapture = weChatCapture
    self.clipboard = clipboard
    self.imageCache = imageCache
    self.imageResources = imageResources
    self.onMediaCaptured = onMediaCaptured
  }

  deinit { task?.cancel() }

  var isFetching: Bool { if case .fetching = state { true } else { false } }
  var isSaving: Bool { if case .saving = state { true } else { false } }
  /// The only cancellable phase is network reading. Once the synchronous
  /// repository commit starts, reporting cancellation would misstate history.
  var canCancelFetch: Bool { isFetching }
  var isBusy: Bool { isFetching || isSaving }
  var errorMessage: String? { if case let .failed(message) = state { message } else { nil } }
  var fetchingMessage: String {
    guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          WeChatWebCapturePolicy.isCandidate(url)
    else { return "正在安全读取网页…" }
    return "正在抓取…"
  }
  var canOpen: Bool { !isBusy && ingestor != nil }
  var canSubmit: Bool { !isBusy && ingestor != nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  func configure(history: HistoryApplicationService?, storageWriteGate: StorageWriteGate, nowMilliseconds: @escaping @Sendable () -> Int64, captureSink: @escaping CaptureIngestService.CaptureSink) {
    self.history = history
    ingestor = .init(
      history: history,
      storageWriteGate: storageWriteGate,
      nowMilliseconds: nowMilliseconds,
      captureSink: captureSink,
      afterCommit: { [imageCache] document, accepted in
        // GitHub adapter stages into the same cache; also pull any absolute HTTPS images.
        // promote is idempotent for empty staging dirs.
        imageCache?.promote(captureID: document.requestID, taskID: accepted.taskID, snapshotID: accepted.snapshotID)
      }
    )
    presentPendingClipboardSuggestionIfEligible()
  }

  /// The App is the only owner of scenePhase. This model remains the only
  /// owner of ClipboardReading, so every foreground check has one audited read.
  func handleScenePhase(_ phase: ScenePhase) {
    guard phase == .active else {
      hasCheckedCurrentActivePhase = false
      return
    }
    guard !hasCheckedCurrentActivePhase else { return }
    hasCheckedCurrentActivePhase = true
    inspectClipboardOnce()
  }

  /// On macOS `scenePhase` tracks window visibility, not app activation:
  /// switching from another app back to LinkDigest leaves it at `.active`, so
  /// the scenePhase path fired once at launch and never again. Copying a link
  /// elsewhere and returning is exactly the flow this feature exists for, and
  /// `NSApplication.didBecomeActiveNotification` is the signal that actually
  /// fires for it. Still one audited read per activation.
  func handleApplicationDidBecomeActive() {
    hasCheckedCurrentActivePhase = true
    inspectClipboardOnce()
  }

  func ignoreClipboardSuggestion() {
    guard let suggestion = clipboardSuggestion else { return }
    lastHandledClipboardCanonicalURL = suggestion.canonicalURL
    clipboardSuggestion = nil
  }

  func captureClipboardSuggestion() {
    guard let suggestion = clipboardSuggestion, !isBusy, ingestor != nil, let history else { return }
    do {
      let canonical = try CanonicalURL(suggestion.canonicalURL)
      guard !(try history.containsCanonicalURL(canonical)) else {
        lastHandledClipboardCanonicalURL = suggestion.canonicalURL
        clipboardSuggestion = nil
        return
      }
    } catch {
      lastHandledClipboardCanonicalURL = suggestion.canonicalURL
      clipboardSuggestion = nil
      return
    }
    lastHandledClipboardCanonicalURL = suggestion.canonicalURL
    clipboardSuggestion = nil
    input = suggestion.canonicalURL
    state = .idle
    isPresented = true
    submit()
  }

  private func inspectClipboardOnce() {
    // Never publish or log the returned string. It survives only long enough
    // to decide whether it is a syntactically safe HTTPS URL.
    guard let candidate = safeClipboardSuggestion(from: clipboard.string()) else {
      lastClipboardCanonicalURL = nil
      lastHandledClipboardCanonicalURL = nil
      clipboardSuggestion = nil
      pendingClipboardSuggestion = nil
      return
    }
    if candidate.canonicalURL != lastClipboardCanonicalURL {
      lastClipboardCanonicalURL = candidate.canonicalURL
      lastHandledClipboardCanonicalURL = nil
      clipboardSuggestion = nil
    }
    guard lastHandledClipboardCanonicalURL != candidate.canonicalURL else { return }
    pendingClipboardSuggestion = candidate
    presentPendingClipboardSuggestionIfEligible()
  }

  private func presentPendingClipboardSuggestionIfEligible() {
    guard let candidate = pendingClipboardSuggestion,
          lastHandledClipboardCanonicalURL != candidate.canonicalURL,
          let history
    else { return }
    do {
      let canonical = try CanonicalURL(candidate.canonicalURL)
      guard !(try history.containsCanonicalURL(canonical)) else {
        lastHandledClipboardCanonicalURL = candidate.canonicalURL
        pendingClipboardSuggestion = nil
        clipboardSuggestion = nil
        return
      }
      clipboardSuggestion = candidate
      pendingClipboardSuggestion = nil
    } catch {
      // History errors fail closed. Clipboard contents must not surface as an
      // error or be retained while storage availability is uncertain.
      pendingClipboardSuggestion = nil
      clipboardSuggestion = nil
    }
  }

  private func safeClipboardSuggestion(from rawValue: String?) -> ClipboardLinkSuggestion? {
    guard let rawValue else { return nil }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), !host.isEmpty,
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let canonical = try? CanonicalURL(trimmed)
    else { return nil }
    return .init(canonicalURL: canonical.value, host: host)
  }

  func open() { guard !isBusy, ingestor != nil else { return }; state = .idle; isPresented = true }

  func readClipboardAndOpen() {
    guard !isBusy, ingestor != nil else { return }
    guard let value = clipboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      state = .failed("剪贴板里没有可用链接。"); isPresented = true; return
    }
    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
      state = .failed("剪贴板里的内容不是有效网页链接。"); isPresented = true; return
    }
    input = value; state = .idle; isPresented = true
  }

  func submit() {
    guard canSubmit, let ingestor else { return }
    let value = input
    state = .fetching
    task?.cancel()
    task = Task { [weak self] in
      var capturedDocument: CapturedDocument?
      do {
        let document: CapturedDocument?
        if let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           WeChatWebCapturePolicy.isCandidate(url) {
          document = try await self?.weChatCapture.capture(url: url)
        } else {
          document = try await self?.captureService.capture(urlString: value)
        }
        guard let document else { return }
        capturedDocument = document
        guard !Task.isCancelled else {
          self?.imageCache?.discardStaged(captureID: document.requestID)
          return
        }
        try Task.checkCancellation()
        // Substantive WeChat articles keep their inline images even when they
        // also carry an embedded-video descriptor. Pure video captures do not.
        if RemoteMarkdownImageStagingPolicy.allows(document),
           let imageCache = self?.imageCache,
           let resources = self?.imageResources {
          if document.platform == "wechat", let articleURL = URL(string: document.url) {
            let note = MarkdownNoteFrontmatter.parse(document.text)
            await imageCache.stageWeChatImages(
              bodyImageURLs: MarkdownRemoteImageReferences.absoluteHTTPSURLs(in: note.body).map(\.absoluteString),
              coverImageURL: nil,
              articleURL: articleURL,
              captureID: document.requestID,
              resources: resources
            )
          } else {
            // Existing generic/GitHub staging keeps its broader policy unchanged.
            await imageCache.stageRemoteMarkdownImages(
              markdown: document.text,
              captureID: document.requestID,
              resources: resources
            )
          }
        }
        // A committed SQLite write cannot honestly be reported as cancelled.
        self?.state = .saving
        let accepted = try await ingestor.ingest(document)
        // Signed media URLs must be downloaded in the same flow; never stored for later.
        if let media = document.media, let onMediaCaptured = self?.onMediaCaptured {
          // Pass page URL so CDN downloads can set a public Referer (no cookies).
          await onMediaCaptured(media, accepted.taskID, accepted.snapshotID, document.url)
        }
        self?.state = .idle
        self?.isPresented = false
        self?.input = ""
      } catch let error as ManualLinkError {
        if let capturedDocument { self?.imageCache?.discardStaged(captureID: capturedDocument.requestID) }
        guard !Task.isCancelled else { return }
        self?.state = .failed(error.userMessage)
      } catch is CancellationError {
        if let capturedDocument { self?.imageCache?.discardStaged(captureID: capturedDocument.requestID) }
        self?.state = .idle
      } catch {
        if let capturedDocument { self?.imageCache?.discardStaged(captureID: capturedDocument.requestID) }
        self?.state = .failed("无法保存这条链接，本地历史未发生变更。")
      }
    }
  }

  func cancelFetch() { guard canCancelFetch else { return }; task?.cancel(); task = nil; state = .idle }
  func dismiss() {
    if isFetching { cancelFetch(); isPresented = false }
    else if !isSaving { isPresented = false }
  }
}
