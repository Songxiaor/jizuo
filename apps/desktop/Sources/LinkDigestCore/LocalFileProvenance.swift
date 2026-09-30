import Foundation

/// 一个本地文件是从哪儿下载来的（2026-09-29）。
///
/// macOS 给下载来的文件留了两处记号，导入时读它们来判断归属：
/// - 扩展属性 `com.apple.quarantine`：`标志;十六进制时间;下载它的 App;事件 UUID`，
///   第三段就是 App 名（WeChat、Google Chrome、Safari…）。**有这个标记就判为外部。**
/// - Spotlight 的 `kMDItemWhereFroms`：下载网址，有时还带来源网页。只用来补充「从哪个网址来」。
///
/// 结果存进快照现有的 `source_label`（不改表），格式见 `sourceLabel`：
/// 列表、导出、搜索都直接用得上这段文字，阅读页题跋再把它解析回来。
public struct LocalFileProvenance: Sendable, Equatable {
  /// quarantine 第三段：下载它的 App 名，原样保留（WeChat 不在这里翻译，显示时再换成「微信」）。
  public let agentName: String?
  /// 下载网址或来源网页，只留 http(s)，去掉账号密码、下载链接上的签名参数。
  public let sourceURL: String?

  public init(agentName: String?, sourceURL: String?) {
    let agent = agentName?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.agentName = agent?.isEmpty == false ? agent : nil
    self.sourceURL = sourceURL.flatMap { Self.sanitizedURL($0, keepsQuery: true) }
  }

  // MARK: 读系统标记

  /// 解析 quarantine 属性值。不是 quarantine 格式（第一段不是十六进制标志）时返回 nil，
  /// 于是乱写的属性不会把条目误判成外部。
  public static func parseQuarantine(_ raw: String) -> (agentName: String?, downloadedAt: Date?)? {
    let fields = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
      .split(separator: ";", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let flags = fields.first, !flags.isEmpty, flags.count <= 8, UInt32(flags, radix: 16) != nil else {
      return nil
    }
    let date = fields.count > 1 ? UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
    let agent = fields.count > 2 ? fields[2] : ""
    return (agent.isEmpty ? nil : agent, date)
  }

  /// `kMDItemWhereFroms` 通常是 `[下载地址, 来源网页]`。来源网页更适合点开（下载地址多半
  /// 带时效签名、过期就打不开），有就用它；没有再退回下载地址，并去掉查询参数。
  public static func preferredWhereFrom(_ values: [String]) -> String? {
    if values.count > 1, let page = sanitizedURL(values[1], keepsQuery: true) { return page }
    if let download = values.first.flatMap({ sanitizedURL($0, keepsQuery: false) }) { return download }
    return nil
  }

  /// 只收 http(s)；去掉 `user:password@` 与片段；`keepsQuery == false` 时连查询串一起去掉
  /// （下载直链的查询串常是一次性签名，不该留在资料库和导出里）。
  public static func sanitizedURL(_ raw: String, keepsQuery: Bool) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 2_048, var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty
    else { return nil }
    components.user = nil
    components.password = nil
    components.fragment = nil
    if !keepsQuery { components.query = nil }
    guard let value = components.string, value.count <= 1_024 else { return nil }
    return value
  }

  // MARK: 存进 source_label

  /// 没有下载标记的本地文件：和改版前一样。
  public static let plainSourceLabel = "本地文件"
  private static let labelPrefix = "本地文件（"
  private static let labelSuffix = "）"
  private static let downloadedFrom = "下载自 "
  private static let unknownDownload = "外部下载"
  private static let urlSeparator = "："

  /// 例：`本地文件（下载自 WeChat）`、`本地文件（下载自 Google Chrome：https://example.com/a）`、
  /// `本地文件（下载自 https://example.com/a）`、`本地文件（外部下载）`。
  public var sourceLabel: String {
    let inner: String
    switch (agentName, sourceURL) {
    case let (agent?, url?): inner = Self.downloadedFrom + agent + Self.urlSeparator + url
    case let (agent?, nil): inner = Self.downloadedFrom + agent
    case let (nil, url?): inner = Self.downloadedFrom + url
    case (nil, nil): inner = Self.unknownDownload
    }
    return Self.labelPrefix + inner + Self.labelSuffix
  }

  /// `sourceLabel` 的反向解析。不是这个格式（包括普通的「本地文件」）时返回 nil。
  public static func parse(sourceLabel: String) -> LocalFileProvenance? {
    guard sourceLabel.hasPrefix(labelPrefix), sourceLabel.hasSuffix(labelSuffix),
          sourceLabel.count > labelPrefix.count + labelSuffix.count
    else { return nil }
    let inner = String(sourceLabel.dropFirst(labelPrefix.count).dropLast(labelSuffix.count))
    if inner == unknownDownload { return LocalFileProvenance(agentName: nil, sourceURL: nil) }
    guard inner.hasPrefix(downloadedFrom) else { return nil }
    let rest = String(inner.dropFirst(downloadedFrom.count))
    if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
      return LocalFileProvenance(agentName: nil, sourceURL: rest)
    }
    if let range = rest.range(of: urlSeparator + "http") {
      let agent = String(rest[..<range.lowerBound])
      let url = String(rest[rest.index(range.lowerBound, offsetBy: urlSeparator.count)...])
      return LocalFileProvenance(agentName: agent, sourceURL: url)
    }
    return LocalFileProvenance(agentName: rest, sourceURL: nil)
  }

  // MARK: 显示

  /// 下载它的 App 换成大家叫惯的名字：WeChat → 微信，AirDrop 的系统进程 sharingd → 隔空投送；其余用 App 名。
  public static func displayName(forAgent agent: String) -> String {
    switch agent.lowercased() {
    case "wechat", "微信", "weixin", "com.tencent.xinwechat": "微信"
    case "sharingd", "airdrop": "隔空投送"
    default: agent
    }
  }

  /// 题跋里「汲自 ___」的那个名字：App 名优先，其次网址的域名，都没有就说「网络下载」。
  public var displaySourceName: String {
    if let agentName { return Self.displayName(forAgent: agentName) }
    if let host = sourceURL.flatMap({ URLComponents(string: $0)?.host }) {
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    return "网络下载"
  }

  /// 导入结果里的一句来源：「微信下载」「Google Chrome 下载」「外部下载」。
  public var summaryLabel: String {
    guard agentName != nil || sourceURL != nil else { return Self.unknownDownload }
    return Self.joined(displaySourceName, "下载")
  }

  /// 可点开的来源网址。
  public var link: URL? { sourceURL.flatMap(URL.init(string:)) }

  /// 中文和拉丁字母之间补一个空格：「Chrome 下载」「汲自 Google Chrome」。
  public static func joined(_ head: String, _ tail: String) -> String {
    guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else { return head + tail }
    func isLatin(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) }
    return isLatin(last) != isLatin(first) ? head + " " + tail : head + tail
  }
}
