import Foundation
import LinkDigestCore

/// A stable, UI-ready snapshot of one work selected from a creator profile.
///
/// `captureURL` may contain a short-lived platform signature. It is intentionally
/// session-only and is never written by `ProfileImportBatchJournal`.
struct ProfileImportCandidateSeed: Sendable, Equatable {
  let workID: String
  let authorID: String
  let canonicalURL: String
  let captureURL: String?
  let previewText: String?
  let coverURL: String?
  let publishedText: String?
  let likes: String?
  let comments: String?
  let collects: String?

  init(
    workID: String,
    authorID: String,
    canonicalURL: String,
    captureURL: String? = nil,
    previewText: String? = nil,
    coverURL: String? = nil,
    publishedText: String? = nil,
    likes: String? = nil,
    comments: String? = nil,
    collects: String? = nil
  ) {
    self.workID = workID
    self.authorID = authorID
    self.canonicalURL = canonicalURL
    self.captureURL = captureURL
    self.previewText = previewText
    self.coverURL = coverURL
    self.publishedText = publishedText
    self.likes = likes
    self.comments = comments
    self.collects = collects
  }
}

enum ProfileImportBatchItemPhase: Sendable, Equatable {
  case queued
  case fetching
  case saving
  case completed(TaskID)
  case failed(String)
  case cancelled
  case interrupted

  var isActive: Bool {
    self == .queued || self == .fetching || self == .saving
  }

  var canRetry: Bool {
    switch self {
    case .failed, .cancelled, .interrupted: true
    default: false
    }
  }

  var canCancel: Bool { self == .queued || self == .fetching }
}

struct ProfileImportBatchItem: Identifiable, Sendable, Equatable {
  let id: UUID
  let seed: ProfileImportCandidateSeed
  var phase: ProfileImportBatchItemPhase
}

struct ProfileImportBatch: Identifiable, Sendable, Equatable {
  let id: UUID
  let createdAtMilliseconds: Int64
  let downloadsVideo: Bool
  let creatorID: CreatorID?
  var isCollapsed: Bool
  var items: [ProfileImportBatchItem]

  var completedCount: Int {
    items.reduce(into: 0) { count, item in
      if case .completed = item.phase { count += 1 }
    }
  }

  var isFinished: Bool { items.allSatisfy { !$0.phase.isActive } }
}

protocol ProfileImportBatchJournalStoring {
  func load() throws -> [ProfileImportBatch]
  func save(_ batches: [ProfileImportBatch]) throws
}

/// A small JSON journal beside the main history database. It deliberately does
/// not duplicate article bodies or migrate SQLite merely to preserve queue UI.
final class ProfileImportBatchJournal: ProfileImportBatchJournalStoring {
  static let fileName = "profile-import-batches-v1.json"

  private let fileURL: URL

  init(applicationSupportRoot: URL) {
    fileURL = applicationSupportRoot.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  func load() throws -> [ProfileImportBatch] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let records = try JSONDecoder().decode([BatchRecord].self, from: Data(contentsOf: fileURL))
    return records.map(\.restoredBatch)
  }

  func save(_ batches: [ProfileImportBatch]) throws {
    let data = try JSONEncoder().encode(batches.map(BatchRecord.init))
    try data.write(to: fileURL, options: .atomic)
  }

  private struct BatchRecord: Codable {
    let id: UUID
    let createdAtMilliseconds: Int64
    let downloadsVideo: Bool
    let creatorID: String?
    let isCollapsed: Bool
    let items: [ItemRecord]

    init(_ batch: ProfileImportBatch) {
      id = batch.id
      createdAtMilliseconds = batch.createdAtMilliseconds
      downloadsVideo = batch.downloadsVideo
      creatorID = batch.creatorID?.rawValue
      isCollapsed = batch.isCollapsed
      items = batch.items.map(ItemRecord.init)
    }

    var restoredBatch: ProfileImportBatch {
      ProfileImportBatch(
        id: id,
        createdAtMilliseconds: createdAtMilliseconds,
        downloadsVideo: downloadsVideo,
        creatorID: creatorID.flatMap(CreatorID.init),
        isCollapsed: isCollapsed,
        items: items.map(\.restoredItem)
      )
    }
  }

  private struct ItemRecord: Codable {
    let id: UUID
    let workID: String
    let authorID: String
    let canonicalURL: String
    let previewText: String?
    let publishedText: String?
    let likes: String?
    let comments: String?
    let collects: String?
    let status: String
    let message: String?
    let taskID: String?

    init(_ item: ProfileImportBatchItem) {
      id = item.id
      workID = item.seed.workID
      authorID = item.seed.authorID
      canonicalURL = item.seed.canonicalURL
      previewText = item.seed.previewText
      publishedText = item.seed.publishedText
      likes = item.seed.likes
      comments = item.seed.comments
      collects = item.seed.collects
      switch item.phase {
      case .queued: (status, message, taskID) = ("queued", nil, nil)
      case .fetching: (status, message, taskID) = ("fetching", nil, nil)
      case .saving: (status, message, taskID) = ("saving", nil, nil)
      case let .completed(id): (status, message, taskID) = ("completed", nil, id.rawValue)
      case let .failed(value): (status, message, taskID) = ("failed", value, nil)
      case .cancelled: (status, message, taskID) = ("cancelled", nil, nil)
      case .interrupted: (status, message, taskID) = ("interrupted", nil, nil)
      }
    }

    var restoredItem: ProfileImportBatchItem {
      ProfileImportBatchItem(
        id: id,
        seed: ProfileImportCandidateSeed(
          workID: workID,
          authorID: authorID,
          canonicalURL: canonicalURL,
          previewText: previewText,
          publishedText: publishedText,
          likes: likes,
          comments: comments,
          collects: collects
        ),
        phase: restoredPhase
      )
    }

    private var restoredPhase: ProfileImportBatchItemPhase {
      switch status {
      case "completed":
        if let taskID, let id = TaskID(taskID) { return .completed(id) }
        return .interrupted
      case "failed": return .failed(message ?? "上次抓取未完成，请重试。")
      case "cancelled": return .cancelled
      case "interrupted": return .interrupted
      // Work cannot continue across process termination. Never imply that an
      // old queued/fetching/saving operation is still running after restart.
      default: return .interrupted
      }
    }
  }
}
