import Foundation
import LinkDigestAdapters
import LinkDigestCore
import SwiftUI
import WebKit

/// Persistent, isolated B 站 login session for high-quality stream refresh.
///
/// - Uses a dedicated non-ephemeral `WKWebsiteDataStore` (survives app relaunch).
/// - Cookies are never written to history SQLite, exports, or logs.
/// - User must sign in explicitly; `clear()` wipes the store.
@MainActor
final class BilibiliSiteSessionController: ObservableObject {
  static let shared = BilibiliSiteSessionController()

  /// Stable store id so relaunch reuses the same WebKit data partition.
  private static let dataStoreIDKey = "linkdigest.site-session.bilibili.data-store-id"
  private static let loginLandingURL = URL(string: "https://passport.bilibili.com/login")!

  @Published private(set) var isLoggedIn = false
  @Published private(set) var statusLabel = "未登录"
  @Published private(set) var lastError: String?
  /// 服务端是否真的认这个会话。
  ///
  /// `isLoggedIn` 只看本机 Cookie 里有没有 `SESSDATA` / `DedeUserID`——存在不等于有效，
  /// 也不等于它能穿过我们自己的网络层送到 B 站。清晰度上不去时，必须先分清是
  /// 「会话没被服务端认可」还是「选流逻辑挑错了」，否则只能靠猜。
  @Published private(set) var verificationLabel: String?
  @Published private(set) var isVerifying = false

  let dataStore: WKWebsiteDataStore
  let loginURL: URL = BilibiliSiteSessionController.loginLandingURL

  private init() {
    let defaults = UserDefaults.standard
    let uuid: UUID
    if let raw = defaults.string(forKey: Self.dataStoreIDKey),
       let existing = UUID(uuidString: raw) {
      uuid = existing
    } else {
      uuid = UUID()
      defaults.set(uuid.uuidString, forKey: Self.dataStoreIDKey)
    }
    dataStore = WKWebsiteDataStore(forIdentifier: uuid)
  }

  /// Hosts the login WebView may navigate to (no free browsing).
  static func isAllowedHost(_ host: String?) -> Bool {
    guard var host = host?.lowercased(), !host.isEmpty else { return false }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if host.hasPrefix("m.") { host = String(host.dropFirst(2)) }
    let allowedSuffixes = [
      "bilibili.com",
      "bilibili.cn",
      "bilivideo.com",
      "hdslb.com",
      "biliapi.net",
      "biliapi.com",
    ]
    return allowedSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  func refreshStatus() async {
    let cookies = await allBilibiliCookies()
    let loggedIn = Self.looksLoggedIn(cookies)
    isLoggedIn = loggedIn
    if loggedIn {
      let name = cookies.first(where: { $0.name == "DedeUserID" })?.value
      if let name, !name.isEmpty {
        statusLabel = "已登录（UID \(name)）"
      } else {
        statusLabel = "已登录"
      }
    } else {
      statusLabel = "未登录"
    }
    lastError = nil
  }

  /// Cookie header for `api.bilibili.com` playurl requests. Never log this string.
  func cookieHeader() async -> String? {
    let cookies = await allBilibiliCookies()
    guard Self.looksLoggedIn(cookies) else { return nil }
    let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    guard let header, !header.isEmpty else { return nil }
    return header
  }

  /// 用**与刷新播放地址完全相同的 fetcher 和请求头**打一次登录态接口。
  /// 走同一条链路才有意义：如果 Cookie 在我们自己的网络层被丢掉，这里就会显示未认可。
  /// 只读取 `isLogin` / 会员等级，不打印任何 Cookie 值。
  func verifySession() async {
    isVerifying = true
    defer { isVerifying = false }
    guard let cookie = await cookieHeader() else {
      verificationLabel = "本机没有可用的登录 Cookie"
      return
    }
    guard let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return }
    let fetcher = ProxyAwareWebPageFetcher()
    do {
      let response = try await fetcher.fetchResource(
        .init(
          url: endpoint,
          headers: [
            "Accept": "application/json",
            "User-Agent": Self.browserUserAgent,
            "Referer": "https://www.bilibili.com/",
            "Cookie": cookie,
          ],
          byteLimit: 256 * 1024,
          allowsRedirectTarget: { target in
            let host = target.host?.lowercased() ?? ""
            return host == "api.bilibili.com" || host.hasSuffix(".bilibili.com")
          }
        )
      )
      guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
        verificationLabel = "无法解析返回内容（HTTP \(response.statusCode)）"
        return
      }
      let data = root["data"] as? [String: Any]
      let isLogin = (data?["isLogin"] as? Bool) ?? false
      guard isLogin else {
        // code=-101 是「账号未登录」。Cookie 存在但服务端不认：过期，或没送达。
        let code = root["code"] as? Int ?? -1
        verificationLabel = "服务端不认可这个会话（code \(code)）——高清档不会解锁"
        return
      }
      let vipStatus = (data?["vipStatus"] as? Int) ?? 0
      let vipType = ((data?["vip"] as? [String: Any])?["type"] as? Int) ?? 0
      let vip = vipStatus == 1
        ? (vipType >= 2 ? "年度大会员" : "大会员")
        : "非大会员"
      verificationLabel = "服务端已认可 · \(vip)"
    } catch {
      verificationLabel = "校验请求失败：\(error)"
    }
  }

  private static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  func clear() async {
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
      dataStore.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      dataStore.removeData(ofTypes: types, for: records) {
        continuation.resume()
      }
    }
    let cookies = await allCookies()
    for cookie in cookies {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        dataStore.httpCookieStore.delete(cookie) {
          continuation.resume()
        }
      }
    }
    isLoggedIn = false
    statusLabel = "未登录"
    lastError = nil
  }

  static func looksLoggedIn(_ cookies: [HTTPCookie]) -> Bool {
    let names = Set(cookies.map(\.name))
    // SESSDATA is the primary session cookie; DedeUserID is a stable companion.
    return names.contains("SESSDATA") || (names.contains("DedeUserID") && names.contains("bili_jct"))
  }

  private func allBilibiliCookies() async -> [HTTPCookie] {
    let all = await allCookies()
    return all.filter { cookie in
      let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return domain == "bilibili.com"
        || domain.hasSuffix(".bilibili.com")
        || domain == "bilibili.cn"
        || domain.hasSuffix(".bilibili.cn")
        || domain.hasSuffix("hdslb.com")
        || domain.hasSuffix("biliapi.net")
        || domain.hasSuffix("biliapi.com")
    }
  }

  private func allCookies() async -> [HTTPCookie] {
    await withCheckedContinuation { continuation in
      dataStore.httpCookieStore.getAllCookies { cookies in
        continuation.resume(returning: cookies)
      }
    }
  }
}

// MARK: - Login WebView

struct BilibiliLoginWebView: NSViewRepresentable {
  /// B 站会按 UA 拦截「版本过低」页；WKWebView 默认 Safari UA 常被当成过时浏览器。
  /// 与远程播放请求共用现代 Chrome UA，避免登录页被挡。
  static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  let dataStore: WKWebsiteDataStore
  let initialURL: URL
  var onNavigationFinished: (() -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(onNavigationFinished: onNavigationFinished)
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: config)
    view.customUserAgent = Self.browserUserAgent
    view.navigationDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = true
    view.load(URLRequest(url: initialURL))
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.onNavigationFinished = onNavigationFinished
    if nsView.customUserAgent != Self.browserUserAgent {
      nsView.customUserAgent = Self.browserUserAgent
    }
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var onNavigationFinished: (() -> Void)?

    init(onNavigationFinished: (() -> Void)?) {
      self.onNavigationFinished = onNavigationFinished
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      let host = navigationAction.request.url?.host
      if BilibiliSiteSessionController.isAllowedHost(host) {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigationFinished?()
    }
  }
}

struct BilibiliLoginSheet: View {
  @ObservedObject var session: BilibiliSiteSessionController
  @Environment(\.dismiss) private var dismiss
  @State private var refreshTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("登录 B 站").font(.headline)
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
          .accessibilityIdentifier("bilibili-login-status")
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("bilibili-login-done")
      }
      .padding(12)

      Divider()

      BilibiliLoginWebView(
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
        .accessibilityIdentifier("bilibili-login-clear")
        Spacer()
        if session.isLoggedIn {
          Text("已检测到登录，可关闭此窗口。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
    .onAppear {
      Task { await session.refreshStatus() }
    }
    .onDisappear {
      refreshTask?.cancel()
      Task { await session.refreshStatus() }
    }
  }
}
