import Foundation

public protocol HistoryIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
  var rawValue: String { get }
  init?(_ rawValue: String)
  init(_ uuid: UUID)
}

public extension HistoryIdentifier {
  init() { self.init(UUID()) }
  var description: String { rawValue }
}

private func canonicalUUID(_ value: String) -> String? {
  guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
  return value
}

public struct TaskID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) { guard let value = canonicalUUID(rawValue) else { return nil }; self.rawValue = value }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }
}

public struct ContentSnapshotID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) { guard let value = canonicalUUID(rawValue) else { return nil }; self.rawValue = value }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }
}

public struct RunID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) { guard let value = canonicalUUID(rawValue) else { return nil }; self.rawValue = value }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }
}

public struct ArtifactID: HistoryIdentifier {
  public let rawValue: String
  public init?(_ rawValue: String) { guard let value = canonicalUUID(rawValue) else { return nil }; self.rawValue = value }
  public init(_ uuid: UUID) { rawValue = uuid.uuidString.lowercased() }
}

public enum RunKind: String, Codable, Sendable, CaseIterable { case summarize, translate }
public enum RunStatus: String, Codable, Sendable, CaseIterable {
  case queued, running, completed, stopped, failed, interrupted
  public var isTerminal: Bool { [.completed, .stopped, .failed, .interrupted].contains(self) }
  public func canTransition(to next: RunStatus) -> Bool {
    switch (self, next) {
    case (.queued, .running), (.queued, .stopped), (.queued, .interrupted), (.queued, .failed),
         (.running, .completed), (.running, .stopped), (.running, .failed), (.running, .interrupted): true
    default: false
    }
  }
}
public enum ArtifactCompleteness: String, Codable, Sendable, CaseIterable { case complete, partial }
public enum ArtifactContentFormat: String, Codable, Sendable, CaseIterable { case plainText = "plain_text", markdown }

public struct RunUsageCost: Codable, Sendable, Equatable {
  public let inputTokens: Int64?
  public let outputTokens: Int64?
  public let totalTokens: Int64?
  public let costAmountMicros: Int64?
  public let costCurrencyCode: String?

  public init(
    inputTokens: Int64? = nil,
    outputTokens: Int64? = nil,
    totalTokens: Int64? = nil,
    costAmountMicros: Int64? = nil,
    costCurrencyCode: String? = nil
  ) throws {
    guard [inputTokens, outputTokens, totalTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
      throw HistoryDomainFailure.invalidUsageCost
    }
    guard (costAmountMicros == nil) == (costCurrencyCode == nil), (costAmountMicros ?? 0) >= 0 else {
      throw HistoryDomainFailure.invalidUsageCost
    }
    if let currency = costCurrencyCode {
      guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
        throw HistoryDomainFailure.invalidUsageCost
      }
    }
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.costAmountMicros = costAmountMicros
    self.costCurrencyCode = costCurrencyCode
  }

  public static let unknown = try! RunUsageCost()
}

public enum HistoryDomainFailure: Error, Sendable, Equatable {
  case invalidUsageCost
  case invalidStateTransition
  case invalidTerminalArtifact
  case invalidIdentifier
}

public struct HistoryTask: Codable, Sendable, Equatable {
  public let id: TaskID
  public let canonicalURL: String
  public let canonicalizationVersion: Int
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public init(id: TaskID, canonicalURL: String, canonicalizationVersion: Int, createdAtMilliseconds: Int64, updatedAtMilliseconds: Int64) {
    self.id = id; self.canonicalURL = canonicalURL; self.canonicalizationVersion = canonicalizationVersion; self.createdAtMilliseconds = createdAtMilliseconds; self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

public struct ContentSnapshot: Codable, Sendable, Equatable {
  public let id: ContentSnapshotID
  public let taskID: TaskID
  public let sequence: Int
  public let envelopeCreatedAtMilliseconds: Int64
  public let capturedAtMilliseconds: Int64
  public let sourceKind: String
  public let sourceURL: String
  public let title: String?
  public let platform: String
  public let captureMethod: String
  public let completeness: String
  public let bodyText: String
  public let characterCount: Int
  public let bodySHA256: String
  public let sourceLabel: String
  public let usedCookie: Bool
  public init(id: ContentSnapshotID, taskID: TaskID, sequence: Int, envelopeCreatedAtMilliseconds: Int64, capturedAtMilliseconds: Int64, sourceKind: String, sourceURL: String, title: String?, platform: String, captureMethod: String, completeness: String, bodyText: String, characterCount: Int, bodySHA256: String, sourceLabel: String, usedCookie: Bool) {
    self.id = id; self.taskID = taskID; self.sequence = sequence; self.envelopeCreatedAtMilliseconds = envelopeCreatedAtMilliseconds; self.capturedAtMilliseconds = capturedAtMilliseconds; self.sourceKind = sourceKind; self.sourceURL = sourceURL; self.title = title; self.platform = platform; self.captureMethod = captureMethod; self.completeness = completeness; self.bodyText = bodyText; self.characterCount = characterCount; self.bodySHA256 = bodySHA256; self.sourceLabel = sourceLabel; self.usedCookie = usedCookie
  }
}

public struct HistoryRun: Codable, Sendable, Equatable {
  public let id: RunID
  public let taskID: TaskID
  public let snapshotID: ContentSnapshotID
  public let idempotencyKey: String
  public let rerunOfRunID: RunID?
  public let kind: RunKind
  public let targetLanguage: String?
  public let status: RunStatus
  public let providerProfileID: String?
  public let providerKind: String?
  public let providerBaseURL: String?
  public let providerAPIMode: String?
  public let model: String?
  public let createdAtMilliseconds: Int64
  public let startedAtMilliseconds: Int64?
  public let finishedAtMilliseconds: Int64?
  public let failureCode: String?
  public let failureRetryable: Bool?
  public let usageCost: RunUsageCost
  public init(id: RunID, taskID: TaskID, snapshotID: ContentSnapshotID, idempotencyKey: String, rerunOfRunID: RunID?, kind: RunKind, targetLanguage: String?, status: RunStatus, providerProfileID: String?, providerKind: String?, providerBaseURL: String?, providerAPIMode: String?, model: String?, createdAtMilliseconds: Int64, startedAtMilliseconds: Int64?, finishedAtMilliseconds: Int64?, failureCode: String?, failureRetryable: Bool?, usageCost: RunUsageCost) {
    self.id = id; self.taskID = taskID; self.snapshotID = snapshotID; self.idempotencyKey = idempotencyKey; self.rerunOfRunID = rerunOfRunID; self.kind = kind; self.targetLanguage = targetLanguage; self.status = status; self.providerProfileID = providerProfileID; self.providerKind = providerKind; self.providerBaseURL = providerBaseURL; self.providerAPIMode = providerAPIMode; self.model = model; self.createdAtMilliseconds = createdAtMilliseconds; self.startedAtMilliseconds = startedAtMilliseconds; self.finishedAtMilliseconds = finishedAtMilliseconds; self.failureCode = failureCode; self.failureRetryable = failureRetryable; self.usageCost = usageCost
  }
}

public struct HistoryArtifact: Codable, Sendable, Equatable {
  public let id: ArtifactID
  public let runID: RunID
  public let contentFormat: ArtifactContentFormat
  public let completeness: ArtifactCompleteness
  public let bodyText: String
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public init(id: ArtifactID, runID: RunID, contentFormat: ArtifactContentFormat, completeness: ArtifactCompleteness, bodyText: String, createdAtMilliseconds: Int64, updatedAtMilliseconds: Int64) {
    self.id = id; self.runID = runID; self.contentFormat = contentFormat; self.completeness = completeness; self.bodyText = bodyText; self.createdAtMilliseconds = createdAtMilliseconds; self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

public struct ProviderRunMetadata: Codable, Sendable, Equatable {
  public let profileID: String?
  public let providerKind: String?
  public let baseURL: String?
  public let apiMode: String?
  public let model: String?

  public init(profileID: String? = nil, providerKind: String? = nil, baseURL: String? = nil, apiMode: String? = nil, model: String? = nil) {
    self.profileID = profileID
    self.providerKind = providerKind
    self.baseURL = baseURL
    self.apiMode = apiMode
    self.model = model
  }
}
