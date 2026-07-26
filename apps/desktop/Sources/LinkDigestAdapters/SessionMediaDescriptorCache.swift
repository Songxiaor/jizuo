import Foundation
import LinkDigestCore

/// Process-only LRU of refreshed streaming descriptors.
/// Capacity bounds memory; eviction forces the next open to re-fetch.
/// Never writes to disk or SQLite.
public final class SessionMediaDescriptorCache: @unchecked Sendable {
  public static let defaultCapacity = 10

  private let lock = NSLock()
  private let capacity: Int
  /// Most-recently used at the end.
  private var order: [TaskID] = []
  private var values: [TaskID: MediaDescriptor] = [:]

  public init(capacity: Int = SessionMediaDescriptorCache.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  public var count: Int {
    lock.withLock { values.count }
  }

  public func descriptor(for taskID: TaskID, now: Date = Date()) -> MediaDescriptor? {
    lock.withLock {
      guard let value = values[taskID] else { return nil }
      if isExpired(value, now: now) {
        removeLocked(taskID)
        return nil
      }
      touchLocked(taskID)
      return value
    }
  }

  public func insert(_ descriptor: MediaDescriptor, for taskID: TaskID) {
    lock.withLock {
      values[taskID] = descriptor
      touchLocked(taskID)
      while order.count > capacity, let oldest = order.first {
        removeLocked(oldest)
      }
    }
  }

  public func remove(_ taskID: TaskID) {
    lock.withLock { removeLocked(taskID) }
  }

  public func removeAll() {
    lock.withLock {
      order.removeAll()
      values.removeAll()
    }
  }

  /// Task IDs from oldest to newest (for tests).
  public func orderedTaskIDs() -> [TaskID] {
    lock.withLock { order }
  }

  private func touchLocked(_ taskID: TaskID) {
    order.removeAll { $0 == taskID }
    order.append(taskID)
  }

  private func removeLocked(_ taskID: TaskID) {
    values.removeValue(forKey: taskID)
    order.removeAll { $0 == taskID }
  }

  private func isExpired(_ descriptor: MediaDescriptor, now: Date) -> Bool {
    guard let raw = descriptor.expiresAt else { return false }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    let expiry = fractional.date(from: raw) ?? whole.date(from: raw)
    guard let expiry else { return false }
    return expiry <= now
  }
}
