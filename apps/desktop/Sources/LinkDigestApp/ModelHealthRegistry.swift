import Foundation
import Observation
import SwiftUI
import LinkDigestCore

/// 记住每个模型最近一次「能不能用」的结论，供设置页和阅读页显示。
///
/// 只存服务地址、模型名、状态、时间和来源——没有密钥、没有回包内容。
@MainActor
@Observable
final class ModelHealthRegistry {
  static let shared = ModelHealthRegistry()

  private static let defaultsKey = "model-health-records-v1"
  private static let seenKey = "model-health-seen-in-catalog-v1"
  private let defaults: UserDefaults
  private let now: () -> Int64
  private(set) var records: [String: ModelHealthRecord] = [:]
  /// 曾经在服务商模型列表里出现过的模型。只有「出现过、现在不见了」才判下架：
  /// 本地模型的别名（llama3 对 llama3:latest）、中转站不列出的模型，本来就不在列表里。
  private var seenInCatalog: Set<String> = []

  init(
    defaults: UserDefaults = .standard,
    now: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
  ) {
    self.defaults = defaults
    self.now = now
    if let data = defaults.data(forKey: Self.defaultsKey),
       let decoded = try? JSONDecoder().decode([String: ModelHealthRecord].self, from: data) {
      records = decoded
    }
    if let seen = defaults.stringArray(forKey: Self.seenKey) {
      seenInCatalog = Set(seen)
    }
  }

  var nowMilliseconds: Int64 { now() }

  /// 让适配层的每次调用结果流进来。App 启动时调用一次。
  static func installObservation() {
    ModelHealthObservation.handler = { baseURL, model, status in
      Task { @MainActor in
        ModelHealthRegistry.shared.record(baseURL: baseURL.absoluteString, model: model, status: status, source: .run)
      }
    }
  }

  func record(for baseURL: String, model: String) -> ModelHealthRecord? {
    records[ModelHealthKey.make(baseURL: baseURL, model: model)]
  }

  func record(baseURL: String, model: String, status: ModelHealthStatus, source: ModelHealthRecord.Source) {
    let key = ModelHealthKey.make(baseURL: baseURL, model: model)
    let timestamp = now()
    // 检测时适配层的旁路通知会晚一步到，别让它把刚写的「检测」结论改成「调用」来源。
    if source == .run, let existing = records[key], existing.source == .probe,
       existing.status == status, timestamp - existing.checkedAtMilliseconds < 10_000 {
      return
    }
    records[key] = ModelHealthRecord(status: status, checkedAtMilliseconds: timestamp, source: source)
    persist()
  }

  /// 读到模型列表后对照：已保存的模型不在列表里 → 已下架。
  ///
  /// 列表被截断（达到读取上限）时不下结论，免得把排在后面的模型误判成下架。
  /// 之前因为「不在列表里」判成下架、现在又出现在列表里的，清掉那条结论。
  func applyCatalog(baseURL: String, catalog: [String], savedModels: [String], isTruncated: Bool) {
    let present = Set(catalog)
    var changed = false
    for model in present {
      let key = ModelHealthKey.make(baseURL: baseURL, model: model)
      if seenInCatalog.insert(key).inserted { changed = true }
      if let existing = records[key], existing.source == .catalog, existing.status == .removed {
        records[key] = nil
        changed = true
      }
    }
    if !isTruncated, !catalog.isEmpty {
      for model in savedModels where !present.contains(model) {
        let key = ModelHealthKey.make(baseURL: baseURL, model: model)
        guard seenInCatalog.contains(key) else { continue }
        records[key] = ModelHealthRecord(status: .removed, checkedAtMilliseconds: now(), source: .catalog)
        changed = true
      }
    }
    if changed { persist() }
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(records) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
    defaults.set(Array(seenInCatalog), forKey: Self.seenKey)
  }
}

/// 模型状态在界面上的样子。
struct ModelHealthBadge: Equatable {
  enum Tone: Equatable { case good, warning, bad, neutral }

  let text: String
  let symbol: String
  let tone: Tone
  /// 悬停和说明文字：为什么、该怎么办。
  let detail: String

  static let unchecked = ModelHealthBadge(
    text: "未检测", symbol: "questionmark.circle", tone: .neutral,
    detail: "还不知道能不能用。点「检测可用性」发一条极短请求确认。"
  )

  init(text: String, symbol: String, tone: Tone, detail: String) {
    self.text = text
    self.symbol = symbol
    self.tone = tone
    self.detail = detail
  }

  init(record: ModelHealthRecord?, nowMilliseconds: Int64) {
    guard let record else {
      self = .unchecked
      return
    }
    let base: ModelHealthBadge = switch record.status {
    case .available:
      .init(text: "可用", symbol: "checkmark.circle.fill", tone: .good, detail: "最近一次调用成功。")
    case .temporarilyUnavailable:
      .init(text: "暂时不可用", symbol: "clock.badge.exclamationmark", tone: .warning,
            detail: "服务商那边暂时出问题或太忙，稍后可以再试。")
    case .removed:
      .init(text: "已下架", symbol: "xmark.octagon.fill", tone: .bad,
            detail: record.source == .catalog
              ? "服务商的模型列表里已经没有它了，请换一个模型。"
              : "服务商说不再支持这个模型，请换一个模型。")
    case .officialClientOnly:
      .init(text: "仅限官方客户端", symbol: "lock.fill", tone: .bad,
            detail: "服务商把这个免费模型限定在自家工具里，汲作调用不了，请换一个模型。")
    case .billingLimited:
      .init(text: "需充值", symbol: "creditcard", tone: .warning,
            detail: "服务商因为余额或额度挡下了请求，去服务商控制台充值后可用。")
    case .notEntitled:
      .init(text: "未开通", symbol: "lock", tone: .warning,
            detail: "这个账号没有使用这个模型的权限，去服务商那边开通，或换一个模型。")
    case .keyInvalid:
      .init(text: "密钥无效", symbol: "key", tone: .bad,
            detail: "服务商不认这把密钥，请在这个模型的设置里点「更换」重新填写。")
    }
    // 下架、仅限官方客户端这类结论不会自己变好，过期也照样显示；
    // 其余的超过一天就提示重新检测。
    if record.isStale(nowMilliseconds: nowMilliseconds), !record.status.isDefinitelyUnusable {
      self = .init(text: base.text + " · 需重新检测", symbol: base.symbol, tone: .neutral,
                   detail: base.detail + "（结果已超过一天）")
    } else {
      self = base
    }
  }

  func color(theme: HistoryThemeTokens) -> Color {
    switch tone {
    case .good: theme.success
    case .warning: theme.warning
    case .bad: theme.danger
    case .neutral: theme.secondaryText
    }
  }
}

/// 模型名后面的一小块状态标记。
struct ModelHealthBadgeView: View {
  let badge: ModelHealthBadge
  let theme: HistoryThemeTokens

  var body: some View {
    Label(badge.text, systemImage: badge.symbol)
      .themedFont(.caption, weight: .medium)
      .foregroundStyle(badge.color(theme: theme))
      .lineLimit(1)
      .fixedSize()
      .help(badge.detail)
      .accessibilityLabel("可用状态：\(badge.text)")
  }
}
