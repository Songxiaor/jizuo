import Foundation

/// 抓取偏好：评论抓几条（默认、按平台）、要不要自动保存。
///
/// 设置页写、Native Host 读。Host 是浏览器拉起的独立进程，读不到 App 的
/// `@AppStorage`，所以落一份小 JSON 到 Application Support，与
/// `BrowserDeliveryLog` 同一目录约定。文件缺失或损坏时一律按默认值。
public struct CapturePreferencesStore: Sendable {
  public static let commentLimitRange = 10...100
  public static let defaultCommentLimit = 20
  /// 设置页可选的档位。
  public static let commentLimitChoices = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

  private let fileURL: URL

  /// `root` 可注入：测试写 `/private/tmp` 的干净目录，不碰真人的设置。
  public init(root: URL) {
    self.fileURL = root
      .appendingPathComponent("Library/Application Support/LinkDigest", isDirectory: true)
      .appendingPathComponent("capture-preferences-v1.json", isDirectory: false)
  }

  public static func standard() -> CapturePreferencesStore {
    .init(root: FileManager.default.homeDirectoryForCurrentUser)
  }

  public static func clampedCommentLimit(_ value: Int) -> Int {
    min(commentLimitRange.upperBound, max(commentLimitRange.lowerBound, value))
  }

  /// 扩展认识的评论平台（键名与扩展 `CommentPlatform` 一致）和设置页上的名字。
  public static let commentPlatforms: [(key: String, title: String)] = [
    ("douyin", "抖音"), ("xiaohongshu", "小红书"), ("zhihu", "知乎"), ("bilibili", "B 站"),
    ("x", "X"), ("youtube", "YouTube"), ("reddit", "Reddit"), ("community", "论坛"),
  ]
  /// 按平台设成这个值表示「不抓评论」。
  public static let commentsDisabled = 0

  /// 默认条数：没有单独设的平台都按它。
  public var commentLimit: Int { Self.clampedCommentLimit(stored?.commentLimit ?? Self.defaultCommentLimit) }

  /// 按平台单独设的条数（2026-09-28 设置按工序重组）：没有的键跟随默认；0 表示不抓。
  public var commentLimitsByPlatform: [String: Int] {
    (stored?.commentLimits ?? [:]).compactMapValues { value in
      value == Self.commentsDisabled ? value : Self.clampedCommentLimit(value)
    }
  }

  /// 抓取时直接保存前几条，不在扩展里逐条勾选。旧文件没有这一项时按「每次勾选」。
  public var autoSaveComments: Bool { stored?.autoSaveComments ?? false }

  public func setCommentLimit(_ value: Int) throws {
    try update { $0.commentLimit = Self.clampedCommentLimit(value) }
  }

  /// `value` 为 nil 表示这个平台改回「跟随默认」。
  public func setCommentLimit(_ value: Int?, forPlatform platform: String) throws {
    try update { stored in
      var limits = stored.commentLimits ?? [:]
      if let value {
        limits[platform] = value == Self.commentsDisabled ? value : Self.clampedCommentLimit(value)
      } else {
        limits.removeValue(forKey: platform)
      }
      stored.commentLimits = limits.isEmpty ? nil : limits
    }
  }

  public func setAutoSaveComments(_ value: Bool) throws {
    try update { $0.autoSaveComments = value }
  }

  /// 新内容进来后会自动做的工序（`record` `proof` `comments` `summary` `translation` `mindMap`）。
  /// App 在设置变化时写进来，Host 读给扩展弹窗点亮工序印（2026-09-29 弹窗重构）。
  /// nil 表示 App 还没写过（旧版本），扩展按「不知道」处理。
  public var autoSteps: [String]? { stored?.autoSteps }

  public func setAutoSteps(_ steps: [String]) throws {
    let known = Set(Self.processStepKeys)
    let cleaned = Self.processStepKeys.filter { steps.contains($0) && known.contains($0) }
    guard cleaned != autoSteps else { return }
    try update { $0.autoSteps = cleaned }
  }

  /// 工序键名，和扩展、App 的 ProcessStep.rawValue 一致。
  public static let processStepKeys = ["record", "proof", "comments", "summary", "translation", "mindMap"]

  private var stored: Stored? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(Stored.self, from: data)
  }

  private func update(_ change: (inout Stored) -> Void) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var value = stored ?? Stored(commentLimit: Self.defaultCommentLimit)
    change(&value)
    try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
  }

  /// 新字段都是可选的：旧版写的文件只有 commentLimit，照样读得出。
  private struct Stored: Codable {
    var commentLimit: Int
    var commentLimits: [String: Int]?
    var autoSaveComments: Bool?
    var autoSteps: [String]?
  }
}

/// 扩展弹窗打开时问一次「评论抓几条」。Host 自己读偏好文件作答，不需要 App 在运行。
public struct CapturePreferencesRequest: Sendable, Equatable {
  public let requestId: String

  /// 返回 nil 表示「不是这类消息」，调用方继续按其它消息解析；抛错表示是但不合法。
  public static func decode(_ data: Data) throws -> CapturePreferencesRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String,
      kind == "getCapturePreferences"
    else { return nil }
    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    return CapturePreferencesRequest(requestId: requestId)
  }
}
