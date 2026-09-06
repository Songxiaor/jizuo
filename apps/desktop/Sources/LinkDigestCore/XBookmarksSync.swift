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

  /// 入队抓取用的公开状态页。查重不能拿它做整串相等：落库几乎都是
  /// `https://x.com/{handle}/status/{id}`，这两种地址是同一条推文。
  public static func statusURLString(forTweetID id: String) -> String {
    "https://x.com/i/status/\(id)"
  }

  /// 从 x.com / twitter.com 的 status 地址取出数字 id。
  /// `/i/status/id` 与 `/user/status/id` 视为同一条。
  public static func tweetID(fromCanonicalURL rawURL: String) -> String? {
    guard let url = URL(string: rawURL),
          url.scheme?.lowercased() == "https",
          let rawHost = url.host?.lowercased()
    else { return nil }
    let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
    guard host == "x.com" || host == "twitter.com" else { return nil }
    let parts = url.pathComponents
    guard let marker = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }) else { return nil }
    let next = parts.index(after: marker)
    guard next < parts.endIndex else { return nil }
    return isValidTweetID(parts[next]) ? parts[next] : nil
  }
}

/// 勾选前查重：扩展把刚收集的 id 交给 App，问「本地历史里已有哪些」。
///
/// 仍不走 capture envelope。允许空列表（返回空 existingIDs），方便调用方省事。
public struct XBookmarksLookupRequest: Sendable, Equatable {
  public let version: Int
  public let requestId: String
  public let tweetIDs: [String]

  public init(version: Int, requestId: String, tweetIDs: [String]) {
    self.version = version
    self.requestId = requestId
    self.tweetIDs = tweetIDs
  }

  public static func decode(_ data: Data) throws -> XBookmarksLookupRequest? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let kind = object["kind"] as? String
    else { return nil }
    guard kind == "xBookmarksLookup" else { return nil }

    guard (object["version"] as? NSNumber)?.intValue == 1 else {
      throw CaptureValidationError.PROTOCOL_VERSION_UNSUPPORTED
    }
    guard let requestId = object["requestId"] as? String,
          !requestId.isEmpty, requestId.count <= 128
    else { throw CaptureValidationError.CAPTURE_SCHEMA_INVALID }
    guard let rawIDs = object["tweetIDs"] as? [Any] else {
      throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
    }
    guard rawIDs.count <= XBookmarksSyncRequest.maximumIDs else {
      throw CaptureValidationError.CAPTURE_PAYLOAD_TOO_LARGE
    }

    var seen = Set<String>()
    var ids: [String] = []
    for raw in rawIDs {
      guard let id = raw as? String, XBookmarksSyncRequest.isValidTweetID(id) else {
        throw CaptureValidationError.CAPTURE_SCHEMA_INVALID
      }
      if seen.insert(id).inserted { ids.append(id) }
    }
    return .init(version: 1, requestId: requestId, tweetIDs: ids)
  }
}
