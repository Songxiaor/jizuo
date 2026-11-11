import Foundation
import LinkDigestCore

/// 生成一张素材卡的完整过程（不含界面、不含确认）：
/// 取转写稿 → 调模型 → 判定「真人口播」标签 → 存卡 → 记账。
/// 依赖全是闭包，测试里换成假的：不碰真实库、不发真实请求。
struct MaterialCardService: Sendable {
  struct Source: Sendable, Equatable {
    var text: String
    var title: String?
  }

  var store: any MaterialCardStoring
  var extractor: any MaterialCardExtracting
  /// 这条内容的转写稿；没有转写稿返回 nil。
  var loadSource: @Sendable (TaskID) async -> Source?
  /// 这条内容现在带着的标签（归一化名）。
  var currentTagNames: @Sendable (TaskID) async -> Set<String>
  /// 挂上「真人口播」，成功返回 true。
  var attachLiveSpeakerTag: @Sendable (TaskID) async -> Bool
  var recordTokens: @Sendable (TaskID, MaterialCardOutcome) async -> Void
  var now: @Sendable () -> Int64

  @discardableResult
  func generate(taskID: TaskID) async throws -> TaskMaterialCardRecord {
    guard let source = await loadSource(taskID),
          source.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= MaterialCardPrompt.minimumTranscriptCharacters
    else { throw MaterialCardError.emptyTranscript }
    let outcome = try await extractor.extractCard(transcript: source.text, title: source.title)
    try Task.checkCancellation()
    // 金句再按全文核对一遍：不信任任何一个 extractor 实现。
    var card = outcome.card
    card.quotes = MaterialCardPrompt.validatedQuotes(card.quotes, transcript: source.text)

    let previous = try? store.loadMaterialCard(taskID: taskID)
    let tags = await currentTagNames(taskID)
    let decision = MaterialCardTagDecision.decide(
      card: card, previous: previous,
      tagCurrentlyOnItem: tags.contains(MaterialCatalog.liveSpeakerTagNormalizedName)
    )
    var applied = decision.applied
    if decision.attach { applied = await attachLiveSpeakerTag(taskID) }

    let timestamp = now()
    let record = TaskMaterialCardRecord(
      taskID: taskID, card: card,
      liveSpeakerTagApplied: applied, liveSpeakerTagSuppressed: decision.suppressed,
      provider: outcome.provider ?? "configured_provider", model: outcome.model,
      promptTokens: outcome.promptTokens, completionTokens: outcome.completionTokens, totalTokens: outcome.totalTokens,
      createdAtMilliseconds: previous?.createdAtMilliseconds ?? timestamp, updatedAtMilliseconds: timestamp
    )
    try store.saveMaterialCard(record)
    await recordTokens(taskID, outcome)
    return record
  }
}
