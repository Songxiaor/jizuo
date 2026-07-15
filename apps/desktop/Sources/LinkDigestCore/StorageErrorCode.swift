import Foundation

public enum StorageErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
  case unavailable = "STORAGE_UNAVAILABLE"
  case writeFailed = "STORAGE_WRITE_FAILED"
  case futureSchema = "STORAGE_FUTURE_SCHEMA"
  case migrationFailed = "STORAGE_MIGRATION_FAILED"
  case readOnly = "STORAGE_READ_ONLY"
  case integrityFailed = "STORAGE_INTEGRITY_FAILED"
  case stateConflict = "STORAGE_STATE_CONFLICT"
  case captureIdempotencyConflict = "CAPTURE_IDEMPOTENCY_CONFLICT"
  case runIdempotencyConflict = "RUN_IDEMPOTENCY_CONFLICT"
}

public enum StorageAvailability: Sendable, Equatable {
  case bootstrapping
  case writable
  case unavailable(StorageErrorCode)

  public var isWriteReady: Bool {
    self == .writable
  }

  public var code: StorageErrorCode? {
    guard case let .unavailable(code) = self else { return nil }
    return code
  }
}

public enum StorageFailureContext: Sendable, Equatable {
  case open
  case write
}

public struct StorageFailurePresentation: Sendable, Equatable {
  public let code: StorageErrorCode
  public let retryable: Bool
  public let action: String
  public let safeDetail: String?

  public init(code: StorageErrorCode, retryable: Bool, action: String, safeDetail: String? = nil) {
    self.code = code
    self.retryable = retryable
    self.action = action
    self.safeDetail = safeDetail
  }
}

public enum StorageErrorMapper {
  public static func map(
    _ failure: RepositoryFailure,
    context: StorageFailureContext
  ) -> StorageFailurePresentation {
    let code: StorageErrorCode = switch failure {
    case .unavailable, .injectedFailure:
      context == .open ? .unavailable : .writeFailed
    case let .readOnly(reason):
      switch reason {
      case .futureSchema: .futureSchema
      case .migrationFailed: .migrationFailed
      case .storageUnavailable: .readOnly
      }
    case .integrityCheckFailed: .integrityFailed
    case .captureIdempotencyConflict: .captureIdempotencyConflict
    case .runIdempotencyConflict: .runIdempotencyConflict
    case .invalidStateTransition, .notFound, .invalidInput: .stateConflict
    }
    return presentation(for: code)
  }

  public static func presentation(for code: StorageErrorCode) -> StorageFailurePresentation {
    switch code {
    case .unavailable, .writeFailed, .migrationFailed:
      .init(code: code, retryable: true, action: "retry")
    case .futureSchema:
      .init(code: code, retryable: false, action: "upgrade_app")
    case .readOnly, .integrityFailed, .stateConflict,
         .captureIdempotencyConflict, .runIdempotencyConflict:
      .init(code: code, retryable: false, action: "none")
    }
  }

  public static func mapUnknown(context: StorageFailureContext) -> StorageFailurePresentation {
    presentation(for: context == .open ? .unavailable : .writeFailed)
  }
}
