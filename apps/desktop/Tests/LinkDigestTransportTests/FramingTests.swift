import XCTest
@testable import LinkDigestTransport

final class FramingTests: XCTestCase {
  func testRoundTripAndLimits() throws { let frame = try ChromiumFramer.encode(["ok": true]); XCTAssertGreaterThan(frame.count, 4) }
  func testRejectZeroAndTruncated() { XCTAssertThrowsError(try ChromiumFramer.decode(Data([0,0,0,0]), as: [String: Bool].self)); XCTAssertThrowsError(try ChromiumFramer.decode(Data([1,0]), as: [String: Bool].self)) }

  func testReadFrameAcceptsPartialPipeWrites() throws {
    let pipe = Pipe()
    let body = try JSONEncoder().encode(["ok": true])
    var length = UInt32(body.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(body)
    let completeFrame = frame
    Thread.detachNewThread {
      for byte in completeFrame {
        try? pipe.fileHandleForWriting.write(contentsOf: Data([byte]))
      }
      try? pipe.fileHandleForWriting.close()
    }
    XCTAssertEqual(try ChromiumFramer.readFrame(from: pipe.fileHandleForReading), body)
  }

  func testReadFrameRejectsOversizedHeaderBeforeBody() {
    let pipe = Pipe()
    var length = UInt32(ChromiumFramer.maxFrameBytes + 1).littleEndian
    try? pipe.fileHandleForWriting.write(contentsOf: Data(bytes: &length, count: 4))
    try? pipe.fileHandleForWriting.close()
    XCTAssertThrowsError(try ChromiumFramer.readFrame(from: pipe.fileHandleForReading)) {
      guard case FramingError.tooLarge = $0 else { return XCTFail("Expected tooLarge, got \($0)") }
    }
  }

  func testReadFrameTimesOutOnAStalledPartialMessage() {
    let pipe = Pipe()
    try? pipe.fileHandleForWriting.write(contentsOf: Data([8, 0, 0, 0, 123]))
    XCTAssertThrowsError(try ChromiumFramer.readFrame(from: pipe.fileHandleForReading, timeout: 0.02)) {
      guard case FramingError.timeout = $0 else { return XCTFail("Expected timeout, got \($0)") }
    }
    try? pipe.fileHandleForWriting.close()
  }
}
