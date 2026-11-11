import Foundation
import LinkDigestCore
import Observation

/// 阅读页「相关内容」的调度（2026-11-11）。
///
/// - 全程在本机：复用「按意思搜」的本机向量索引，不调用付费模型，不外发内容。
/// - 后台算：查询在语义引擎的 actor 上跑，按 id 取列表信息放到 `Task.detached`，
///   主线程只拿结果。打开一条资料时界面不额外等待。
/// - 不串台：每次请求带一个自增序号，快速切换条目时迟到的旧结果直接丢掉。
/// - 不重复算：同一份查询 + 同一版索引算过一次就记下来，切走再回来直接用。
/// - 开关和索引状态由「按意思搜」决定；没打开、模型没下好、索引没建好时这里什么都不做，
///   也不会顺手触发下载或补索引。
@MainActor
protocol RelatedContentSearching: AnyObject {
  var isRelatedContentReady: Bool { get }
  /// 当前索引版本（条数 + 最新更新时间）。先拿它判缓存，命中就不用再算一遍查询。
  var relatedContentIndexFingerprint: String { get }
  func relatedCandidates(_ query: String) async -> RelatedContentCandidates
}

/// 一次检索的返回：候选，以及这些候选所依据的索引版本。
struct RelatedContentCandidates: Sendable {
  let indexFingerprint: String
  let ranked: [(taskID: TaskID, score: Float)]
}

extension SemanticSearchService: RelatedContentSearching {
  var isRelatedContentReady: Bool { isReady }
  var relatedContentIndexFingerprint: String { indexFingerprint }
}

/// 按 id 取列表要显示的标题和正文预览。脱离主线程调用。
protocol RelatedContentRowLoading: Sendable {
  func rows(for taskIDs: [TaskID]) -> [HistoryRowProjection]
}

struct HistoryRelatedContentRows: RelatedContentRowLoading {
  let history: HistoryApplicationService

  func rows(for taskIDs: [TaskID]) -> [HistoryRowProjection] {
    guard !taskIDs.isEmpty else { return [] }
    // 只查这几个候选：候选最多 200 条，一页就够。
    let filter = HistoryListFilter(includesNotes: true, onlyTaskIDs: taskIDs)
    return (try? history.historyPage(limit: taskIDs.count, after: nil, filter: filter))?.rows ?? []
  }
}

/// 一次「相关内容」请求的身份。查询文本也算在内：同一条资料跑完总结后再打开，
/// 查询会换成更好的版本，这时应该重算，而不是拿旧缓存。
struct RelatedContentRequest: Hashable {
  let taskID: TaskID
  let query: String
}

@MainActor
@Observable
final class RelatedContentService {
  private struct CacheKey: Hashable {
    let request: RelatedContentRequest
    /// 索引版本：索引有增删改，缓存立刻作废，不能拿旧索引算的结果顶新内容。
    let indexFingerprint: String
  }

  private(set) var items: [RelatedContentSelection.Item] = []
  private(set) var request: RelatedContentRequest?

  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var cache: [CacheKey: [RelatedContentSelection.Item]] = [:]

  func load(
    request: RelatedContentRequest,
    search: (any RelatedContentSearching)?,
    rows: (any RelatedContentRowLoading)?
  ) async {
    generation += 1
    let current = generation
    let isSameItem = self.request == request
    self.request = request

    guard let search, search.isRelatedContentReady, let rows,
          !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // 没就绪、没库：换到别的资料才清空。同一条上已经有结果就留着——
      // 索引补算期间这一块不能凭空消失，补算完再刷新（2026-11-11 复核）。
      if !isSameItem { items = [] }
      return
    }

    let fingerprint = search.relatedContentIndexFingerprint
    if let cached = cache[CacheKey(request: request, indexFingerprint: fingerprint)] {
      items = cached
      return
    }
    // 同一条资料重算（比如索引补了一遍）时，先把旧结果留在屏幕上，算完再换。
    if !isSameItem { items = [] }

    let candidates = await search.relatedCandidates(request.query)
    guard !Task.isCancelled, current == generation, self.request == request else { return }

    let key = CacheKey(request: request, indexFingerprint: candidates.indexFingerprint)
    if let cached = cache[key] {
      items = cached
      return
    }

    let loadedRows = await Task.detached(priority: .userInitiated) {
      rows.rows(for: candidates.ranked.map(\.taskID))
    }.value
    guard !Task.isCancelled, current == generation, self.request == request else { return }

    let selected = RelatedContentSelection.select(
      ranked: candidates.ranked,
      currentTaskID: request.taskID,
      rows: loadedRows,
      minimumScore: SemanticSearchService.minimumScore
    )
    // 空结果不缓存：库里刚补进来的条目、或者索引补算完了，下次应该能算出来。
    if !selected.isEmpty { cache[key] = selected }
    items = selected
  }
}
