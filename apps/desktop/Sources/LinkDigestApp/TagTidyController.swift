import Foundation
import Observation
import LinkDigestCore

/// 「AI 整理标签」的流程控制：出方案 → 预览 → 用户确认 → 备份 → 经现有 `mergeTags` 执行。
///
/// 安全顺序写死在这里：
/// 1. 发模型前过数据去向确认；只读状态不开始；
/// 2. 方案只是预览，用户可逐组取消、改名；
/// 3. 确认后**先备份**，备份失败就一个合并都不做；
/// 4. 合并只走注入的 `merge`（生产里是 `HistoryApplicationService.mergeTags`），不手工改库；
/// 5. 保留标签在 `TagTidyPlan.enabledMerges()` 里再过滤一次。
@MainActor
@Observable
final class TagTidyController {
  enum State: Equatable {
    case idle
    case needsConsent(host: String, model: String)
    case working
    case preview
    case applying
    case finished(String)
    case failed(String)
  }

  private(set) var state: State = .idle
  /// 预览里可编辑的方案（取消某组、改名、去掉某个常用标签）。
  var plan: TagTidyPlan?
  /// 确认时是否同时启用建议的常用标签表。
  var adoptFrequent = true
  private(set) var tokenSummary: String?
  /// 最近一次整理的用量（只记数字和模型名，不记任何内容）。
  struct Usage: Equatable { let promptTokens: Int?; let completionTokens: Int?; let totalTokens: Int; let model: String? }
  private(set) var lastUsage: Usage?
  private var usageNote: String?

  private let tidier: any TagTidying
  private let gate: ModelCallGate
  private let store: FrequentTagStore
  private let tags: () -> [HistoryNavigationTag]
  private let isReadOnly: () -> Bool
  private let backup: @Sendable () async throws -> Void
  private let merge: @Sendable ([String], String) async throws -> Void
  private let didApply: () -> Void
  private var task: Task<Void, Never>?
  /// 方案刚出来时每组的原目标名，用来把用户改名同步到常用表里。
  private var originalTargets: [Int: String] = [:]

  init(
    tidier: any TagTidying,
    gate: ModelCallGate,
    store: FrequentTagStore,
    tags: @escaping () -> [HistoryNavigationTag],
    isReadOnly: @escaping () -> Bool,
    backup: @escaping @Sendable () async throws -> Void,
    merge: @escaping @Sendable ([String], String) async throws -> Void,
    didApply: @escaping () -> Void
  ) {
    self.tidier = tidier
    self.gate = gate
    self.store = store
    self.tags = tags
    self.isReadOnly = isReadOnly
    self.backup = backup
    self.merge = merge
    self.didApply = didApply
  }

  var isBusy: Bool { state == .working || state == .applying }

  func start() {
    guard !isBusy else { return }
    plan = nil; tokenSummary = nil; usageNote = nil; lastUsage = nil
    guard !isReadOnly() else { state = .failed(TagTidyError.notAllowed.userMessage); return }
    guard !TagTidyPrompt.userContent(tags: tags()).isEmpty else {
      state = .failed(TagTidyError.noTags.userMessage); return
    }
    task = Task { [weak self] in
      guard let self else { return }
      switch await self.gate.status() {
      case .allowed: await self.propose()
      case let .needsConfirmation(host, model): self.state = .needsConsent(host: host, model: model)
      case let .unavailable(message): self.state = .failed(message)
      }
    }
  }

  func confirmConsent() {
    guard case let .needsConsent(host, model) = state else { return }
    state = .working
    task = Task { [weak self] in
      guard let self else { return }
      // 确认的是弹窗里展示的 host+model：这期间换了服务商/模型就作废，重新弹窗，不发送。
      guard await self.gate.confirm(host, model) else {
        switch await self.gate.status() {
        case .allowed: await self.propose()
        case let .needsConfirmation(newHost, newModel): self.state = .needsConsent(host: newHost, model: newModel)
        case let .unavailable(message): self.state = .failed(message)
        }
        return
      }
      await self.propose()
    }
  }

  func cancel() {
    task?.cancel(); task = nil
    if state != .applying { state = .idle; plan = nil }
  }

  func dismissResult() {
    if !isBusy { state = .idle; plan = nil }
  }

  private func propose() async {
    state = .working
    do {
      let outcome = try await tidier.proposePlan(tags: tags())
      guard !Task.isCancelled else { return }
      plan = outcome.plan
      originalTargets = Dictionary(uniqueKeysWithValues: outcome.plan.merges.map { ($0.id, $0.target) })
      if let total = outcome.totalTokens ?? outcome.promptTokens.map({ $0 + (outcome.completionTokens ?? 0) }) {
        let modelPart = outcome.model.map { "，模型 \($0)" } ?? ""
        tokenSummary = "本次约用 \(total) token" + modelPart
        usageNote = tokenSummary
        lastUsage = .init(
          promptTokens: outcome.promptTokens, completionTokens: outcome.completionTokens,
          totalTokens: total, model: outcome.model
        )
      }
      state = .preview
    } catch let error as TagTidyError {
      state = .failed(error.userMessage)
    } catch let error as TranscriptTidyError {
      state = error == .cancelled ? .idle : .failed(error.userMessage)
    } catch is CancellationError {
      state = .idle
    } catch {
      state = .failed("整理标签时出了问题，没有做任何修改。")
    }
  }

  /// 用户点「确认执行」。
  func apply() {
    guard state == .preview, let plan, !isBusy else { return }
    guard !isReadOnly() else { state = .failed(TagTidyError.notAllowed.userMessage); return }
    let merges = plan.enabledMerges()
    let frequent = adoptFrequent && !plan.frequent.isEmpty ? plan.resolvedFrequent(originalTargets: originalTargets) : nil
    guard !merges.isEmpty || frequent != nil else {
      state = .finished("没有勾选任何合并，也没有启用常用标签表，没有做修改。"); return
    }
    state = .applying
    task = Task { [weak self] in
      guard let self else { return }
      // 先备份：失败就一个都不执行。没有合并时只写常用表（小 JSON），不需要备份整库。
      if !merges.isEmpty {
        do { try await self.backup() } catch {
          self.state = .failed(TagTidyError.backupFailed.userMessage)
          return
        }
      }
      var done = 0, failed = 0, attempted = 0
      for group in merges {
        // 每组之前检查取消：取消就停，不回滚已做的（备份在）。
        if Task.isCancelled { break }
        attempted += 1
        do { try await self.merge(group.sources, group.target); done += 1 } catch { failed += 1 }
      }
      let cancelled = attempted < merges.count
      var notes: [String] = []
      if !merges.isEmpty {
        notes.append("已完成 \(done) 组、未执行 \(merges.count - attempted) 组" + (failed > 0 ? "，另有 \(failed) 组没成功" : ""))
        notes.append("已做的合并不会自动撤回；整理前已备份整库，需要恢复时可用数据备份里最新的那份")
      }
      if cancelled {
        notes.append("已停止，常用标签表没有更新")
      } else if let frequent {
        if (try? self.store.replaceTags(frequent)) != nil {
          notes.append("常用标签表已更新（\(self.store.allowedNames.count) 个）：新内容的标签今后只从表里选")
        } else {
          notes.append("常用标签表没能保存")
        }
      }
      if let usage = self.usageNote { notes.append(usage) }
      self.didApply()
      self.state = .finished(notes.joined(separator: "；") + "。")
      self.plan = nil
    }
  }
}

/// 常用标签表和「建议加入」候选的界面模型：薄薄一层，包着 `FrequentTagStore`。
@MainActor
@Observable
final class FrequentTagsModel {
  private(set) var document = FrequentTagsDocument()
  /// 常用表文件损坏时的一句提示（坏文件已改名留底，表按空表处理）。
  private(set) var corruptNotice: String?
  private let store: FrequentTagStore

  init(store: FrequentTagStore) {
    self.store = store
    document = store.load()
    refreshNotice()
  }

  func reload() { document = store.load(); refreshNotice() }

  func dismissNotice() { store.acknowledgeCorruptNotice(); corruptNotice = nil }

  private func refreshNotice() {
    if let name = store.corruptBackupName {
      corruptNotice = "常用标签表的文件损坏，已按空表处理（新内容的标签不受限制）。原文件已保留为 \(name)，在数据目录里。"
    }
  }

  func add(_ rawName: String) { document = (try? store.addTag(rawName)) ?? store.load() }

  func remove(_ name: String) {
    guard let key = HistoryTagNormalizer.normalized(name)?.normalizedName else { return }
    document = (try? store.removeTag(normalizedName: key)) ?? store.load()
  }

  /// 清空整张表 = 回到和没有这个功能时一样的行为。
  func clearAll() { document = (try? store.replaceTags([])) ?? store.load() }

  func accept(_ name: String) {
    guard let key = HistoryTagNormalizer.normalized(name)?.normalizedName else { return }
    document = (try? store.acceptSuggestion(normalizedName: key)) ?? store.load()
  }

  func dismiss(_ name: String) {
    guard let key = HistoryTagNormalizer.normalized(name)?.normalizedName else { return }
    document = (try? store.dismissSuggestion(normalizedName: key)) ?? store.load()
  }
}
