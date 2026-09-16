import AppKit
import Foundation
import LinkDigestCore

/// 抓取成败的本地计数。
///
/// 用户报「最近老是失败」的时候，我们既看不到他的历史库，也不该看。这个文件是
/// 唯一的替代品：只记「哪个平台、成功多少次、失败时是什么错误码」，不记 URL、
/// 不记标题、不记正文。它小到可以整份贴进诊断导出里。
struct CaptureOutcomeCounts: Codable, Equatable, Sendable {
  struct PlatformCounts: Codable, Equatable, Sendable {
    var succeeded: Int = 0
    /// 错误码 → 次数。错误码是跨版本唯一稳定的东西，所以按它分桶。
    var failed: [String: Int] = [:]

    var failedTotal: Int { failed.values.reduce(0, +) }
  }

  var version: Int = 1
  var updatedAt: String = ""
  var platforms: [String: PlatformCounts] = [:]

  var totalSucceeded: Int { platforms.values.reduce(0) { $0 + $1.succeeded } }
  var totalFailed: Int { platforms.values.reduce(0) { $0 + $1.failedTotal } }
}

/// `diagnostics/capture-outcomes.json` 的读写。
///
/// 写入是同步的：这份文件只有几百字节，而抓取路径上本来就在写 SQLite，
/// 再多一次小文件写不构成新的风险；换成异步反而让「导出时看到的计数」变成
/// 一个时序问题。
final class CaptureOutcomeStore: @unchecked Sendable {
  static let fileName = "capture-outcomes.json"

  private let lock = NSLock()
  private let directoryURL: URL
  private let now: @Sendable () -> Date

  init(applicationSupportRoot: URL, now: @escaping @Sendable () -> Date = Date.init) {
    directoryURL = applicationSupportRoot
      .appendingPathComponent("LinkDigest", isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true)
    self.now = now
  }

  var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

  func recordSuccess(platform: String) {
    mutate { counts in
      let key = Self.safeToken(platform, fallback: "unknown")
      counts.platforms[key, default: .init()].succeeded += 1
    }
  }

  func recordFailure(platform: String, code: String) {
    mutate { counts in
      let key = Self.safeToken(platform, fallback: "unknown")
      let errorCode = Self.safeToken(code, fallback: "UNKNOWN")
      counts.platforms[key, default: .init()].failed[errorCode, default: 0] += 1
    }
  }

  func snapshot() -> CaptureOutcomeCounts {
    lock.withLock { readUnlocked() }
  }

  /// 只在用户明确要求重置时用；诊断导出不会触发它。
  func reset() {
    lock.withLock { try? FileManager.default.removeItem(at: fileURL) }
  }

  private func mutate(_ body: (inout CaptureOutcomeCounts) -> Void) {
    lock.withLock {
      var counts = readUnlocked()
      body(&counts)
      counts.version = 1
      counts.updatedAt = ISO8601DateFormatter().string(from: now())
      guard let data = try? JSONEncoder().encode(counts) else { return }
      do {
        try FileManager.default.createDirectory(
          at: directoryURL, withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
      } catch {
        // 计数写不进去不该影响抓取本身。只留一行日志（不含路径）。
        AppLog.error(.storage, "capture_outcome_write_failed", code: "DIAGNOSTICS_COUNTER_WRITE_FAILED")
      }
    }
  }

  private func readUnlocked() -> CaptureOutcomeCounts {
    guard let data = try? Data(contentsOf: fileURL),
          let counts = try? JSONDecoder().decode(CaptureOutcomeCounts.self, from: data)
    else { return CaptureOutcomeCounts() }
    return counts
  }

  /// 平台名和错误码都来自内部枚举，但仍然过一次白名单：万一哪天有人把
  /// 用户输入接到这里，也不会把一段正文写进计数文件的键里。
  static func safeToken(_ raw: String, fallback: String) -> String {
    let filtered = raw.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
    }
    let value = String(String.UnicodeScalarView(filtered))
    guard !value.isEmpty else { return fallback }
    return String(value.prefix(64))
  }
}

extension CaptureOutcomeStore {
  /// 生产路径上唯一的那一份。
  ///
  /// 单元测试里返回 nil：计数文件落在用户真实的 Application Support 里，
  /// 跑测试不该往那儿写。需要验证读写的测试自己传临时目录。
  static let shared: CaptureOutcomeStore? = {
    guard NSClassFromString("XCTestCase") == nil else { return nil }
    guard let root = try? AppApplicationSupportRoot.resolve() else { return nil }
    return CaptureOutcomeStore(applicationSupportRoot: root)
  }()
}

/// 诊断信息的正文组装。与界面无关，便于直接测试。
enum DiagnosticsReport {
  struct Environment: Sendable {
    var appName: String
    var shortVersion: String
    var buildVersion: String
    var systemVersion: String
    /// 当前模型服务的显示名，例如「DeepSeek · deepseek-chat」。绝不含密钥。
    var modelServiceDisplayName: String
  }

  static let logPredicate = "subsystem == \"\(AppLog.subsystem)\""
  static let logWindow = "2h"

  static func compose(
    environment: Environment,
    counts: CaptureOutcomeCounts,
    logText: String,
    generatedAt: Date = Date()
  ) -> String {
    var lines: [String] = []
    lines.append("汲作 诊断信息")
    lines.append("这份文件不包含你保存的正文、网址、密钥或 Cookie。")
    lines.append("")
    lines.append("生成时间：\(ISO8601DateFormatter().string(from: generatedAt))")
    lines.append("应用：\(environment.appName) \(environment.shortVersion)（内部版本 \(environment.buildVersion)）")
    lines.append("系统：\(environment.systemVersion)")
    lines.append("当前模型服务：\(environment.modelServiceDisplayName)")
    lines.append("")
    lines.append("== 抓取成败计数 ==")
    if counts.platforms.isEmpty {
      lines.append("暂无记录。")
    } else {
      lines.append("合计：成功 \(counts.totalSucceeded) 次，失败 \(counts.totalFailed) 次")
      for platform in counts.platforms.keys.sorted() {
        let entry = counts.platforms[platform] ?? .init()
        var line = "\(platform)：成功 \(entry.succeeded)，失败 \(entry.failedTotal)"
        if !entry.failed.isEmpty {
          let detail = entry.failed.keys.sorted().map { "\($0) × \(entry.failed[$0] ?? 0)" }
          line += "（\(detail.joined(separator: "，"))）"
        }
        lines.append(line)
      }
    }
    lines.append("")
    lines.append("== 最近 \(logWindow) 运行日志 ==")
    lines.append(logText.isEmpty ? "没有取到日志。" : logText)
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// 读取最近两小时、只属于汲作的系统日志。
  ///
  /// 走 `log show` 而不是自己维护一份文件：系统日志本来就在收，自己再写一份
  /// 只会多一个可能泄漏正文的落盘点。这里只取汲作自己的 subsystem。
  static func recentLogText(
    window: String = logWindow,
    timeoutSeconds: TimeInterval = 20
  ) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show",
      "--predicate", logPredicate,
      "--last", window,
      "--style", "compact",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return "无法读取系统日志（log show 启动失败）。"
    }

    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeoutSeconds, execute: watchdog
    )
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    watchdog.cancel()

    let text = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "最近 \(window) 内没有汲作的日志记录。" : text
  }

  /// 从 UserDefaults 里那份**非敏感**的服务档案推出显示名。
  ///
  /// 走这条路而不是 Keychain：显示名不需要密钥，读密钥只会白白弹一次钥匙串授权。
  /// 档案里存的 `secretReference` 是一个 UUID 指针，不是密钥本身，也不会被写进来。
  static func modelServiceDisplayName(
    defaults: UserDefaults = .standard,
    storageKey: String = "com.syc.linkdigest.provider-profile"
  ) -> String {
    guard let data = defaults.data(forKey: storageKey),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "未配置" }
    let baseURL = object["baseURL"] as? String ?? ""
    let model = object["model"] as? String ?? ""
    let preset = ProviderPreset.allCases.first { $0.baseURLTemplate == baseURL }
    let providerName = preset.map { $0 == .custom ? AppLog.host(baseURL) : $0.displayName }
      ?? AppLog.host(baseURL)
    let safeModel = AppLog.redact(model)
    return safeModel.isEmpty ? providerName : "\(providerName) · \(safeModel)"
  }

  static func liveEnvironment(bundle: Bundle = .main) -> Environment {
    let info = bundle.infoDictionary
    return Environment(
      appName: ProductDisplay.name,
      shortVersion: info?["CFBundleShortVersionString"] as? String ?? "—",
      buildVersion: info?["CFBundleVersion"] as? String ?? "—",
      systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      modelServiceDisplayName: modelServiceDisplayName()
    )
  }

  static func suggestedFileName(generatedAt: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "汲作诊断-\(formatter.string(from: generatedAt)).txt"
  }
}

/// 「反馈问题」按钮的 mailto 组装。地址与正文都不含任何用户数据。
enum FeedbackMail {
  /// 支持邮箱。
  ///
  /// 写在这里而不是 `config/app-release.json`：那个文件压在三层发布完整性门禁上——
  /// `release_unit.py` 要求它的 key 集合**精确匹配**，而 `local-test-release.json`
  /// 又钉着它、`release_unit.py`、`release_unit_check.py` 三个文件的 sha256。
  /// 为一个邮箱去重签三份冻结件，风险（错一处整个 release unit 被拒）远大于收益。
  ///
  /// 将来真要走配置时不用改这里：`address(releaseConfiguration:)` 的优先级已经
  /// 留好了——传进来的配置优先，这个常量只负责兜底。
  static let supportAddress = "Syc7232@gmail.com"

  static func address(releaseConfiguration: [String: Any]?) -> String {
    let candidate = releaseConfiguration?["supportEmail"] as? String
    guard let candidate, candidate.contains("@"), !candidate.hasSuffix("@") else {
      return supportAddress
    }
    return candidate
  }

  static func subject(environment: DiagnosticsReport.Environment) -> String {
    "汲作反馈 \(environment.shortVersion)"
  }

  static func body(environment: DiagnosticsReport.Environment) -> String {
    [
      "（请在这里描述遇到的问题，以及出现问题前你做了什么。）",
      "",
      "——以下信息帮助我们定位，请保留——",
      "应用：\(environment.appName) \(environment.shortVersion)（内部版本 \(environment.buildVersion)）",
      "系统：\(environment.systemVersion)",
    ].joined(separator: "\n")
  }

  static func mailtoURL(
    address: String,
    environment: DiagnosticsReport.Environment
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = address
    components.queryItems = [
      URLQueryItem(name: "subject", value: subject(environment: environment)),
      URLQueryItem(name: "body", value: body(environment: environment)),
    ]
    return components.url
  }

  /// Gmail 网页版写伩页（`view=cm&fs=1` 是它公开的撰写入口参数）。
  static func webComposeURL(
    address: String,
    environment: DiagnosticsReport.Environment
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "mail.google.com"
    components.path = "/mail/"
    components.queryItems = [
      URLQueryItem(name: "view", value: "cm"),
      URLQueryItem(name: "fs", value: "1"),
      URLQueryItem(name: "to", value: address),
      URLQueryItem(name: "su", value: subject(environment: environment)),
      URLQueryItem(name: "body", value: body(environment: environment)),
    ]
    return components.url
  }

  /// 「写邮件…」应该交给谁。
  ///
  /// 不能无条件用 `mailto:`：macOS 允许**浏览器**注册成 `mailto:` 的默认处理器
  /// （装浏览器时很常见），而它对这个 scheme 通常无能为力 —— `NSWorkspace.open`
  /// 返回 true（进程确实被拉起来了），浏览器却打开一片空白，用户看到的就是
  /// 「点了一下，浏览器开了，什么也没发生」。
  ///
  /// 判据不用维护浏览器名单：**同一个 App 既处理 mailto 又处理 https，就当它是
  /// 浏览器**，改走网页版写伩入口（主题与正文照样带上版本信息）。
  enum ComposeTarget: Equatable {
    case mailClient(URL)
    case webMail(URL)
    case none
  }

  static func composeTarget(
    address: String,
    environment: DiagnosticsReport.Environment,
    handlerIsWebBrowser: Bool = defaultHandlerIsWebBrowser()
  ) -> ComposeTarget {
    if !handlerIsWebBrowser, let url = mailtoURL(address: address, environment: environment) {
      return .mailClient(url)
    }
    if let url = webComposeURL(address: address, environment: environment) {
      return .webMail(url)
    }
    if let url = mailtoURL(address: address, environment: environment) {
      return .mailClient(url)
    }
    return .none
  }

  /// 本机 `mailto:` 的默认处理器是不是一个浏览器。
  static func defaultHandlerIsWebBrowser() -> Bool {
    let workspace = NSWorkspace.shared
    guard let mailtoProbe = URL(string: "mailto:probe@example.invalid"),
          let webProbe = URL(string: "https://example.invalid"),
          let mailtoHandler = workspace.urlForApplication(toOpen: mailtoProbe),
          let webHandler = workspace.urlForApplication(toOpen: webProbe)
    else { return false }
    return mailtoHandler == webHandler
  }
}

/// 设置页按钮背后的动作。
@MainActor
enum DiagnosticsExportAction {
  enum Result: Equatable {
    case cancelled
    case saved(URL)
    case failed(String)
  }

  static func exportWithSavePanel(
    counts: CaptureOutcomeCounts,
    environment: DiagnosticsReport.Environment = DiagnosticsReport.liveEnvironment(),
    logText: @Sendable () -> String = { DiagnosticsReport.recentLogText() }
  ) -> Result {
    let panel = NSSavePanel()
    panel.title = "导出诊断信息"
    panel.message = "这份文件不包含你保存的正文、网址和密钥。"
    panel.nameFieldStringValue = DiagnosticsReport.suggestedFileName()
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

    let text = DiagnosticsReport.compose(
      environment: environment,
      counts: counts,
      logText: logText()
    )
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      AppLog.info(.storage, "diagnostics_exported", ["bytes": String(text.utf8.count)])
      return .saved(url)
    } catch {
      AppLog.error(.storage, "diagnostics_export_failed", code: "DIAGNOSTICS_EXPORT_WRITE_FAILED")
      return .failed("写入失败，请换一个位置再试。")
    }
  }
}
