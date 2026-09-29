import Foundation

/// 扩展弹窗问「这一页存过没有、做到哪了」（2026-09-29 弹窗重构）。
///
/// 打开弹窗时问一次（查重），保存后再按同一个地址轮询（看进度）。只读历史，不写库，
/// Host 只在 App 已经在运行时转发，不会为了它把 App 拉起来。
public struct PageStatusRequest: Sendable, Equatable {
  public static let maximumURLLength = 4_096
  public let requestId: String
  public let url: String

  /// 返回 nil 表示「不是这类消息」；抛错表示是但不合法。
  public static func decode(_ data: Data) throws -> PageStatusRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String,
      kind == "pageStatus"
    else { return nil }
    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    guard let url = object["url"] as? String,
          url.count <= maximumURLLength,
          let parsed = URL(string: url),
          ["http", "https"].contains(parsed.scheme?.lowercased())
    else { throw CaptureValidationError.CAPTURE_URL_UNSUPPORTED }
    return PageStatusRequest(requestId: requestId, url: url)
  }
}

/// 一道工序在这条内容上的状态。没列出来的工序 = 还没做。
public struct PageStepStatus: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable {
    case done, running, failed
  }

  /// 与 `CapturePreferencesStore.processStepKeys` 同一套键名。
  public let step: String
  public let state: State
  /// 一句短说明：「存了 20 条」「DeepSeek v4 Flash」「转写中」。可选。
  public let detail: String?

  public init(step: String, state: State, detail: String? = nil) {
    self.step = step
    self.state = state
    self.detail = detail
  }
}

public struct PageStatusPayload: Codable, Sendable, Equatable {
  public let found: Bool
  public let taskID: String?
  public let savedAtMilliseconds: Int64?
  public let steps: [PageStepStatus]

  public init(found: Bool, taskID: String? = nil, savedAtMilliseconds: Int64? = nil, steps: [PageStepStatus] = []) {
    self.found = found
    self.taskID = taskID
    self.savedAtMilliseconds = savedAtMilliseconds
    self.steps = steps
  }

  public static let notFound = PageStatusPayload(found: false)
}
