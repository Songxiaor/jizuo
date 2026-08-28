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

/// 「添加网页链接」里对自动模型调用的事前说明。
///
/// 这里按真正会发出的远程步骤计数，不能再把「自动总结」当成整条自动管线的
/// 同义词：总结和脑图同时打开时就是两次独立调用。视频转写后的文稿整理取决于
/// 页面有没有媒体，因此单独写成条件项，不拿一个看似精确的数字误导用户。
struct AutomaticModelCallDisclosure: Equatable {
  let autoSummarize: Bool
  let autoMindMap: Bool
  let mayAutoTidyVideoTranscript: Bool

  var message: String? {
    var steps: [String] = []
    if autoSummarize { steps.append("总结") }
    if autoMindMap { steps.append("脑图") }

    var parts: [String] = []
    if !steps.isEmpty {
      parts.append(
        "添加后将自动抓取并执行\(steps.joined(separator: "、"))，预计产生 \(steps.count) 次模型调用。"
      )
    }
    if mayAutoTidyVideoTranscript {
      parts.append("如果链接包含视频并完成自动转写，文稿整理还会额外产生 1 次模型调用。")
    }
    guard !parts.isEmpty else { return nil }
    parts.append("可在设置的「生成偏好」里关闭。")
    return parts.joined()
  }
}

/// Normalizes text the user explicitly submits into one web URL.
///
/// Sharing sheets often copy a sentence plus one link (Douyin is a common
/// example). Accepting that explicit input is different from automatically
/// surfacing arbitrary clipboard text: `safeClipboardSuggestion` below remains
/// deliberately strict and still accepts only a clipboard value that is itself
/// an HTTPS URL.
enum ExplicitWebLinkInput {
  /// 句尾标点不属于 URL。
  ///
  /// 从中文正文里复制链接时，末尾常带一个「。」或「，」。`URL(string:)` 会把它
  /// 百分号编码后照单全收——`…/claude-code。` 变成 `…/claude-code%E3%80%82`，
  /// scheme 和 host 都合法，于是「直接命中」这条路径把它当成有效链接放过去，
  /// 抓取时才报「网页暂时无法打开」，而错在多了一个字符。
  ///
  /// 不剥右括号和右方括号：Wikipedia 这类地址里它们是路径的一部分。
  private static let trailingSentencePunctuation = CharacterSet(charactersIn: "。，、；：！？…·．,;:!?\"'“”‘’「」『』《》〉·")

  static func singleURL(from rawValue: String) -> URL? {
    var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = trimmed.unicodeScalars.last,
          trailingSentencePunctuation.contains(last) {
      trimmed = String(trimmed.unicodeScalars.dropLast())
    }
    guard !trimmed.isEmpty else { return nil }
    // 「整串就是一个裸链接」才走直接命中。
    //
    // 这里原来只做 `validatedWebURL(trimmed)`，而 `URL(string:)` 会把空白和汉字
    // 百分号编码后照单全收——「链接 + 换行 + 一整句中文」整段都能通过 scheme 与
    // host 校验，于是根本走不到下面那条按词边界识别的 detector 路径，抓取时才报
    // 「网页暂时无法打开」。
    //
    // 判据只看空白，不看汉字：原样汉字既可能是被吞进来的正文，也可能是路径本身
    // （中文维基那种）。而「整串没有任何空白」说明这是刻意粘进来的一个地址，
    // 此时汉字该原样保留；一旦出现空白就说明周围还有别的字，交给 detector 按词
    // 边界切，那条路径再负责把紧贴的中文正文截掉。
    let containsWhitespace = trimmed.unicodeScalars.contains {
      CharacterSet.whitespacesAndNewlines.contains($0)
    }
    if !containsWhitespace, let direct = validatedWebURL(trimmed) { return direct }

    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    guard let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return nil }

    var unique: [String: URL] = [:]
    detector.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
      guard let match, let detected = match.url else { return }
      // 中文紧跟在链接后面而中间没有空格时，NSDataDetector 会把正文一起吃进去：
      // `…/vibe-hub-skill帮我安装` 整串被当成一个链接，百分号编码后 scheme 和
      // host 仍然合法，于是一路放行到抓取才报「网页暂时无法打开」。
      //
      // 换行或空格分隔时它是对的，所以这里只处理「紧贴」这一种。
      let candidate: URL = {
        guard let matchRange = Range(match.range, in: trimmed) else { return detected }
        let raw = String(trimmed[matchRange])
        let cut = Self.truncatedAtRawCJK(raw)
        guard cut != raw, let trimmedURL = validatedWebURL(cut) else { return detected }
        return trimmedURL
      }()
      guard let url = validatedWebURL(candidate.absoluteString) else { return }
      unique[url.absoluteString] = url
    }
    guard unique.count == 1 else { return nil }
    return unique.values.first
  }

  /// 在第一个**未编码**的中日韩字符处截断。
  ///
  /// 判据是「原样的汉字」而不是「任何汉字」：从浏览器地址栏复制中文维基这类地址，
  /// 拿到的是 `%E7%BC%96%E7%A8%8B…` 这种百分号编码形式，不受影响；而中文正文
  /// 紧跟链接时是原样汉字，那几乎一定是句子而不是路径。
  ///
  /// 代价是手打的原样中文 URL 会被截短。这种输入本来就不常见，且真要抓时把地址
  /// 从浏览器复制一次即可；反过来放过它，则每次中文紧贴链接都会静默抓失败。
  private static func truncatedAtRawCJK(_ value: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      if isRawCJK(scalar) { break }
      result.append(scalar)
    }
    return String(result)
  }

  private static func isRawCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x303F,   // CJK 标点
         0x3040...0x30FF,   // 假名
         0x3400...0x4DBF,   // 扩展 A
         0x4E00...0x9FFF,   // 基本汉字
         0xAC00...0xD7AF,   // 谚文
         0xF900...0xFAFF,   // 兼容汉字
         0xFF00...0xFFEF,   // 全角形式
         0x20000...0x2FA1F: // 扩展 B 及以后
      return true
    default:
      return false
    }
  }

  private static func validatedWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value),
          ["http", "https"].contains(url.scheme?.lowercased()),
          let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }
}

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

  /// 抖音图文帖（无视频 media，正文内联远程图片）需要下载图片；
  /// 抖音视频帖（有 media）不下载正文图片，避免刮到无关缩略图。
  static func isDouyinImagePost(_ document: CapturedDocument) -> Bool {
    guard document.platform == "douyin", document.media == nil else { return false }
    return document.text.range(of: #"!\[[^\]]*\]\(https?://[^)]*douyinpic\.com/"#, options: .regularExpression) != nil
  }

  /// X 帖子的正文图片（含引用推文的配图）都来自 pbs.twimg.com。它们是内容，
  /// 与帖子是否附带视频无关——带视频的推文同样要下载正文图片。
  static func isXPostWithBodyImages(_ document: CapturedDocument) -> Bool {
    guard document.platform == "x" else { return false }
    return document.text.range(
      of: #"!\[[^\]]*\]\(https?://[^)]*pbs\.twimg\.com/"#,
      options: .regularExpression
    ) != nil
  }

  static func allows(_ document: CapturedDocument) -> Bool {
    if document.platform == "douyin" { return isDouyinImagePost(document) }
    if isXPostWithBodyImages(document) { return true }
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
  /// 重复链接确认：默认拦截，用户确认「仍要重新抓取」后放行一次。
  @Published var isDuplicatePromptPresented = false
  /// 排队抓取：提交即入队关窗，进度在列表顶部展示。
  @Published private(set) var pendingCaptures: [PendingCapture] = []

  struct PendingCapture: Identifiable, Equatable {
    enum Phase: Equatable { case queued, fetching, saving, failed(String) }
    let id: UUID
    let urlString: String
    var phase: Phase
  }

  private var allowsDuplicateSubmit = false
  private var queueWorker: Task<Void, Never>?
  private var activeCaptureID: UUID?
  private var activeCaptureTask: Task<Void, Error>?

  private let captureService: ManualLinkCaptureService
  private let weChatCapture: any WeChatWebCapturing
  private let douyinCapture: (any DouyinWebCapturing)?
  private let clipboard: any ClipboardReading
  private let imageCache: GitHubREADMEImageCache?
  private let imageResources: (any SafeResourceFetching)?
  /// X 用 MSE 播放、正文也是客户端渲染，直接抓 x.com 只会得到 SPA 外壳。
  /// 有解析器时，X 链接改走公开端点取回完整推文。
  private let xResolver: XTweetResolver?
  private let onMediaCaptured: ((CaptureMedia, TaskID, ContentSnapshotID, String) async -> Void)?
  /// 笔记写作窗口复用同一个 ingestor：两条路都是「往库里加一条记录」，
  /// 没有理由维护两套落库逻辑。
  private(set) var ingestor: CaptureIngestService?
  private var history: HistoryApplicationService?
  private var task: Task<Void, Never>?
  private var hasCheckedCurrentActivePhase = false
  private var lastClipboardCanonicalURL: String?
  private var lastHandledClipboardCanonicalURL: String?
  private var pendingClipboardSuggestion: ClipboardLinkSuggestion?

  init(
    captureService: ManualLinkCaptureService = .init(fetcher: ProxyAwareWebPageFetcher()),
    weChatCapture: any WeChatWebCapturing = WeChatWKWebViewCaptureService(),
    douyinCapture: (any DouyinWebCapturing)? = nil,
    clipboard: any ClipboardReading = NSPasteboardClipboardReader(),
    imageCache: GitHubREADMEImageCache? = nil,
    imageResources: (any SafeResourceFetching)? = nil,
    xResolver: XTweetResolver? = nil,
    onMediaCaptured: ((CaptureMedia, TaskID, ContentSnapshotID, String) async -> Void)? = nil
  ) {
    self.captureService = captureService
    self.weChatCapture = weChatCapture
    self.douyinCapture = douyinCapture
    self.clipboard = clipboard
    self.imageCache = imageCache
    self.imageResources = imageResources
    self.xResolver = xResolver
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
    guard let url = ExplicitWebLinkInput.singleURL(from: input),
          WeChatWebCapturePolicy.isCandidate(url)
    else { return "正在安全读取网页…" }
    return "正在抓取…"
  }
  var canOpen: Bool { !isBusy && ingestor != nil }

  /// 新建一条空白笔记。
  ///
  /// 走的是与手动链接**完全相同**的 `ingest(_:)` 落库路径——笔记只是「正文由用户自己
  /// 写」的一条记录，没有理由为它另开一条写入口。这样标签、搜索、翻译、总结、导出
  /// 全部自动可用，也不会出现两套落库逻辑各自演化的问题。
  /// 打开「今天」的笔记，没有就建一条。
  ///
  /// 幂等由 canonical URL 保证（同一天同一个值 + tasks 的 UNIQUE 约束），所以这里
  /// 不需要先查一次再决定——那在竞态下会产生两条。重复调用只会回到同一条。
  func openTodayNote(
    onOpened: (@MainActor (TaskID) -> Void)? = nil,
    onFailure: (@MainActor (String) -> Void)? = nil
  ) {
    guard let ingestor else {
      onFailure?("历史存储尚未就绪，请稍后再试。")
      return
    }
    Task {
      do {
        let document = try UserNoteDocument.makeDaily()
        let capture = try await ingestor.ingest(document)
        await MainActor.run { onOpened?(capture.taskID) }
      } catch {
        await MainActor.run { onFailure?("打开今天的笔记失败：\(String(describing: error))") }
      }
    }
  }

  /// 新建一条笔记。
  ///
  /// **不复用 `isBusy` 做门禁**：它由 `state` 派生，而 `state` 被手动链接的抓取流程
  /// 共用。抓取一旦把 state 停在 `.fetching`/`.saving`，`guard !isBusy` 就会让新建
  /// 笔记**完全没有反应**——没有提示、没有日志，用户只会觉得按钮是死的。
  /// 新建笔记是一次本地写入，和抓取排队没有关系，不该被它挡住。
  ///
  /// 失败也必须有声音：错误经 `onFailure` 交给调用方，用主界面确定可见的通道呈现，
  /// 而不是写进只在抓取弹窗里显示的 `state`。
  /// 建一条空白笔记。
  ///
  /// `title` 供工作台用：新建一件创作时，正文笔记直接以灵感原句命名，
  /// 列表里一眼能认出是哪个念头，而不是又一条「无标题笔记」。
  func createNote(
    title: String? = nil,
    onCreated: (@MainActor (TaskID) -> Void)? = nil,
    onFailure: (@MainActor (String) -> Void)? = nil
  ) {
    guard let ingestor else {
      onFailure?("历史存储尚未就绪，请稍后再试。")
      return
    }
    Task {
      do {
        let document = try UserNoteDocument.make(title: title)
        let capture = try await ingestor.ingest(document)
        await MainActor.run { onCreated?(capture.taskID) }
      } catch {
        await MainActor.run {
          onFailure?("新建笔记失败：\(String(describing: error))")
        }
      }
    }
  }
  /// 为工作台建一份稿件。
  ///
  /// 和 `createNote` 走同一条落库通道,区别只在 origin 与 scheme——
  /// 稿件属于「过程」,不该出现在「我的笔记」里。
  func createPieceDraft(
    title: String? = nil,
    onCreated: (@MainActor (TaskID) -> Void)? = nil,
    onFailure: (@MainActor (String) -> Void)? = nil
  ) {
    guard let ingestor else {
      onFailure?("历史存储尚未就绪，请稍后再试。")
      return
    }
    Task {
      do {
        let document = try PieceDraftDocument.make(title: title)
        let capture = try await ingestor.ingest(document)
        await MainActor.run { onCreated?(capture.taskID) }
      } catch {
        await MainActor.run {
          onFailure?("新建稿件失败：\(String(describing: error))")
        }
      }
    }
  }

  var canSubmit: Bool {
    !isBusy && ingestor != nil && ExplicitWebLinkInput.singleURL(from: input) != nil
  }

  /// 按钮变灰时同时说明原因，避免用户只能靠反复点击猜输入格式。
  var inputValidationMessage: String? {
    guard !isBusy else { return nil }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard ExplicitWebLinkInput.singleURL(from: input) == nil else { return nil }
    return "请输入一条完整网页链接，或只包含一条链接的分享文案。"
  }

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

  /// Opens the existing capture sheet with one historical source prefilled.
  /// Submission still goes through the duplicate confirmation and the same
  /// adapter/ingest queue, so recapture cannot silently overwrite a snapshot.
  func openForRecapture(_ rawURL: String) {
    guard !isBusy, ingestor != nil,
          let url = ExplicitWebLinkInput.singleURL(from: rawURL)
    else { return }
    input = url.absoluteString
    state = .idle
    isPresented = true
  }

  func readClipboardAndOpen() {
    guard !isBusy, ingestor != nil else { return }
    guard let value = clipboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      state = .failed("剪贴板里没有可用链接。"); isPresented = true; return
    }
    guard let url = ExplicitWebLinkInput.singleURL(from: value) else {
      state = .failed("剪贴板里的内容不是有效网页链接。"); isPresented = true; return
    }
    input = url.absoluteString; state = .idle; isPresented = true
  }

  private func markClipboardURLHandled(_ rawURL: String) {
    guard let canonical = try? CanonicalURL(rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    lastHandledClipboardCanonicalURL = canonical.value
    if clipboardSuggestion?.canonicalURL == canonical.value { clipboardSuggestion = nil }
    if pendingClipboardSuggestion?.canonicalURL == canonical.value { pendingClipboardSuggestion = nil }
  }

  func submit() {
    guard !isBusy, ingestor != nil else { return }
    guard let submittedURL = ExplicitWebLinkInput.singleURL(from: input) else {
      state = .failed("请输入一条完整网页链接，或只包含一条链接的分享文案。")
      isPresented = true
      return
    }
    let value = submittedURL.absoluteString
    // 重复检测：同一链接已在库中时先提示，避免静默重抓浪费请求与 token；
    // 用户确认后仍可继续（新抓取会併入原条目成为最新快照）。
    if !allowsDuplicateSubmit, let history,
       let canonical = try? CanonicalURL(value.trimmingCharacters(in: .whitespacesAndNewlines)),
       (try? history.containsCanonicalURL(canonical)) == true {
      isDuplicatePromptPresented = true
      return
    }
    allowsDuplicateSubmit = false
    markClipboardURLHandled(value)
    // 入队即关窗：抓取进度移到列表顶部排队区，用户可以继续浏览。
    pendingCaptures.append(PendingCapture(id: UUID(), urlString: value, phase: .queued))
    state = .idle
    isPresented = false
    input = ""
    kickCaptureQueue()
  }

  func confirmDuplicateSubmit() {
    isDuplicatePromptPresented = false
    allowsDuplicateSubmit = true
    submit()
  }

  func cancelDuplicateSubmit() {
    isDuplicatePromptPresented = false
    allowsDuplicateSubmit = false
  }

  struct BookmarksEnqueueOutcome: Equatable {
    let queued: Int
    let skipped: Int
  }

  /// 收藏夹同步：把一批推文 id 转成 x.com 链接塞进抓取队列，已在库的静默跳过
  /// （批量场景不能对每条弹重复确认框）。抓取本身复用既有的串行 worker——
  /// X 链接会在 performCapture 里走公开端点取回完整推文。
  @discardableResult
  func enqueueXBookmarks(_ tweetIDs: [String]) -> BookmarksEnqueueOutcome {
    guard ingestor != nil else { return .init(queued: 0, skipped: 0) }
    var queued = 0
    var skipped = 0
    var queuedURLs = Set(pendingCaptures.map(\.urlString))
    let existingIDs = (try? history?.existingXTweetIDs(in: tweetIDs)) ?? []
    for id in tweetIDs {
      guard XBookmarksSyncRequest.isValidTweetID(id) else { skipped += 1; continue }
      if existingIDs.contains(id) {
        skipped += 1
        continue
      }
      let urlString = "https://x.com/i/status/\(id)"
      // 同一条已在本次队列里（滚动重复采到）也跳过。
      if !queuedURLs.insert(urlString).inserted { skipped += 1; continue }
      pendingCaptures.append(PendingCapture(id: UUID(), urlString: urlString, phase: .queued))
      queued += 1
    }
    if queued > 0 { kickCaptureQueue() }
    return .init(queued: queued, skipped: skipped)
  }

  func retryPendingCapture(_ id: UUID) {
    guard let index = pendingCaptures.firstIndex(where: { $0.id == id }),
          case .failed = pendingCaptures[index].phase else { return }
    pendingCaptures[index].phase = .queued
    kickCaptureQueue()
  }

  func removePendingCapture(_ id: UUID) {
    if activeCaptureID == id { activeCaptureTask?.cancel() }
    pendingCaptures.removeAll { $0.id == id }
  }

  private func updatePendingPhase(_ id: UUID, _ phase: PendingCapture.Phase) {
    guard let index = pendingCaptures.firstIndex(where: { $0.id == id }) else { return }
    pendingCaptures[index].phase = phase
  }

  /// 串行处理：微信捕获走同一个 WKWebView 服务，不做并发。
  private func kickCaptureQueue() {
    guard queueWorker == nil else { return }
    queueWorker = Task { [weak self] in
      defer { self?.queueWorker = nil }
      while let self, let next = self.pendingCaptures.first(where: { $0.phase == .queued }) {
        self.updatePendingPhase(next.id, .fetching)
        self.activeCaptureID = next.id
        let work = Task { try await self.performCapture(value: next.urlString, pendingID: next.id) }
        self.activeCaptureTask = work
        do {
          try await work.value
          self.pendingCaptures.removeAll { $0.id == next.id }
        } catch let error as ManualLinkError {
          self.updatePendingPhase(next.id, .failed(error.userMessage))
        } catch is CancellationError {
          self.pendingCaptures.removeAll { $0.id == next.id }
        } catch {
          self.updatePendingPhase(next.id, .failed("无法保存这条链接，本地历史未发生变更。"))
        }
        self.activeCaptureID = nil
        self.activeCaptureTask = nil
      }
    }
  }

  /// 单条链接的完整捕获流程；由队列 worker 串行调用。
  private func performCapture(value: String, pendingID: UUID) async throws {
    guard let ingestor else { throw ManualLinkError.network }
    var capturedDocument: CapturedDocument?
    do {
      let document: CapturedDocument?
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if let xResolver, let tweetID = XTweetResolver.tweetID(from: trimmed) {
        // X 直抓只有 SPA 外壳；改用公开端点取回整条推文（正文/图片/视频直链）。
        guard let tweet = await xResolver.resolveTweet(id: tweetID) else {
          throw ManualLinkError.network
        }
        document = tweet.capturedDocument(createdAt: ISO8601DateFormatter().string(from: Date()))
      } else if let url = URL(string: trimmed),
                WeChatWebCapturePolicy.isCandidate(url) {
        document = try await weChatCapture.capture(url: url)
      } else if let url = URL(string: trimmed),
                DouyinURL.matches(url),
                let douyinCapture {
        do {
          document = try await captureService.capture(urlString: value)
        } catch ManualLinkError.extensionCaptureRequired {
          // Public Douyin HTML is often only a client-rendered shell. Keep the
          // public adapter first, then fall back to the App's isolated WebKit
          // session instead of saving shell chrome or making the user repeat
          // the same URL through the extension.
          document = try await douyinCapture.capture(url: url)
        }
      } else {
        document = try await captureService.capture(urlString: value)
      }
      guard let document else { return }
      capturedDocument = document
      try Task.checkCancellation()
      // Substantive WeChat articles keep their inline images even when they
      // also carry an embedded-video descriptor. Pure video captures do not.
      if RemoteMarkdownImageStagingPolicy.allows(document),
         let imageCache, let resources = imageResources {
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
      updatePendingPhase(pendingID, .saving)
      let accepted = try await ingestor.ingest(document)
      markClipboardURLHandled(value)
      // Signed media URLs must be downloaded in the same flow; never stored for later.
      if let media = document.media, let onMediaCaptured {
        // Pass page URL so CDN downloads can set a public Referer (no cookies).
        await onMediaCaptured(media, accepted.taskID, accepted.snapshotID, document.url)
      }
    } catch {
      if let capturedDocument { imageCache?.discardStaged(captureID: capturedDocument.requestID) }
      throw error
    }
  }

  func cancelFetch() { guard canCancelFetch else { return }; task?.cancel(); task = nil; state = .idle }
  func dismiss() {
    if isFetching { cancelFetch(); isPresented = false }
    else if !isSaving { isPresented = false }
  }
}
