import Foundation

/// App「添加链接」在隐藏网页里跑扩展同一份 `extract-page.js` 时的纯逻辑部分：
/// 读脚本、拼执行体、把结果按扩展的放行规则变成入库文档。
///
/// 为什么要这条路（2026-10-02 抓取完整度测试）：App 原来自己下载 HTML、用正则挑正文，
/// 挑错区块（arena.ai 只存下推荐卡）、一律删图、不认前端渲染的页面。扩展在真实网页里
/// 跑 DOM 提取，同一篇文章两条路结果差一个数量级。现在两条路共用一份提取实现，
/// 修一处两边都好；区别只剩「登录状态来自浏览器还是来自站点登录」。
public enum RenderedPageExtraction {
  /// 随 App 打包的提取脚本（扩展构建产物的副本，见 scripts/sync-contracts.sh）。
  /// YouTube 观看页用 `extract-youtube.js`（字幕、简介），其余用 `extract-page.js`。
  public static func extractorScript(for url: URL) -> String? {
    let name = isYouTubeWatch(url) ? "extract-youtube" : "extract-page"
    guard let resource = CoreResourceBundle.resolved()?
      .url(forResource: name, withExtension: "js", subdirectory: "browser-scripts")
    else { return nil }
    return try? String(contentsOf: resource, encoding: .utf8)
  }

  /// YouTube 的脚本要读页面自己的播放器数据，得在页面主世界里跑。
  public static func isYouTubeWatch(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if host == "youtu.be" { return true }
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
    return url.path == "/watch" || url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/live/")
  }

  /// 给 `callAsyncJavaScript` 的函数体：跑提取脚本，返回 JSON 字符串。
  ///
  /// 脚本源码直接放进函数体，不经过 `eval`：YouTube 这类启用 Trusted Types 的页面会拒绝
  /// `eval`（「Refused to evaluate a string as JavaScript」），App 里的 YouTube 因此拿不到
  /// 字幕（2026-10-02 实测）。打包产物是 `var 名字=(function(){…})();`，取那个变量的结果。
  public static func functionBody(script: String) -> String {
    guard let match = script.range(of: #"^var ([A-Za-z_$][A-Za-z0-9_$]*)="#, options: .regularExpression) else {
      return """
      const result = await (0, eval)(\(CommentCapture.javaScriptStringLiteral(script)));
      return JSON.stringify(result ?? null);
      """
    }
    let name = script[match].dropFirst(4).dropLast()
    return script + "\nreturn JSON.stringify((await \(name)) ?? null);"
  }

  /// 整次抓取和提取脚本各最多等多久。YouTube 要打开「文字记录」面板、等字幕加载并稳定，
  /// 常要 30 秒以上；原来一律 30 秒，超时就整条退回直读，只剩简介没有字幕（2026-10-02 实测 9 次里 3 次）。
  public static func timeBudget(for url: URL) -> (overall: Duration, script: Duration) {
    isYouTubeWatch(url) ? (.seconds(110), .seconds(55)) : (.seconds(75), .seconds(30))
  }

  /// 等页面稳定：每半秒量一次正文字数，连续两次不变才算好，最多 8 秒。
  /// 前端渲染的站点在加载完成后还会重绘正文，中途有一段时间页面里只剩推荐卡片——
  /// arena.ai 在 App 里因此时好时坏，一次 1.7 万字、一次 774 字（2026-10-02 实测）。
  public static let settleBody = """
    let last = -1, stable = 0;
    for (let i = 0; i < 16; i++) {
      const size = ((document.body && document.body.innerText) || "").length;
      if (size > 0 && size === last) { stable += 1; if (stable >= 2) break; } else { stable = 0; }
      last = size;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    return last;
    """

  /// 第一次提取后是否值得隔一会儿再取一次：字很少（可能撞上重绘空档），
  /// 或 YouTube 还没读到字幕（播放器、文字记录面板加载得慢）。
  public static func shouldRetry(_ document: CapturedDocument, url: URL) -> Bool {
    if document.characterCount < 2_000 { return true }
    return isYouTubeWatch(url) && !hasTranscript(document)
  }

  /// 慢慢滚到底再回顶：懒加载的图片只有进过视口才会换上真地址。
  public static let lazyLoadScrollBody = """
    const height = () => (document.scrollingElement || document.documentElement).scrollHeight;
    for (let y = 0; y < height() && y < 60000; y += 800) {
      window.scrollTo(0, y);
      await new Promise((resolve) => setTimeout(resolve, 120));
    }
    window.scrollTo(0, 0);
    return true;
    """

  /// 共用提取结果里的正文（去掉它自带的 frontmatter），给已有专门流程的来源换上
  /// 扩展同款的正文排版。字数明显少于原流程时返回 nil，由调用方保留原结果。
  public static func sharedBody(json: String, comparedTo existing: String) -> String? {
    guard let data = json.data(using: .utf8),
          let payload = try? JSONDecoder().decode(Payload.self, from: data),
          payload.captureIssue == nil,
          let text = payload.text
    else { return nil }
    let body = MarkdownNoteFrontmatter.parse(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
    let plain = { (value: String) in value.filter { !$0.isWhitespace }.count }
    guard plain(body) * 10 >= plain(existing) * 8 else { return nil }
    return body
  }

  struct Payload: Decodable {
    let title: String?
    let url: String?
    let text: String?
    let platform: String?
    let completeness: String?
    let captureIssue: String?
    let captionTrackCount: Int?
  }

  /// YouTube 提取结果里播放器的字幕轨数：0 = 视频本来就没有字幕，nil = 不知道。
  public static func captionTrackCount(json: String) -> Int? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONDecoder().decode(Payload.self, from: data))?.captionTrackCount
  }

  /// 存下的视频正文里有没有字幕段。
  public static func hasTranscript(_ document: CapturedDocument) -> Bool {
    document.text.contains("## 字幕")
  }

  /// YouTube 最终没拿到字幕时保存后的提示：视频本来没有字幕就直说；有字幕却没取到，告诉用户怎么重来。
  public static func missingTranscriptNotice(captionTrackCount: Int?) -> String {
    captionTrackCount == 0
      ? "这个视频本身没有字幕，只存了标题和简介。"
      : "已保存，但这次没拿到字幕，只存了标题和简介。稍后可以再添加一次这个链接，选「仍要重新保存」。"
  }

  /// 扩展 `captureSendBlockReason` 的同一套放行规则：登录墙、应用外壳、只有导航这三种
  /// 「软问题」在正文已有 200 字以上时照样保存（标成只含可见内容），其余一律拦下。
  public static func document(
    json: String,
    requestedURL: URL,
    now: Date = Date()
  ) throws -> CapturedDocument {
    guard let data = json.data(using: .utf8),
          let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { throw ManualLinkError.invalidPageResult }
    let text = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let characterCount = text.count
    var completeness = payload.completeness ?? "full_article"
    if let issue = payload.captureIssue {
      let soft: Set<String> = ["CAPTURE_LOGIN_WALL", "CAPTURE_APP_SHELL", "CAPTURE_NAVIGATION_ONLY"]
      guard soft.contains(issue), characterCount >= 200 else { throw error(for: issue) }
      completeness = payload.completeness ?? "visible_only"
    }
    guard characterCount >= 20 else { throw ManualLinkError.emptyContent }
    let pageURL = payload.url.flatMap(URL.init(string:)) ?? requestedURL
    if isLoginRedirect(from: requestedURL, to: pageURL) { throw ManualLinkError.loginRequired }
    if VerificationPagePolicy.matches(url: pageURL, extractedText: text) {
      throw ManualLinkError.verificationRequired
    }
    let platform = payload.platform ?? CapturePlatformDetection.platform(from: pageURL)
    let timestamp = ISO8601DateFormatter().string(from: now)
    let document = CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual-rendered:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: pageURL.absoluteString,
      title: payload.title,
      platform: platform,
      method: "rendered_dom",
      text: text,
      completeness: completeness,
      capturedAt: timestamp,
      sourceLabel: "手动链接（App 内置网页）"
    )
    do {
      try CapturedDocumentValidator.validate(document)
    } catch let failure as CapturedDocumentValidationError {
      switch failure {
      case .emptyContent: throw ManualLinkError.emptyContent
      case .contentTooLarge: throw ManualLinkError.responseTooLarge
      case .invalidURL, .countMismatch, .invalidTimestamp: throw ManualLinkError.invalidPageResult
      }
    }
    return document
  }

  /// 要的是一篇内容，最后却停在登录页（知乎未登录时跳 /signin，2026-10-02 实测）。
  public static func isLoginRedirect(from requested: URL, to final: URL) -> Bool {
    func isLoginPath(_ url: URL) -> Bool {
      let path = url.path.lowercased()
      let first = url.pathComponents.dropFirst().first?.lowercased() ?? ""
      return ["signin", "login", "signup", "passport", "sso"].contains(first)
        || path.contains("/flow/login") || path.contains("/account/login") || path.hasPrefix("/website-login")
    }
    return isLoginPath(final) && !isLoginPath(requested)
  }

  static func error(for issue: String) -> ManualLinkError {
    switch issue {
    case "CAPTURE_LOGIN_WALL": .loginRequired
    case "CAPTURE_SECURITY_CHALLENGE": .verificationRequired
    case "CAPTURE_PAGE_LOAD_FAILED": .responseStatus
    default: .emptyContent
    }
  }
}
