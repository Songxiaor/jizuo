import CryptoKit
import Foundation
import LinkDigestCore

/// A small, host-keyed cache for history-list favicons.
///
/// The cache only receives resources through `SafeResourceFetching`, so every
/// request still passes the same URL admission, peer/TLS and redirect checks
/// as page capture. It is deliberately best-effort: a failed favicon can never
/// fail a captured document, a run, or history loading.
public final class WebsiteFaviconCache: @unchecked Sendable {
  public static let perHostByteLimit = 64 * 1024
  public static let maximumCachedHosts = 128
  public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
  /// A host which does not serve a safe, supported favicon should not hold up
  /// every history reload. Keep that negative result local for one day, then
  /// permit a retry in case the site has fixed its icon.
  public static let negativeCacheTTL: TimeInterval = 24 * 60 * 60

  private let root: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private let lock = NSLock()

  public init(
    applicationSupportRoot: URL,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/WebsiteFavicons", isDirectory: true)
    self.fileManager = fileManager
    self.now = now
  }

  /// Returns a cached local file, if present. No remote URL is ever returned
  /// to SwiftUI.
  public func localImageURL(for sourceURL: URL) -> URL? {
    guard let key = Self.cacheKey(for: sourceURL) else { return nil }
    let file = root.appendingPathComponent(key, isDirectory: false)
    lock.lock()
    defer { lock.unlock() }
    guard fileManager.fileExists(atPath: file.path) else { return nil }
    try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
    return file
  }

  /// Fetches at most one 64 KiB favicon for a previously captured host.
  /// Redirects may leave the original host (icons are commonly served from a
  /// CDN); the transport separately validates every redirect URL and actual
  /// network peer, and only verified image bytes are ever written to disk.
  public func localImageURL(
    fetchingIfNeededFor sourceURL: URL,
    resources: any SafeResourceFetching
  ) async -> URL? {
    if let cached = localImageURL(for: sourceURL) { return cached }
    guard let key = Self.cacheKey(for: sourceURL),
          let sourceHost = PublicWebURLPolicy.normalizedHost(sourceURL.host ?? "")
    else { return nil }
    if hasFreshNegativeCache(for: key) { return nil }

    // 本站拿不到就退到注册域。
    //
    // 实测 support.claude.com 的 /favicon.ico 返回 200 但**零字节**，而
    // claude.com/favicon.ico 有 15086 字节的正常图标。这不是个例：帮助中心、
    // 文档站、博客常挂在 support./help./docs./blog. 这类子域上，图标只在主域有。
    // 只剥一层标签，且要求剩余部分仍是可注册域，避免把 foo.co.uk 削成 co.uk。
    var response: SafeResourceResponse?
    for host in Self.faviconHostChain(from: sourceHost) {
      guard let faviconURL = Self.faviconURL(host: host) else { continue }
      guard let candidate = try? await resources.fetchResource(.init(
        url: faviconURL,
        headers: ["Accept": "image/x-icon,image/vnd.microsoft.icon,image/png,image/*;q=0.8"],
        byteLimit: Self.perHostByteLimit,
        allowsRedirectTarget: Self.isSafeIconLocation
      )),
        (200...299).contains(candidate.statusCode),
        candidate.body.count <= Self.perHostByteLimit,
        Self.isSafeIconLocation(candidate.url),
        Self.isSupportedImage(candidate)
      else { continue }
      response = candidate
      break
    }

    // 猜路径全失败时，回到页面自己声明的地址。
    //
    // 声明的图标常挂在 CDN 上（和页面不同域），所以这一条不能沿用 same-host 守卫。
    // 安全性由别处兜住：URL 仍走 PublicWebURLPolicy、有字节上限、且必须通过
    // magic bytes 校验才会落盘——放宽的只是「必须同域」这一条。
    if response == nil {
      response = await fetchDeclaredIcon(pageURL: sourceURL, resources: resources)
    }

    guard let response else {
      recordNegativeCache(for: key)
      return nil
    }

    return store(response, for: key)
  }

  /// Fetches the icon URL observed by the browser on the captured page.
  ///
  /// Protected sites can return a challenge/robot shell to the App's separate
  /// HTTP request even though the user-visible page contains a valid
  /// `<link rel="icon">`. This candidate crosses the wire only as a URL; it
  /// never bypasses the normal public-URL, redirect, peer/TLS, byte-limit or
  /// image-magic checks. A successful browser declaration intentionally
  /// supersedes a previous `.miss` marker for the same source host.
  public func localImageURL(
    fetchingBrowserDeclaredURL declaredURL: URL,
    for sourceURL: URL,
    resources: any SafeResourceFetching
  ) async -> URL? {
    if let cached = localImageURL(for: sourceURL) { return cached }
    guard let key = Self.cacheKey(for: sourceURL),
          Self.isSafeIconLocation(declaredURL),
          let response = try? await resources.fetchResource(.init(
            url: declaredURL,
            headers: ["Accept": "image/png,image/x-icon,image/svg+xml,image/*;q=0.8"],
            byteLimit: Self.perHostByteLimit,
            allowsRedirectTarget: Self.isSafeIconLocation
          )),
          (200...299).contains(response.statusCode),
          response.body.count <= Self.perHostByteLimit,
          Self.isSafeIconLocation(response.url),
          Self.isSupportedImage(response)
    else { return nil }
    return store(response, for: key)
  }

  /// All sources for one host share the same on-disk icon. The URL that won
  /// may live on a CDN, but the key remains the captured page's original host.
  private func store(_ response: SafeResourceResponse, for key: String) -> URL? {
    lock.withLock {
      guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
      let destination = root.appendingPathComponent(key, isDirectory: false)
      guard (try? response.body.write(to: destination, options: .atomic)) != nil else {
        recordNegativeCacheLocked(for: key)
        return nil
      }
      try? fileManager.removeItem(at: negativeCacheURL(for: key))
      try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
      pruneLocked()
      return destination
    }
  }

  /// The source scheme and host are retained; userinfo, query and fragment are
  /// discarded. PublicWebURLPolicy will still re-admit this URL at transport
  /// time, including for records created by older app versions.
  /// 抓一次页面 HTML，按它声明的图标地址逐个尝试。
  ///
  /// 只在猜路径全失败后才走这里：多一次 HTML 请求，不该让大多数正常站点也付这个钱。
  private func fetchDeclaredIcon(
    pageURL: URL,
    resources: any SafeResourceFetching
  ) async -> SafeResourceResponse? {
    guard let page = try? await resources.fetchResource(.init(
      url: pageURL,
      headers: ["Accept": "text/html,application/xhtml+xml"],
      byteLimit: Self.htmlByteLimit,
      allowsRedirectTarget: { _ in true }
    )),
      (200...299).contains(page.statusCode),
      let html = String(data: Data(page.body), encoding: .utf8)
        ?? String(data: Data(page.body), encoding: .isoLatin1)
    else { return nil }

    let candidates = Self.declaredIconURLs(inHTML: html, baseURL: page.url)
    for candidate in candidates.prefix(Self.maximumDeclaredIconAttempts) {
      guard let response = try? await resources.fetchResource(.init(
        url: candidate,
        headers: ["Accept": "image/png,image/x-icon,image/svg+xml,image/*;q=0.8"],
        byteLimit: Self.perHostByteLimit,
        allowsRedirectTarget: { _ in true }
      )),
        (200...299).contains(response.statusCode),
        response.body.count <= Self.perHostByteLimit,
        Self.isSupportedImage(response)
      else { continue }
      return response
    }
    return nil
  }

  /// 页面 HTML 的抓取上限。
  ///
  /// 原来是 256 KB，注释写着「只读 head 够用的量」——这个假设被真实站点推翻了：
  /// `www.databricks.com` 的博客页整页 722 KB，而 `<link rel="icon">` 出现在第
  /// 533,361 个字符（前面全是内联脚本与 JSON）。截断在 256 KB 意味着那 9 条图标
  /// 声明从头到尾没被看见过，图标只能回落到首字母方块。
  ///
  /// 一个 host 的图标最多每 30 天取一次（失败也有 24 小时负缓存），为此多读几百 KB
  /// 是划算的；仍保留硬上限，避免真正失控的页面把内存吃掉。
  private static let htmlByteLimit = 1024 * 1024
  /// 一页里声明四五个尺寸很常见，试太多等于为一个图标打一串请求。
  private static let maximumDeclaredIconAttempts = 5

  /// 列表里的图标只有 20pt 见方（视网膜屏约 40px）。
  ///
  /// 所以「越大越好」是错的：512×512 的 PNG 实测 197 KB，既超 64 KiB 缓存上限，
  /// 拿到了也只是被缩到 20pt。按与这个尺寸的接近程度排，才会挑中真正合用的那张
  /// ——databricks 那张 32×32 的只有 914 字节。
  static let preferredIconPixelSize = 64
  /// `<link rel="icon">` 不写 sizes 时的惯例尺寸。当作 32 处理，而不是当作 0 排到
  /// 最后——不写 sizes 的往往正是那张最标准的小图标。
  private static let assumedIconPixelSize = 32

  /// 从页面 HTML 里读出它自己声明的图标地址。
  ///
  /// 猜 `/favicon.ico` 在真实站点上有两种常见坏法，实测都撞到了：
  /// - `support.claude.com` 返回 200 但**零字节**；
  /// - `www.residentialvps.com` 返回 200 但 content-type 是 `text/html`——
  ///   SPA 把所有未知路径都回首页，退到注册域也是同一份 HTML。
  ///
  /// 站点自己在 `<link rel="icon">` 里声明的地址才是权威来源。
  ///
  /// 按「与列表显示尺寸的接近程度」排序，不是按大小降序。降序排会先试 512×512
  /// 那种上百 KB 的图，连着几次撞上缓存上限，把有限的尝试次数全耗光，而真正合用
  /// 的小图标排在最后一个永远轮不到。
  static func declaredIconURLs(inHTML html: String, baseURL: URL) -> [URL] {
    let pattern = #"<link\b[^>]*\brel\s*=\s*["']([^"']*)["'][^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    // 扫到 </head> 为止：正文里的 <link> 不是图标声明。
    //
    // 原来是固定截前 20 万字符，这在 head 本身就超过 20 万字符的站点上等于什么都
    // 没扫到（databricks 的图标声明在第 53 万字符）。用真实的 head 边界，既不会
    // 漏掉靠后的声明，也不会把整篇正文卷进来。
    let scope: String = {
      if let headEnd = html.range(of: "</head>", options: [.caseInsensitive]) {
        return String(html[html.startIndex..<headEnd.lowerBound])
      }
      return html
    }()
    var found: [(url: URL, side: Int, isVector: Bool)] = []
    for match in regex.matches(in: scope, range: NSRange(scope.startIndex..., in: scope)) {
      guard let tagRange = Range(match.range, in: scope),
            let relRange = Range(match.range(at: 1), in: scope)
      else { continue }
      let rel = scope[relRange].lowercased()
      guard rel.split(separator: " ").contains(where: {
        $0 == "icon" || $0 == "shortcut" || $0 == "apple-touch-icon"
          || $0 == "apple-touch-icon-precomposed"
      }) else { continue }
      let tag = String(scope[tagRange])
      guard let href = attribute("href", in: tag), !href.isEmpty,
            let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
            let scheme = resolved.scheme?.lowercased(), ["http", "https"].contains(scheme),
            resolved.user == nil, resolved.password == nil
      else { continue }
      let declared = attribute("sizes", in: tag)
        .flatMap { $0.lowercased().split(separator: "x").first.flatMap { Int($0) } }
      // 矢量图没有像素尺寸，任何显示尺寸下都清晰，按最合适处理。
      let isVector = attribute("type", in: tag)?.lowercased().contains("svg") == true
        || resolved.pathExtension.lowercased() == "svg"
      let side = isVector ? preferredIconPixelSize : (declared ?? assumedIconPixelSize)
      found.append((resolved, side, isVector))
    }
    // 去重保序：同一个地址被 icon 和 apple-touch-icon 同时声明很常见。
    var seen = Set<String>()
    return found
      .sorted(by: isBetterIcon)
      .compactMap { seen.insert($0.url.absoluteString).inserted ? $0.url : nil }
  }

  /// 取「不小于显示尺寸的最小那张」，同档位图优先于矢量。
  ///
  /// 两个方向都会出问题，所以不能简单地按大小排：
  /// - 一味求大：512×512 实测 197 KB，超 64 KiB 缓存上限直接被丢，白费一次尝试；
  /// - 一味求小：16×16 拉到 40px 显示是糊的。
  ///
  /// 够用的里面挑最小的，既清晰又省流量。一张都不够大时退而取其中最大的——糊总比
  /// 没有强。
  ///
  /// **同档时位图优先**：矢量图没有像素尺寸，上面按 `preferredIconPixelSize` 给它
  /// 记了个「正好够用」，于是它总排在够用组的最前——但那个假定只说明它清晰，
  /// **完全没说明它有多大**。实测 earendil.com 声明的第一个图标是一张 4.6 MB 的
  /// SVG（同目录下的 apple-touch-icon 只有 49 KB），每次抓取都先去撞一次 64 KiB
  /// 上限才轮到下一个：白费一次请求，也把整条链路的失败窗口拉长。位图的字节数和
  /// 声明的尺寸大致成正比，是可预测的那一个，同档就该先试它。
  ///
  /// 矢量图仍然保留在候选里——只提供 SVG 的站点靠它才不至于回落到首字母方块。
  private static func isBetterIcon(
    _ lhs: (url: URL, side: Int, isVector: Bool),
    _ rhs: (url: URL, side: Int, isVector: Bool)
  ) -> Bool {
    let lhsSufficient = lhs.side >= preferredIconPixelSize
    let rhsSufficient = rhs.side >= preferredIconPixelSize
    if lhsSufficient != rhsSufficient { return lhsSufficient }
    if lhsSufficient, lhs.isVector != rhs.isVector { return !lhs.isVector }
    return lhsSufficient ? lhs.side < rhs.side : lhs.side > rhs.side
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
      options: [.caseInsensitive]
    ), let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
      let range = Range(match.range(at: 1), in: tag)
    else { return nil }
    return String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 依次尝试的 host：本站，然后（若存在）注册域。
  ///
  /// 只剥一层标签。剥更多会滑向公共后缀（`a.b.co.uk` → `co.uk`），那是一个
  /// 别人的域，抓它的图标既不对也不该。判据是「剩余部分至少两段，且不是已知的
  /// 多段有效顶级域」——不引公共后缀表的前提下，这条足够保守。
  static func faviconHostChain(from host: String) -> [String] {
    var chain = [host]
    if let parent = registrableParent(of: host) { chain.append(parent) }
    return chain
  }

  /// 常见的多段有效顶级域。命中就说明再剥一层会越过注册边界。
  private static let multiLabelSuffixes: Set<String> = [
    "co.uk", "org.uk", "ac.uk", "gov.uk",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "com.au", "net.au", "org.au",
    "co.jp", "or.jp", "ne.jp", "ac.jp",
    "com.hk", "com.tw", "com.sg", "com.br", "com.mx",
    "co.kr", "co.in", "co.nz", "co.za",
  ]

  private static func registrableParent(of host: String) -> String? {
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count >= 3 else { return nil }
    let parent = labels.dropFirst().joined(separator: ".")
    // 剥完只剩「有效顶级域」本身，说明原 host 已经是注册域，不能再退。
    guard parent.split(separator: ".").count >= 2,
          !multiLabelSuffixes.contains(parent)
    else { return nil }
    return parent
  }

  /// 猜 `/favicon.ico` 这条路上，一个地址是否还值得继续跟下去。
  ///
  /// 原来这里额外要求**必须同域**，实测把一整类站点判死了：`www.douyin.com/favicon.ico`
  /// 返回 302 跳到 `lf1-cdn-tos.bytegoofy.com`，那是一张 4286 字节的标准 ICO，却因为
  /// 跨域被丢掉。而抖音的页面 HTML 是 SPA 外壳——`</head>` 出现在第 36 个字节、零个
  /// `<link rel="icon">`，所以退到「读页面声明」那条路同样无路可走。两条路被同一个
  /// 盲点堵死，结果就是永远回落到首字母方块。
  ///
  /// 把图标托管在 CDN 上是主流做法，同域要求会持续误伤。放宽的只是「必须同域」这一
  /// 条，理由和读页面声明那条路完全一致：URL 仍走 `PublicWebURLPolicy`、有 64 KiB
  /// 字节上限、且必须通过 magic bytes 校验才会落盘。凭据、非 http(s) 协议和非标准
  /// 端口照旧拒绝——那几条挡的是别的东西，不能一起放掉。
  static func isSafeIconLocation(_ candidate: URL) -> Bool {
    guard candidate.user == nil, candidate.password == nil,
          let scheme = candidate.scheme?.lowercased(), ["http", "https"].contains(scheme),
          (scheme == "http" && (candidate.port == nil || candidate.port == 80)) ||
            (scheme == "https" && (candidate.port == nil || candidate.port == 443)),
          let host = PublicWebURLPolicy.normalizedHost(candidate.host ?? ""), !host.isEmpty
    else { return false }
    return true
  }

  static func faviconURL(host: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/favicon.ico"
    return components.url
  }

  public static func faviconURL(for sourceURL: URL) -> URL? {
    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          components.user == nil, components.password == nil,
          let host = PublicWebURLPolicy.normalizedHost(components.host ?? ""), !host.isEmpty,
          (scheme == "http" && (components.port == nil || components.port == 80)) ||
            (scheme == "https" && (components.port == nil || components.port == 443))
    else { return nil }
    var favicon = components
    favicon.scheme = scheme
    favicon.host = host
    favicon.user = nil
    favicon.password = nil
    favicon.path = "/favicon.ico"
    favicon.query = nil
    favicon.fragment = nil
    return favicon.url
  }

  private static func cacheKey(for sourceURL: URL) -> String? {
    guard let host = PublicWebURLPolicy.normalizedHost(sourceURL.host ?? ""), !host.isEmpty else { return nil }
    return SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSupportedImage(_ response: SafeResourceResponse) -> Bool {
    isSupportedImage(contentType: response.contentType, body: response.body)
  }

  /// 内容类型 + magic bytes 的纯判断。
  ///
  /// 抽出来是为了能直接测：这是「图标为什么没出现」最容易出错的一环，而构造一个
  /// 完整的 `SafeResourceResponse` 只为断言几个字节头并不划算。
  /// **以字节为准，Content-Type 只当提示。**
  ///
  /// 原来是「按声明的类型选一套 magic bytes 去校验」，于是任何标错类型的站点都被
  /// 判死。实测 `x.com/favicon.ico` 声明 `image/x-icon`，字节头却是
  /// `89 50 4E 47`——一张标准 PNG。同类还有不发 Content-Type、或一律发
  /// `application/octet-stream` 的 CDN。认头不认字节，等于把这些站点全部放弃。
  ///
  /// 反过来以字节为准既更宽也更严：只接受确实是已知图片格式的内容，服务器怎么说
  /// 都不影响判断，把 HTML 错标成图片那种坏法照样挡得住。
  static func isSupportedImage(contentType: String?, body: Data) -> Bool {
    if hasRasterImageMagicBytes(body) { return true }
    return looksLikeSVG(body)
  }

  private static func hasRasterImageMagicBytes(_ body: Data) -> Bool {
    if body.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return true }  // PNG
    if body.starts(with: [0xff, 0xd8, 0xff]) { return true }                                 // JPEG
    if body.starts(with: Array("GIF87a".utf8)) || body.starts(with: Array("GIF89a".utf8)) { return true }
    if body.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }                           // ICO
    if body.count >= 12,
       body.starts(with: Array("RIFF".utf8)),
       Data(body.dropFirst(8).prefix(4)) == Data("WEBP".utf8) { return true }
    // AVIF：`....ftypavif`。越来越多站点用它，NSImage 在 macOS 13+ 能解。
    if body.count >= 12,
       Data(body.dropFirst(4).prefix(4)) == Data("ftyp".utf8),
       Data(body.dropFirst(8).prefix(4)) == Data("avif".utf8) { return true }
    return false
  }

  /// SVG 是文本，没有 magic bytes，只能按内容判。
  ///
  /// 现在大量站点只提供 SVG 图标，不认它等于对这些站点永远回落到首字母方块。
  /// NSImage 能直接解码 SVG（本机 macOS 26 实测通过）。
  ///
  /// 必须同时排除 HTML：猜路径那条路上实测遇到过 SPA 把任意未知路径都回首页，
  /// 那份 HTML 里也可能内嵌 `<svg>`，只查 `<svg` 会把整张首页当图标存下来。
  private static func looksLikeSVG(_ body: Data) -> Bool {
    guard let text = String(data: Data(body.prefix(4096)), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    else { return false }
    guard !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html") else { return false }
    return text.hasPrefix("<svg") || (text.hasPrefix("<?xml") && text.contains("<svg"))
  }

  private func negativeCacheURL(for key: String) -> URL {
    root.appendingPathComponent("\(key).miss", isDirectory: false)
  }

  private func hasFreshNegativeCache(for key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let marker = negativeCacheURL(for: key)
    guard fileManager.fileExists(atPath: marker.path) else { return false }
    let date = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    guard date.addingTimeInterval(Self.negativeCacheTTL) > now() else {
      try? fileManager.removeItem(at: marker)
      return false
    }
    return true
  }

  private func recordNegativeCache(for key: String) {
    lock.lock()
    defer { lock.unlock() }
    recordNegativeCacheLocked(for: key)
  }

  private func recordNegativeCacheLocked(for key: String) {
    guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return }
    let marker = negativeCacheURL(for: key)
    guard fileManager.createFile(atPath: marker.path, contents: Data()) else { return }
    try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: marker.path)
    pruneLocked()
  }

  /// Cleanup is cache-only: on each successful write, discard entries unused
  /// for 30 days and then evict oldest files until 128 hosts remain. Task
  /// deletion does not remove a shared host favicon, so another history item
  /// can continue to reuse it.
  private func prune() {
    lock.lock()
    defer { lock.unlock() }
    pruneLocked()
  }

  private func pruneLocked() {
    guard let files = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let deadline = now().addingTimeInterval(-Self.retentionInterval)
    var retained: [String: (urls: [URL], latestDate: Date)] = [:]
    for file in files {
      let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      if date < deadline { try? fileManager.removeItem(at: file) }
      else {
        let name = file.lastPathComponent
        let key = name.hasSuffix(".miss") ? String(name.dropLast(5)) : name
        var entry = retained[key] ?? ([], .distantPast)
        entry.urls.append(file)
        entry.latestDate = max(entry.latestDate, date)
        retained[key] = entry
      }
    }
    for (_, entry) in retained.sorted(by: { $0.value.latestDate < $1.value.latestDate }).dropLast(Self.maximumCachedHosts) {
      for file in entry.urls { try? fileManager.removeItem(at: file) }
    }
  }
}
