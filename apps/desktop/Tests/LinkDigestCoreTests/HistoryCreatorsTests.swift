import XCTest
@testable import LinkDigestCore

final class HistoryCreatorsTests: XCTestCase {
  func testIdentityRejectsEmptyAuthorIDAndDoesNotUseNickname() {
    XCTAssertNil(CreatorIdentity(platform: "douyin.com", authorID: "  "))
    XCTAssertEqual(
      CreatorIdentity(platform: "www.douyin.com", authorID: "MS4wLjABAAAA-a")?.platform,
      "douyin.com"
    )
    let left = CreatorIdentity(platform: "douyin.com", authorID: "id-a")
    let right = CreatorIdentity(platform: "x.com", authorID: "id-a")
    XCTAssertNotEqual(left, right)
  }

  func testUntitledPlaceholderDoesNotUseNicknameAsIdentity() {
    XCTAssertEqual(CreatorDisplay.placeholderName(platform: "douyin.com"), "未命名抖音博主")
    let identity = CreatorIdentity(platform: "douyin.com", authorID: "MS4wLjABAAAA-x")!
    let summary = CreatorSummary(
      id: CreatorID(),
      identity: identity,
      profileURL: "https://www.douyin.com/user/MS4wLjABAAAA-x",
      displayName: nil,
      pinnedRank: nil,
      savedWorkCount: 0,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    XCTAssertEqual(summary.listingTitle, "未命名抖音博主")
    XCTAssertFalse(summary.hasResolvedDisplayName)
    XCTAssertEqual(summary.directoryDisplayName, "待获取")
  }

  func testDirectoryNameRejectsHandleAndKeepsRealDisplayName() {
    let identity = CreatorIdentity(platform: "x.com", authorID: "thedankoe")!
    let handle = CreatorSummary(
      id: CreatorID(),
      identity: identity,
      profileURL: "https://x.com/thedankoe",
      displayName: "@thedankoe",
      pinnedRank: nil,
      savedWorkCount: 0,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    XCTAssertFalse(handle.hasResolvedDisplayName)
    XCTAssertEqual(handle.directoryDisplayName, "待获取")
    let named = CreatorSummary(
      id: CreatorID(),
      identity: identity,
      profileURL: "https://x.com/thedankoe",
      displayName: "DAN KOE",
      pinnedRank: nil,
      savedWorkCount: 4,
      createdAtMilliseconds: 1,
      updatedAtMilliseconds: 1
    )
    XCTAssertTrue(named.hasResolvedDisplayName)
    XCTAssertEqual(named.directoryDisplayName, "DAN KOE")
  }

  func testHistoryListFilterCarriesCreatorWithoutTreatingNicknameAsHost() {
    let creatorID = CreatorID()
    let filter = HistoryListFilter(hosts: ["douyin.com"], creatorID: creatorID)
    XCTAssertEqual(filter.hosts, ["douyin.com"])
    XCTAssertEqual(filter.creatorID, creatorID)
    XCTAssertNotEqual(filter, .none)
  }
}
