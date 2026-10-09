import Foundation
import LinkDigestCore

/// 读过的模型列表里，服务商给的显示名和渠道名（Magpie 给「Claude Haiku 5.5」「Claude Code」）。
///
/// 读列表时（添加模型、拉取最新、检测可用）顺手记下，别处显示模型名时查：设置里的选择器、
/// 详情页的提示和工序面板、生成记录。存在本机一个小文件里，旧的生成记录也能用上；没记过的
/// 模型由 `ModelNaming` 自己推。只是显示用的缓存，删了也不影响任何功能。
final class ModelNameHintStore: @unchecked Sendable {
  static let shared = ModelNameHintStore(fileURL: ModelNameHintStore.defaultFileURL)

  private let fileURL: URL?
  private let lock = NSLock()
  private var hints: [String: ModelNameHints]

  init(fileURL: URL?) {
    self.fileURL = fileURL
    if let fileURL, let data = try? Data(contentsOf: fileURL),
       let stored = try? JSONDecoder().decode([String: ModelNameHints].self, from: data) {
      hints = stored
    } else {
      hints = [:]
    }
  }

  static var defaultFileURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("LinkDigest", isDirectory: true)
      .appendingPathComponent("model-display-names.json")
  }

  private static func key(_ baseURL: String, _ model: String) -> String { baseURL + "\n" + model }

  func record(baseURL: String, entries: [ModelCatalogEntry]) {
    let fresh = entries.compactMap { entry -> (String, ModelNameHints)? in
      let hint = ModelNameHints(displayName: entry.displayName, channelLabel: entry.sourceLabel)
      guard hint.displayName != nil || hint.channelLabel != nil else { return nil }
      return (Self.key(baseURL, entry.id), hint)
    }
    guard !fresh.isEmpty else { return }
    let snapshot: [String: ModelNameHints]? = lock.withLock {
      var changed = false
      for (key, hint) in fresh where hints[key] != hint {
        hints[key] = hint
        changed = true
      }
      return changed ? hints : nil
    }
    guard let snapshot, let fileURL else { return }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
  }

  func hints(baseURL: String?, model: String) -> ModelNameHints? {
    guard let baseURL else { return nil }
    return lock.withLock { hints[Self.key(baseURL, model)] }
  }

  /// 全 App 显示模型名都走这里。
  ///
  /// 没给服务地址时（设置里只存了模型 ID 的那几处、脑图记录），按模型 ID 在记过的列表里反查：
  /// 只有一家有这个 ID 才用它，两家都有就不猜，渠道留空。
  func label(baseURL: String?, model: String) -> ModelLabel {
    let resolved = baseURL ?? uniqueBaseURL(for: model)
    return ModelNaming.label(baseURL: resolved, model: model, hints: hints(baseURL: resolved, model: model))
  }

  private func uniqueBaseURL(for model: String) -> String? {
    let suffix = "\n" + model
    let bases = lock.withLock { hints.keys.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) } }
    return bases.count == 1 ? bases[0] : nil
  }
}
