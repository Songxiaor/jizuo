import Foundation
import XCTest
@testable import LinkDigestCore
@testable import LinkDigestPersistence

/// 方法库的读写。
final class WritingMethodStoreTests: XCTestCase {
  private func method(_ body: String, enabled: Bool = true, at time: Int64 = 1) -> WritingMethod {
    .init(body: body, isEnabled: enabled, createdAtMilliseconds: time)
  }

  func testRoundTripsInInsertionOrder() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try repository.insertWritingMethod(method("先给结论再给证据", at: 1))
      try repository.insertWritingMethod(method("每段不超过三句", at: 2))
      XCTAssertEqual(
        try repository.writingMethods().map(\.body),
        ["先给结论再给证据", "每段不超过三句"]
      )
    }
  }

  /// 停用的也要读回来。
  ///
  /// 只返回启用的会让界面看不到停用的那些——用户就无法把它们重新打开，
  /// 只能再写一遍，而重写出来的是一条新记录。
  func testDisabledMethodsAreStillListed() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let one = method("先给结论再给证据")
      try repository.insertWritingMethod(one)
      try repository.setWritingMethodEnabled(false, for: one.id)

      let stored = try repository.writingMethods()
      XCTAssertEqual(stored.count, 1)
      XCTAssertFalse(stored.first?.isEnabled ?? true)
    }
  }

  func testOriginSurvives() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      try repository.insertWritingMethod(.init(
        body: "他总是把长句拆短", origin: .distilled, createdAtMilliseconds: 1
      ))
      XCTAssertEqual(try repository.writingMethods().first?.origin, .distilled)
    }
  }

  func testDeleteRemovesIt() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      let one = method("先给结论再给证据")
      try repository.insertWritingMethod(one)
      try repository.deleteWritingMethod(id: one.id)
      XCTAssertTrue(try repository.writingMethods().isEmpty)
    }
  }

  func testOperationsOnMissingMethodsFail() throws {
    try withTemporaryLocation { location in
      let repository = try GRDBHistoryRepository.open(at: location)
      defer { try? repository.database.close() }

      XCTAssertThrowsError(try repository.deleteWritingMethod(id: UUID())) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }
      XCTAssertThrowsError(try repository.setWritingMethodEnabled(false, for: UUID())) {
        XCTAssertEqual($0 as? RepositoryFailure, .notFound)
      }
    }
  }
}
