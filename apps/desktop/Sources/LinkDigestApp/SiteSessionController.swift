import Foundation
import LinkDigestCore
import SwiftUI
import WebKit

/// App 自有的站点登录会话：隔离、持久、可随时清除。
///
/// - 每个站点一个独立的非 ephemeral `WKWebsiteDataStore`（重启后仍在）。
/// - Cookie 绝不写进 history SQLite、导出文件或日志。
/// - 必须用户显式登录；`clear()` 抹掉整个分区。
///
/// 站点差异全在 `SiteSessionProfile` 里，这个类不认识任何具体站点——加一个平台
/// 是加一份数据，不是复制一份控制器。
@MainActor
final class SiteSessionController: ObservableObject {
  /// 四个站点各有一个持久分区。分区 id 一经写入 UserDefaults 就不能换，否则已有登录态会变成孤儿。
  /// 主页导入和手动抓取都复用这些实例，不另开 ephemeral store，也不导入外部浏览器 Cookie。
  static let x = SiteSessionController(profile: .x)
  static let bilibili = SiteSessionController(profile: .bilibili)
  static let douyin = SiteSessionController(profile: .douyin)
  static let xiaohongshu = SiteSessionController(profile: .xiaohongshu)

  let profile: SiteSessionProfile

  @Published private(set) var isLoggedIn = false
  @Published private(set) var statusLabel = "未登录"
  /// 账号标识单独存一份，供状态徽章与主状态分两行显示。
  /// 不从 `statusLabel` 里切字符串——那等于把展示格式当数据结构用。
  @Published private(set) var accountDetail: String?
  @Published private(set) var lastError: String?
  /// 服务端是否真的认这个会话。
  ///
  /// `isLoggedIn` 只看本机 Cookie 在不在——存在不等于有效，也不等于它能穿过我们
  /// 自己的网络层送到站点。清晰度上不去时，必须先分清是「会话没被服务端认可」
  /// 还是「选流逻辑挑错了」，否则只能靠猜。
  @Published private(set) var verificationLabel: String?
  @Published private(set) var isVerifying = false

  /// 每次读取 cookie 的实测记录。只放数量和 cookie **名**，绝不放值。
  ///
  /// 加这个是因为「App 一关登录就失效」用读代码查不出来：磁盘上的凭据一直都在、
  /// 也没过期（B 站 SESSDATA 到 2027），分区 id 也稳定存在 UserDefaults 里，
  /// 每一环读起来都是通的，但设置页就是显示未登录。既然存储没问题，问题只能在
  /// 「读的那一刻拿到了什么」——必须让这个数字可见，否则只能继续猜。
  @Published private(set) var sessionDiagnostic: String?

  private var readCount = 0

  let dataStore: WKWebsiteDataStore
  var loginURL: URL { profile.loginURL }

  init(profile: SiteSessionProfile) {
    self.profile = profile
    let defaults = UserDefaults.standard
    let key = profile.dataStoreIDKey
    let uuid: UUID
    if let raw = defaults.string(forKey: key), let existing = UUID(uuidString: raw) {
      uuid = existing
    } else {
      uuid = UUID()
      defaults.set(uuid.uuidString, forKey: key)
    }
    dataStore = WKWebsiteDataStore(forIdentifier: uuid)
  }

  func refreshStatus() async {
    readCount += 1
    var all = await allCookies()
    var owned = all.filter { profile.ownsCookieDomain($0.domain) }
    let coldSiteCount = owned.count
    let coldAllCount = all.count

    // 第一次读不出本站 cookie 时，再给数据分区一次机会后重读。
    //
    // `WKWebsiteDataStore(forIdentifier:)` 的 cookie 由网络进程持有，而这个分区
    // 在冷启动后未必已经把磁盘上的内容加载进来。`fetchDataRecords` 会让分区落地，
    // 之后再读才是它真正持有的内容。这一步是只读的，拿不到就照旧报未登录。
    var warmedSiteCount: Int?
    if owned.isEmpty {
      await warmUpDataStore()
      all = await allCookies()
      owned = all.filter { profile.ownsCookieDomain($0.domain) }
      warmedSiteCount = owned.count
    }

    let cookies = SiteSessionCookieFilter.excludingExpired(owned)
    let expiredNames = Set(owned.map(\.name)).subtracting(Set(cookies.map(\.name)))
    let loggedIn = profile.looksLoggedIn(Set(cookies.map(\.name)))
    sessionDiagnostic = diagnosticLine(
      coldSiteCount: coldSiteCount,
      coldAllCount: coldAllCount,
      warmedSiteCount: warmedSiteCount,
      warmedAllCount: all.count,
      presentNames: Set(cookies.map(\.name)),
      expiredNames: expiredNames,
      loggedIn: loggedIn
    )
    isLoggedIn = loggedIn
    guard loggedIn else {
      statusLabel = "未登录"
      accountDetail = nil
      lastError = nil
      return
    }
    statusLabel = "登录已保存"
    if let name = profile.accountIDCookieName,
       let label = profile.accountIDLabel,
       let account = cookies.first(where: { $0.name == name })?.value,
       !account.isEmpty {
      accountDetail = "\(label) \(account)"
    } else {
      accountDetail = nil
    }
    lastError = nil
  }

  /// 业务请求用的 Cookie 头。绝不打印这个字符串。
  func cookieHeader() async -> String? {
    var cookies = SiteSessionCookieFilter.excludingExpired(await siteCookies())
    if !profile.looksLoggedIn(Set(cookies.map(\.name))) {
      await warmUpDataStore()
      cookies = SiteSessionCookieFilter.excludingExpired(await siteCookies())
    }
    guard profile.looksLoggedIn(Set(cookies.map(\.name))) else { return nil }
    let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    guard let header, !header.isEmpty else { return nil }
    return header
  }

  /// 用**与业务请求完全相同的 fetcher 和请求头**打一次登录态接口。
  /// 走同一条链路才有意义：如果 Cookie 在我们自己的网络层被丢掉，这里就会显示未认可。
  func verifySession() async {
    guard let verifier = profile.verifier else {
      verificationLabel = "该站点没有可用的登录态校验接口"
      return
    }
    isVerifying = true
    defer { isVerifying = false }
    guard let cookie = await cookieHeader() else {
      verificationLabel = "本机没有可用的登录 Cookie"
      return
    }
    verificationLabel = await verifier(cookie)
  }

  func clear() async {
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
      dataStore.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      dataStore.removeData(ofTypes: types, for: records) { continuation.resume() }
    }
    // removeData 不保证连 cookie 一起清干净，逐条删是唯一可靠的收尾。
    let cookies = await allCookies()
    for cookie in cookies {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
      }
    }
    isLoggedIn = false
    statusLabel = "未登录"
    accountDetail = nil
    verificationLabel = nil
    lastError = nil
  }

  private func siteCookies() async -> [HTTPCookie] {
    await allCookies().filter { profile.ownsCookieDomain($0.domain) }
  }

  /// 让 identifier 分区把磁盘上的内容落地。只读，不改动任何数据。
  private func warmUpDataStore() async {
    _ = await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
      dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) {
        continuation.resume(returning: $0)
      }
    }
  }

  /// 组装这次读取的可见记录。
  ///
  /// 判据是「缺哪几个名字」而不是「登录失败」：`looksLoggedIn` 是若干组名字的
  /// 子集判定，只说成功与否等于把唯一有用的信息扔掉——到底是一条都没读到，
  /// 还是读到了但少一个名字，修法完全不同。
  private func diagnosticLine(
    coldSiteCount: Int,
    coldAllCount: Int,
    warmedSiteCount: Int?,
    warmedAllCount: Int,
    presentNames: Set<String>,
    expiredNames: Set<String>,
    loggedIn: Bool
  ) -> String {
    var line = "读取 #\(readCount)：本站 \(coldSiteCount) 条（分区共 \(coldAllCount) 条）"
    if let warmedSiteCount {
      line += " → 预热后本站 \(warmedSiteCount) 条（分区共 \(warmedAllCount) 条）"
    }
    if !expiredNames.isEmpty {
      line += "；过期 \(expiredNames.sorted().joined(separator: "、"))"
    }
    if loggedIn {
      line += "；判定登录已保存"
      return line
    }
    // 取「最接近齐全」的那一组来报缺失：报所有组的并集会把 B 站
    // `SESSDATA` 与 `DedeUserID+bili_jct` 这种本就二选一的关系说成全都缺。
    let closest = profile.loginCookieGroups
      .filter { !$0.isEmpty }
      .min { $0.subtracting(presentNames).count < $1.subtracting(presentNames).count }
    if let missing = closest?.subtracting(presentNames), !missing.isEmpty {
      line += "；缺 \(missing.sorted().joined(separator: "、"))"
    } else {
      line += "；判定未登录"
    }
    return line
  }

  private func allCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
      dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
    }
  }
}

enum SiteSessionCookieFilter {
  /// 有过期时间且已经到期的丢掉；没有 `expiresDate` 的 session cookie 保留。
  /// 只看时间，不看、不返回 cookie 值。
  static func isUnexpired(expiresDate: Date?, now: Date = Date()) -> Bool {
    guard let expiresDate else { return true }
    return expiresDate > now
  }

  static func excludingExpired(_ cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
    cookies.filter { isUnexpired(expiresDate: $0.expiresDate, now: now) }
  }
}

// MARK: - Login WebView

struct SiteLoginWebView: NSViewRepresentable {
  let profile: SiteSessionProfile
  let dataStore: WKWebsiteDataStore
  let initialURL: URL
  var onNavigationFinished: (() -> Void)?
  var onExternalLogin: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(profile: profile, onNavigationFinished: onNavigationFinished, onExternalLogin: onExternalLogin)
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: config)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = true
    view.load(URLRequest(url: initialURL))
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.onNavigationFinished = onNavigationFinished
    context.coordinator.onExternalLogin = onExternalLogin
    if nsView.customUserAgent != SiteSessionProfile.browserUserAgent {
      nsView.customUserAgent = SiteSessionProfile.browserUserAgent
    }
  }

  /// WebKit 的 `WKNavigationDelegate` 整体以 `@MainActor` 暴露（`WK_SWIFT_UI_ACTOR`），
  /// 且 delegate 回调本来就由 WebKit 保证在主线程派发。标注 `@MainActor` 只是把这一
  /// 既有事实写进类型（与 `YouTubeEmbedNavigationDelegate` 同款），不改变运行行为。
  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let profile: SiteSessionProfile
    var onNavigationFinished: (() -> Void)?

    var onExternalLogin: (() -> Void)?

    init(profile: SiteSessionProfile, onNavigationFinished: (() -> Void)?, onExternalLogin: (() -> Void)?) {
      self.profile = profile
      self.onNavigationFinished = onNavigationFinished
      self.onExternalLogin = onExternalLogin
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      if profile.platform == .x, XExternalLoginPolicy.isProviderURL(navigationAction.request.url) {
        onExternalLogin?()
        decisionHandler(.cancel)
        return
      }
      // 白名单外不在内嵌网页打开。
      decisionHandler(profile.isAllowedHost(navigationAction.request.url?.host) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if profile.platform == .x, XExternalLoginPolicy.isProviderURL(navigationAction.request.url) {
        onExternalLogin?()
      } else if profile.isAllowedHost(navigationAction.request.url?.host) {
        webView.load(navigationAction.request)
      }
      return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigationFinished?()
    }
  }
}

enum XExternalLoginPolicy {
  static let loginURL = URL(string: "https://x.com/i/flow/login")!

  static func isProviderURL(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443 else { return false }
    return ["accounts.google.com", "appleid.apple.com"].contains(url.host?.lowercased() ?? "")
  }
}

struct SiteLoginSheet: View {
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var session: SiteSessionController
  @Environment(\.dismiss) private var dismiss
  @State private var refreshTask: Task<Void, Never>?
  @State private var browserLoginNotice: String?

  private func openBrowserLogin() {
    // Start X-owned login afresh in the browser; never export an embedded OAuth request or its state.
    let opened = NSWorkspace.shared.open(XExternalLoginPolicy.loginURL)
    browserLoginNotice = opened
      ? "已打开浏览器。登录 X 后，打开博主主页并点击汲作扩展读取作品；本窗口的登录状态不会因此改变。"
      : "未能打开默认浏览器，请检查系统默认浏览器设置后重试。"
  }

  private var siteName: String { session.profile.platform.displayName }
  private var idPrefix: String { session.profile.platform.rawValue }
  private var loginPurpose: String {
    switch session.profile.platform {
    case .x:
      "登录一次后，下次读取该站博主主页可复用本机会话。可随时在设置中清除。"
    case .bilibili:
      "登录一次后，下次读取该站博主主页可复用；也用于在本机获取更高清晰度的临时播放地址。可随时在设置中清除。"
    case .xiaohongshu:
      "登录一次后，下次读取该站博主主页可复用；也用于手动粘贴链接时读取登录后可见的正文。可随时在设置中清除。"
    case .douyin:
      "登录一次后，下次读取该站博主主页可复用。手动粘链接仍常失败，如果抓取失败，请改用浏览器扩展。可随时在设置中清除。"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("登录 \(siteName)").themedFont(.headline)
          Text(loginPurpose)
            .themedFont(.caption)
            .foregroundStyle(.secondary)
          if session.isLoggedIn {
            Text("右上角「登录已保存」表示本机仍有会话，可点完成；不表示站点一定还认。下方若仍提示浏览器过旧，关掉后重新打开即可。")
              .themedFont(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        Text(session.statusLabel)
          .themedFont(.caption)
          .foregroundStyle(session.isLoggedIn ? appTheme.success : Color.secondary)
          .accessibilityIdentifier("\(idPrefix)-login-status")
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("\(idPrefix)-login-done")
      }
      .padding(12)

      Divider()

      if session.profile.platform == .x {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text("使用 Google 或 Apple 登录？")
              .themedFont(.subheadline)
            Text(browserLoginNotice ?? "请在默认浏览器登录 X，再用汲作扩展读取博主主页。浏览器登录与本窗口独立。")
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Button("在浏览器中登录") { openBrowserLogin() }
            .accessibilityIdentifier("x-login-open-browser")
        }
        .padding(12)
        Divider()
      }

      SiteLoginWebView(
        profile: session.profile,
        dataStore: session.dataStore,
        initialURL: session.loginURL,
        onNavigationFinished: {
          refreshTask?.cancel()
          refreshTask = Task { await session.refreshStatus() }
        },
        onExternalLogin: { openBrowserLogin() }
      )
      .frame(minWidth: 720, minHeight: 520)

      Divider()

      HStack {
        Button("清除登录并关闭", role: .destructive) {
          Task {
            await session.clear()
            dismiss()
          }
        }
        .accessibilityIdentifier("\(idPrefix)-login-clear")
        Spacer()
        if session.isLoggedIn {
          Text("登录已保存，可关闭此窗口。")
            .themedFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
    .onAppear { Task { await session.refreshStatus() } }
    .onDisappear {
      refreshTask?.cancel()
      Task { await session.refreshStatus() }
    }
  }
}
