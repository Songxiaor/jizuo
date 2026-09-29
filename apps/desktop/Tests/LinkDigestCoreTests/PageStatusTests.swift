import XCTest
@testable import LinkDigestCore

/// 扩展弹窗查重 / 看进度的消息（2026-09-29 弹窗重构）。
final class PageStatusTests: XCTestCase {
  func testRequestDecodingClaimsOnlyItsOwnKindAndNeedsAWebAddress() throws {
    XCTAssertNil(try PageStatusRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r"}"#.utf8)))
    let request = try PageStatusRequest.decode(Data(#"{"kind":"pageStatus","version":1,"requestId":"r-1","url":"https://x.com/a/status/1"}"#.utf8))
    XCTAssertEqual(request, PageStatusRequest(requestId: "r-1", url: "https://x.com/a/status/1"))
    XCTAssertThrowsError(try PageStatusRequest.decode(Data(#"{"kind":"pageStatus","version":2,"requestId":"r","url":"https://a.test"}"#.utf8)))
    XCTAssertThrowsError(try PageStatusRequest.decode(Data(#"{"kind":"pageStatus","version":1,"requestId":"r","url":"file:///etc/hosts"}"#.utf8)))
    XCTAssertThrowsError(try PageStatusRequest.decode(Data(#"{"kind":"pageStatus","version":1,"url":"https://a.test"}"#.utf8)))
  }

  func testResponseRoundTripsAndIsNotABrowserDelivery() throws {
    let response = NativeResponse.pageStatus(version: 1, requestId: "r", status: PageStatusPayload(
      found: true,
      taskID: "40847250-39d8-4983-a3b6-e44c9bd8122c",
      savedAtMilliseconds: 1_790_000_000_000,
      steps: [
        PageStepStatus(step: "record", state: .done),
        PageStepStatus(step: "comments", state: .done, detail: "存了 20 条"),
        PageStepStatus(step: "summary", state: .running, detail: "总结中"),
      ]
    ))
    let data = try JSONEncoder().encode(response)
    XCTAssertEqual(try JSONDecoder().decode(NativeResponse.self, from: data), response)
    XCTAssertFalse(response.isSuccessfulBrowserDelivery)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "pageStatus")
    let status = try XCTUnwrap(object["status"] as? [String: Any])
    XCTAssertEqual(status["found"] as? Bool, true)
  }

  func testNotFoundCarriesNoTask() throws {
    let data = try JSONEncoder().encode(NativeResponse.pageStatus(version: 1, requestId: "r", status: .notFound))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let status = try XCTUnwrap(object["status"] as? [String: Any])
    XCTAssertEqual(status["found"] as? Bool, false)
    XCTAssertNil(status["taskID"])
  }

  func testOpenAppCanJumpToOneItemButOnlyWithAValidTaskID() throws {
    let plain = try OpenAppRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r"}"#.utf8))
    XCTAssertNil(plain?.deepLink)
    let jump = try OpenAppRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r","taskID":"40847250-39D8-4983-A3B6-E44C9BD8122C"}"#.utf8))
    XCTAssertEqual(jump?.deepLink?.absoluteString, "linkdigest://digest/40847250-39d8-4983-a3b6-e44c9bd8122c")
    XCTAssertThrowsError(try OpenAppRequest.decode(Data(#"{"kind":"openApp","version":1,"requestId":"r","taskID":"../../etc"}"#.utf8)))
  }
}
