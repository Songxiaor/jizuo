import Foundation

/// 收藏夹同步请求：扩展只负责在页面上收集推文 id，正文由 App 用公开端点取。
///
/// 它刻意不复用 capture envelope——那套契约描述的是「一次页面捕获的完整结果」，
/// 而这里传的只是一串 id。走独立消息可以让 envelope 的 schema 保持冻结。
public struct XBookmarksSyncRequest: Sendable, Equatable {
  /// 单次同步的条数上限。收藏夹可能有几千条，一次性全塞进来既会撑爆消息体，
  /// 也会让端点侧的节流变得不可控；超出的部分留给下一次同步。
  public static let maximumIDs = 300

  public let version: Int
  public let requestId: String
  public let tweetIDs: [String]

  public init(version: Int, requestId: String, tweetIDs: [String]) {
    self.version = version
    self.requestId = requestId
    self.tweetIDs = tweetIDs
  }

  /// 返回 nil 表示「这不是收藏夹同步消息」，调用方应继续按 capture envelope 解析。
  /// 抛错表示「是这种消息但不合法」。
  public static func decode(_ data: Data) throws -> XBookmarksSyncRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String
    else { return nil }
    guard kind == "xBookmarks" else { return nil }

    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    guard let rawIDs = object["tweetIDs"] as? [Any] else {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    guard !rawIDs.isEmpty else { throw CaptureValidationError.CAPTURE_CONTENT_EMPTY }
    guard rawIDs.count <= maximumIDs else { throw CaptureValidationError.CAPTURE_PAYLOAD_TOO_LARGE }

    var seen = Set<String>()
    var ids: [String] = []
    for raw in rawIDs {
      guard let id = raw as? String, isValidTweetID(id) else {
        throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
      }
      // 收藏夹页面滚动时同一条可能被重复采到，去重后保持原顺序。
      if seen.insert(id).inserted { ids.append(id) }
    }
    return .init(version: 1, requestId: requestId, tweetIDs: ids)
  }

  public static func isValidTweetID(_ value: String) -> Bool {
    (8...25).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
