import Foundation
import LinkDigestCore

/// 批量/AI 保存的视频「自动转写」队列的小日志：只记 taskID 和已尝试次数，
/// 不存链接、正文或任何令牌。App 中途退出后，下次启动按它把没转完的接着排上；
/// 每条最多自动尝试 `maxAttempts` 次，避免坏文件无限重试。
final class AutoTranscriptionJournal {
  static let fileName = "auto-transcription-queue-v1.json"
  static let maxAttempts = 2

  private let fileURL: URL
  private var attempts: [String: Int]

  init(applicationSupportRoot: URL) {
    fileURL = applicationSupportRoot.appendingPathComponent(Self.fileName, isDirectory: false)
    if let data = try? Data(contentsOf: fileURL),
       let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
      attempts = decoded
    } else {
      attempts = [:]
    }
  }

  /// 新登记一条：已在日志里的不重置次数。
  func register(_ taskID: TaskID) {
    guard attempts[taskID.rawValue] == nil else { return }
    attempts[taskID.rawValue] = 0
    persist()
  }

  /// 开始转之前记一次尝试。
  func noteAttempt(_ taskID: TaskID) {
    attempts[taskID.rawValue, default: 0] += 1
    persist()
  }

  /// 完成、已有转写、失败或用户停止后都从日志移除（失败的在条目里手动重试）。
  func remove(_ taskID: TaskID) {
    guard attempts.removeValue(forKey: taskID.rawValue) != nil else { return }
    persist()
  }

  /// 关掉「自动转写」时整本清空。
  func removeAll() {
    guard !attempts.isEmpty else { return }
    attempts.removeAll()
    persist()
  }

  /// 启动时要接着转的：尝试次数还没到上限的；到上限的顺手清掉。
  func resumableTaskIDs() -> [TaskID] {
    let exhausted = attempts.filter { $0.value >= Self.maxAttempts }.map(\.key)
    if !exhausted.isEmpty {
      exhausted.forEach { attempts.removeValue(forKey: $0) }
      persist()
    }
    return attempts.keys.sorted().compactMap { TaskID($0) }
  }

  var pendingCount: Int { attempts.count }

  private func persist() {
    guard let data = try? JSONEncoder().encode(attempts) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
