import Foundation

/// 扩展弹窗「打开汲作查看」：只请 Host 用同包 `.app` 路径唤起，不走 capture envelope。
///
/// 弹窗若用 `linkdigest://open` 交给 Launch Services 默认绑定，本机上残留的旧
/// 签名声明会把这条 URL 吞掉，正在跑的汲作也不会到前台。Host 已经能用绝对路径
/// `open` 同包 App，发送内容走的就是这条；打开按钮必须复用它。
public struct OpenAppRequest: Sendable, Equatable {
  public let version: Int
  public let requestId: String

  public init(version: Int, requestId: String) {
    self.version = version
    self.requestId = requestId
  }

  /// 返回 nil 表示「这不是打开 App 的消息」，调用方应继续按其它消息解析。
  /// 抛错表示「是这种消息但不合法」。
  public static func decode(_ data: Data) throws -> OpenAppRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String
    else { return nil }
    guard kind == "openApp" else { return nil }

    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    return OpenAppRequest(version: 1, requestId: requestId)
  }
}
