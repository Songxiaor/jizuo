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
  /// B 站是目前唯一有真实消费者的站点：`SessionMediaRefreshService` 用它刷新
  /// 高清播放地址。其余平台的 profile 在有消费者之前不建实例，避免设置页出现
  /// 点了不产生任何效果的登录入口。
  static let bilibili = SiteSessionController(profile: .bilibili)
  /// 这两个的消费端是手动链接抓取：未登录时服务端只返回登录墙 / 风控页。
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
    let cookies = await siteCookies()
    let loggedIn = profile.looksLoggedIn(Set(cookies.map(\.name)))
    isLoggedIn = loggedIn
    guard loggedIn else {
      statusLabel = "未登录"
      accountDetail = nil
      lastError = nil
      return
    }
    let account = profile.accountIDCookieName.flatMap { name in
      cookies.first(where: { $0.name == name })?.value
    }
    if let account, !account.isEmpty, let label = profile.accountIDLabel {
      statusLabel = "已登录（\(label) \(account)）"
      accountDetail = "\(label) \(account)"
    } else {
      statusLabel = "已登录"
      accountDetail = nil
    }
    lastError = nil
  }

  /// 业务请求用的 Cookie 头。绝不打印这个字符串。
  func cookieHeader() async -> String? {
    let cookies = await siteCookies()
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

  private func allCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
      dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
    }
  }
}

// MARK: - Login WebView

struct SiteLoginWebView: NSViewRepresentable {
  let profile: SiteSessionProfile
  let dataStore: WKWebsiteDataStore
  let initialURL: URL
  var onNavigationFinished: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(profile: profile, onNavigationFinished: onNavigationFinished)
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: config)
    view.customUserAgent = SiteSessionProfile.browserUserAgent
    view.navigationDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = true
    view.load(URLRequest(url: initialURL))
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.onNavigationFinished = onNavigationFinished
    if nsView.customUserAgent != SiteSessionProfile.browserUserAgent {
      nsView.customUserAgent = SiteSessionProfile.browserUserAgent
    }
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    let profile: SiteSessionProfile
    var onNavigationFinished: (() -> Void)?

    init(profile: SiteSessionProfile, onNavigationFinished: (() -> Void)?) {
      self.profile = profile
      self.onNavigationFinished = onNavigationFinished
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // 这是这个 WebView 唯一的边界：白名单外一律取消，避免它变成自由浏览器。
      decisionHandler(profile.isAllowedHost(navigationAction.request.url?.host) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigationFinished?()
    }
  }
}

struct SiteLoginSheet: View {
  @ObservedObject var session: SiteSessionController
  @Environment(\.dismiss) private var dismiss
  @State private var refreshTask: Task<Void, Never>?

  private var siteName: String { session.profile.platform.displayName }
  private var idPrefix: String { session.profile.platform.rawValue }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("登录 \(siteName)").font(.headline)
          Text("仅用于在本机获取更高清晰度的临时播放地址。可随时在设置中清除。")
            .font(.caption)
            .foregroundStyle(.secondary)
          if session.isLoggedIn {
            Text("右上角「已登录」表示本机已有会话 Cookie，可直接点完成；下方若仍提示浏览器过旧，关掉后重新打开「登录」即可刷新页面。")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        Text(session.statusLabel)
          .font(.caption)
          .foregroundStyle(session.isLoggedIn ? .green : .secondary)
          .accessibilityIdentifier("\(idPrefix)-login-status")
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("\(idPrefix)-login-done")
      }
      .padding(12)

      Divider()

      SiteLoginWebView(
        profile: session.profile,
        dataStore: session.dataStore,
        initialURL: session.loginURL,
        onNavigationFinished: {
          refreshTask?.cancel()
          refreshTask = Task { await session.refreshStatus() }
        }
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
          Text("已检测到登录，可关闭此窗口。")
            .font(.caption)
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
