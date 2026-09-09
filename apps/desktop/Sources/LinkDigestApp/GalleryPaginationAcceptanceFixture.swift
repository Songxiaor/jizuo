#if DEBUG
import Foundation
import SwiftUI
import LinkDigestCore

/// Six immutable, cover-free rows. All writes fail; no real store or network.
/// The first next-page read waits for the acceptance control, then fails once.
final class GalleryPaginationAcceptanceRepository: HistoryRepository, @unchecked Sendable {
  let accessMode: HistoryRepositoryAccessMode = .readOnly(.storageUnavailable)
  let rows: [HistoryRowProjection] = (1...6).map { index in
    let letter = String(UnicodeScalar(64 + index)!)
    return .init(taskID: TaskID("00000000-0000-4000-8000-00000000000\(index)")!,
      title: "隔离作品 \(letter) · 第\(index <= 4 ? "一" : "二")页",
      canonicalURL: "https://fixture.invalid/pagination/\(letter)", host: "fixture.invalid",
      sourceLabel: "隔离夹具", latestRunKind: nil, latestRunStatus: nil, latestModel: nil,
      updatedAtMilliseconds: Int64(100 - index), latestRunAtMilliseconds: nil,
      usageCost: .unknown, artifactPreview: "只用于分页验收，不连接真实资料。")
  }
  private let condition = NSCondition()
  private var released = false
  private var trail: [String] = []
  private var nextReads = 0

  var requestTrail: [String] {
    condition.lock(); defer { condition.unlock() }
    return trail
  }
  func releaseFailure() {
    condition.lock(); released = true; condition.broadcast(); condition.unlock()
  }
  func historyPage(limit: Int, after cursor: HistoryPageCursor?, filter: HistoryListFilter) throws -> HistoryPage {
    guard filter.searchText.isEmpty else { return .init(rows: [], nextCursor: nil) }
    return try historyPage(limit: limit, after: cursor)
  }
  func historyPage(limit _: Int, after cursor: HistoryPageCursor?) throws -> HistoryPage {
    condition.lock(); defer { condition.unlock() }
    trail.append(cursor?.taskID.rawValue ?? "initial")
    let last = rows[3]
    guard let cursor else {
      return .init(rows: Array(rows.prefix(4)), nextCursor: .init(
        updatedAtMilliseconds: last.updatedAtMilliseconds, taskID: last.taskID))
    }
    guard cursor.taskID == last.taskID, cursor.updatedAtMilliseconds == last.updatedAtMilliseconds else {
      throw RepositoryFailure.invalidInput
    }
    nextReads += 1
    if nextReads == 1 {
      let deadline = Date().addingTimeInterval(1200)
      while !released, Date() < deadline { _ = condition.wait(until: deadline) }
      throw RepositoryFailure.unavailable
    }
    return .init(rows: Array(rows.suffix(2)), nextCursor: nil)
  }
  func acceptCapture(_: AcceptCaptureCommand) throws -> AcceptCaptureResult { throw RepositoryFailure.invalidInput }
  func createRun(_: CreateRunCommand) throws -> CreateRunResult { throw RepositoryFailure.invalidInput }
  func markRunRunning(_: MarkRunRunningCommand) throws { throw RepositoryFailure.invalidInput }
  func savePartialArtifact(_: SavePartialArtifactCommand) throws { throw RepositoryFailure.invalidInput }
  func finishRun(_: FinishRunCommand) throws { throw RepositoryFailure.invalidInput }
  func recoverInterruptedRuns(at _: Int64) throws -> Int { 0 }
  func detail(taskID _: TaskID) throws -> HistoryDetailProjection { throw RepositoryFailure.notFound }
  func exportProjection(taskID _: TaskID) throws -> HistoryExportProjection { throw RepositoryFailure.invalidInput }
  func deleteTask(taskID _: TaskID) throws { throw RepositoryFailure.invalidInput }
}

@MainActor
final class GalleryPaginationAcceptanceState {
  let model = HistoryViewModel()
  let repository = GalleryPaginationAcceptanceRepository()
  private let root: URL?
  private var started = false
  init(root: URL? = nil) { self.root = root }
  deinit { repository.releaseFailure() }
  func start() {
    guard !started else { return }
    started = true
    model.configure(history: HistoryApplicationService(repository: repository), isReadOnly: true, unavailableCode: nil)
    model.selectHost("fixture.invalid")
  }
  func record() {
    guard let root else { return }
    let snapshot: [String: Any] = [
      "rowIDs": model.rows.map { $0.taskID.rawValue },
      "selectedIDs": model.selectedTaskIDs.map(\.rawValue).sorted(),
      "listState": String(describing: model.listState),
      "isLoadingNextPage": model.isLoadingNextPage,
      "error": model.listErrorCode?.rawValue ?? "",
      "requests": repository.requestTrail
    ]
    if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
      try? data.write(to: root.appendingPathComponent("pagination-state.json"), options: .atomic)
    }
  }
}

@MainActor
struct GalleryPaginationAcceptancePanel: View {
  let fixture: GalleryPaginationAcceptanceState
  @ObservedObject private var model: HistoryViewModel
  @Environment(\.appTheme) private var theme
  @FocusState private var searchFocused: Bool
  @State private var scrollTarget: TaskID?
  init(fixture: GalleryPaginationAcceptanceState) {
    self.fixture = fixture
    model = fixture.model
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("隔离分页 · 已载入 \(model.rows.count) 条 · 已勾选 \(model.selectedTaskIDs.count) 条")
        Spacer()
        Button("触发第二页失败") { fixture.repository.releaseFailure() }
          .disabled(!model.isLoadingNextPage)
          .accessibilityIdentifier("pagination-fixture-release-failure")
      }.padding(12)
      PlatformHistoryGallery(model: model, theme: theme, searchFocused: $searchFocused,
        scrollTarget: $scrollTarget, onOpen: { _ in }, contextMenu: { _ in AnyView(EmptyView()) })
    }
    .task { fixture.start() }
    .onChange(of: model.rows) { _, _ in fixture.record() }
    .onChange(of: model.selectedTaskIDs) { _, _ in fixture.record() }
    .onChange(of: model.isLoadingNextPage) { _, _ in fixture.record() }
    .onChange(of: model.listErrorCode) { _, _ in fixture.record() }
  }
}
#endif
