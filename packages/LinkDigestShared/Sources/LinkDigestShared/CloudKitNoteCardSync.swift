import CloudKit
import Foundation
import Security

/// CloudKit 私有库双向同步：拉 → 与本地合并 → 推差异。
///
/// - 不读写 API Key
/// - 软删除以墓碑字段同步（`deletedAtMilliseconds`），不物理删远端记录
/// - 可通过 `database` 注入 Fake，供无网络单测
public struct CloudKitNoteCardSync: NoteCardSyncing {
  public static let recordType = "NoteCard"
  public static let defaultContainerIdentifier = "iCloud.com.syc.linkdigest"

  public enum Field: String {
    case id
    case kind
    case title
    case body
    case summary
    case translation
    case transcript
    case transcriptionRequestedAtMilliseconds
    case sourceURL
    case createdAtMilliseconds
    case updatedAtMilliseconds
    case deletedAtMilliseconds
    case schemaVersion
  }

  public enum SyncError: Error, Sendable, Equatable {
    case containerUnavailable(String)
    case decodeFailed(String)
  }

  private let containerIdentifier: String
  private let enabled: Bool
  private let database: (any CloudKitNoteDatabase)?
  private let checksAccountStatus: Bool

  /// - Parameters:
  ///   - enabled: false 时只返回可读失败，不访问网络。
  ///   - database: 注入假库或自定义库；nil 且 enabled 时用 Live CloudKit。
  ///   - checksAccountStatus: 仅对真库做 iCloud 账户探测；Fake 测试关掉。
  public init(
    containerIdentifier: String = CloudKitNoteCardSync.defaultContainerIdentifier,
    enabled: Bool = false,
    database: (any CloudKitNoteDatabase)? = nil,
    checksAccountStatus: Bool = true
  ) {
    self.containerIdentifier = containerIdentifier
    self.enabled = enabled
    self.database = database
    self.checksAccountStatus = checksAccountStatus
  }

  public func synchronize(local: NoteCardStore) async throws -> NoteSyncStatus {
    guard enabled else {
      return NoteSyncStatus(
        phase: .failed,
        lastSuccessAtMilliseconds: nil,
        lastErrorMessage: "手机与 Mac 的 iCloud 同步尚未开通：需要付费 Apple Developer 账号，并在系统设置登录同一 Apple ID。当前笔记只保存在本机。"
      )
    }

    let db: any CloudKitNoteDatabase
    if let database {
      db = database
    } else {
      // 无 iCloud entitlement 时 CKContainer(identifier:) 会 _os_crash，catch 不住。
      do {
        db = try LiveCloudKitNoteDatabase.make(containerIdentifier: containerIdentifier)
      } catch {
        return NoteSyncStatus(
          phase: .failed,
          lastSuccessAtMilliseconds: nil,
          lastErrorMessage: CloudKitCapability.unavailableMessage(
            containerIdentifier: containerIdentifier
          )
        )
      }
    }

    if checksAccountStatus, database == nil {
      if let accountFailure = await accountStatusFailure() {
        return accountFailure
      }
    }

    do {
      let remoteBefore = try await db.fetchAllNoteCards()
      let localCards = try await local.list(includeDeleted: true)
      let merged = NoteCardSyncPlanner.mergeUniverse(local: localCards, remote: remoteBefore)

      for card in merged {
        try await local.upsert(card)
      }

      let toPush = NoteCardSyncPlanner.cardsNeedingPush(merged: merged, remoteBefore: remoteBefore)
      if !toPush.isEmpty {
        try await db.saveNoteCards(toPush)
      }

      return NoteSyncStatus(
        phase: .idle,
        lastSuccessAtMilliseconds: SyncNoteCardFactory.nowMilliseconds(),
        lastErrorMessage: nil
      )
    } catch {
      return NoteSyncStatus(
        phase: .failed,
        lastSuccessAtMilliseconds: nil,
        lastErrorMessage: friendlyMessage(for: error)
      )
    }
  }

  private func accountStatusFailure() async -> NoteSyncStatus? {
    let container = CKContainer(identifier: containerIdentifier)
    do {
      let status = try await container.accountStatus()
      guard status == .available else {
        return NoteSyncStatus(
          phase: .failed,
          lastSuccessAtMilliseconds: nil,
          lastErrorMessage: "iCloud 账户不可用（status=\(String(describing: status))）。请在系统设置登录 Apple ID 并开启 iCloud。"
        )
      }
      return nil
    } catch {
      return NoteSyncStatus(
        phase: .failed,
        lastSuccessAtMilliseconds: nil,
        lastErrorMessage: "无法检查 iCloud 状态：\(error.localizedDescription)"
      )
    }
  }

  private func friendlyMessage(for error: Error) -> String {
    if let ckError = error as? CKError {
      switch ckError.code {
      case .notAuthenticated:
        return "未登录 iCloud。请在系统设置登录 Apple ID。"
      case .networkUnavailable, .networkFailure:
        return "网络不可用，稍后再同步。"
      case .quotaExceeded:
        return "iCloud 存储空间不足。"
      case .serverRejectedRequest:
        return "CloudKit 拒绝请求：请确认 App 已打开 iCloud(CloudKit) 且容器为 \(containerIdentifier)。"
      default:
        return "CloudKit 同步失败：\(ckError.localizedDescription)"
      }
    }
    return "同步失败：\(error.localizedDescription)"
  }

  public static func makeRecord(from card: SyncNoteCard, zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
    try SyncNoteCardValidator.validate(card)
    let recordID = CKRecord.ID(recordName: card.id.uuidString.lowercased(), zoneID: zoneID ?? .default)
    let record = CKRecord(recordType: recordType, recordID: recordID)
    try apply(card, to: record)
    return record
  }

  public static func apply(_ card: SyncNoteCard, to record: CKRecord) throws {
    try SyncNoteCardValidator.validate(card)
    record[Field.id.rawValue] = card.id.uuidString.lowercased() as CKRecordValue
    record[Field.kind.rawValue] = card.kind.rawValue as CKRecordValue
    record[Field.title.rawValue] = card.title as CKRecordValue
    record[Field.body.rawValue] = card.body as CKRecordValue
    if let summary = card.summary {
      record[Field.summary.rawValue] = summary as CKRecordValue
    } else {
      record[Field.summary.rawValue] = nil
    }
    if let translation = card.translation {
      record[Field.translation.rawValue] = translation as CKRecordValue
    } else {
      record[Field.translation.rawValue] = nil
    }
    if let transcript = card.transcript {
      record[Field.transcript.rawValue] = transcript as CKRecordValue
    } else {
      record[Field.transcript.rawValue] = nil
    }
    if let requested = card.transcriptionRequestedAtMilliseconds {
      record[Field.transcriptionRequestedAtMilliseconds.rawValue] = NSNumber(value: requested)
    } else {
      record[Field.transcriptionRequestedAtMilliseconds.rawValue] = nil
    }
    if let sourceURL = card.sourceURL {
      record[Field.sourceURL.rawValue] = sourceURL as CKRecordValue
    } else {
      record[Field.sourceURL.rawValue] = nil
    }
    record[Field.createdAtMilliseconds.rawValue] = NSNumber(value: card.createdAtMilliseconds)
    record[Field.updatedAtMilliseconds.rawValue] = NSNumber(value: card.updatedAtMilliseconds)
    if let deleted = card.deletedAtMilliseconds {
      record[Field.deletedAtMilliseconds.rawValue] = NSNumber(value: deleted)
    } else {
      record[Field.deletedAtMilliseconds.rawValue] = nil
    }
    record[Field.schemaVersion.rawValue] = NSNumber(value: card.schemaVersion)
  }

  public static func makeCard(from record: CKRecord) throws -> SyncNoteCard {
    guard record.recordType == recordType else {
      throw SyncError.decodeFailed("unexpected record type \(record.recordType)")
    }
    guard
      let idString = record[Field.id.rawValue] as? String,
      let id = UUID(uuidString: idString),
      let kindRaw = record[Field.kind.rawValue] as? String,
      let kind = SyncNoteCard.Kind(rawValue: kindRaw),
      let title = record[Field.title.rawValue] as? String,
      let body = record[Field.body.rawValue] as? String,
      let created = (record[Field.createdAtMilliseconds.rawValue] as? NSNumber)?.int64Value,
      let updated = (record[Field.updatedAtMilliseconds.rawValue] as? NSNumber)?.int64Value,
      let schema = (record[Field.schemaVersion.rawValue] as? NSNumber)?.intValue
    else {
      throw SyncError.decodeFailed("NoteCard record missing required fields")
    }

    let card = SyncNoteCard(
      id: id,
      kind: kind,
      title: title,
      body: body,
      summary: record[Field.summary.rawValue] as? String,
      translation: record[Field.translation.rawValue] as? String,
      transcript: record[Field.transcript.rawValue] as? String,
      transcriptionRequestedAtMilliseconds:
        (record[Field.transcriptionRequestedAtMilliseconds.rawValue] as? NSNumber)?.int64Value,
      sourceURL: record[Field.sourceURL.rawValue] as? String,
      createdAtMilliseconds: created,
      updatedAtMilliseconds: updated,
      deletedAtMilliseconds: (record[Field.deletedAtMilliseconds.rawValue] as? NSNumber)?.int64Value,
      schemaVersion: schema
    )
    try SyncNoteCardValidator.validate(card)
    return card
  }
}

/// 探测当前进程签名是否带指定 CloudKit 容器。
///
/// `CKContainer(identifier:)` 在缺 entitlement 时会 `_os_crash`（SIGTRAP），
/// 不是可 catch 的 Swift Error。调用真库前必须先过这一关。
public enum CloudKitCapability: Sendable {
  public static func isContainerEntitled(
    _ identifier: String = CloudKitNoteCardSync.defaultContainerIdentifier
  ) -> Bool {
    guard let entitlements = embeddedEntitlements() else { return false }
    let containers =
      stringList(entitlements["com.apple.developer.icloud-container-identifiers"])
      + stringList(
        entitlements["com.apple.developer.icloud-container-development-container-identifiers"]
      )
    let services = stringList(entitlements["com.apple.developer.icloud-services"])
    return containers.contains(identifier) && services.contains("CloudKit")
  }

  public static func unavailableMessage(
    containerIdentifier: String = CloudKitNoteCardSync.defaultContainerIdentifier
  ) -> String {
    "当前签名没有 iCloud(CloudKit) 容器 \(containerIdentifier)，已跳过同步以免闪退。真开通需要付费 Apple Developer 证书。"
  }

  private static func embeddedEntitlements() -> [String: Any]? {
    #if os(macOS)
    var me: SecCode?
    guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &me) == errSecSuccess, let me else {
      return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(me, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &info
      ) == errSecSuccess,
      let info
    else {
      return nil
    }
    let dict = info as NSDictionary
    return dict[kSecCodeInfoEntitlementsDict] as? [String: Any]
    #else
    // SecCode* 仅 macOS；iOS 端由 App 启动时显式 enabled + entitlements 文件控制，避免误触 CKContainer。
    return nil
    #endif
  }

  private static func stringList(_ value: Any?) -> [String] {
    if let list = value as? [String] {
      return list
    }
    if let single = value as? String {
      return [single]
    }
    return []
  }
}
