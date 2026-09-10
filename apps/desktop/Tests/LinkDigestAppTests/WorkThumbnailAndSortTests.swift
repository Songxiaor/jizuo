import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import LinkDigestApp

private actor ThumbnailFetchProbe {
  let data: Data
  var calls = 0
  var active = 0
  var peak = 0
  var failures: Int
  init(data: Data, failures: Int = 0) { self.data = data; self.failures = failures }
  func fetch(_ url: URL) async throws -> Data {
    calls += 1; active += 1; peak = max(peak, active)
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(40))
    if failures > 0 { failures -= 1; throw CocoaError(.fileReadUnknown) }
    return data
  }
}

@MainActor
final class WorkThumbnailAndSortTests: XCTestCase {
  private func png() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 1200,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func testThumbnailsPersistToDiskAcrossLoaderInstances() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("thumb-disk-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://images.example.test/persist.png")!
    let probe = ThumbnailFetchProbe(data: try png())
    let first = WorkThumbnailLoader(diskDirectory: directory, fetch: { try await probe.fetch($0) })
    let fetched = try await first.image(url: url, pixels: 256)
    let file = WorkThumbnailLoader.diskFileURL(directory: directory, url: url, pixels: 256)
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "封面缩略图应落盘")

    let offline = WorkThumbnailLoader(diskDirectory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) })
    let restored = try await offline.image(url: url, pixels: 256)
    XCTAssertEqual(restored.image.width, fetched.image.width)
    let calls = await probe.calls
    XCTAssertEqual(calls, 1)
  }

  func testDuplicateThumbnailRequestsShareDownloadAndDecodedCache() async throws {
    let probe = ThumbnailFetchProbe(data: try png())
    let loader = WorkThumbnailLoader(fetch: { try await probe.fetch($0) })
    let url = URL(string: "https://images.example.test/a.png")!
    async let a = loader.image(url: url, pixels: 256)
    async let b = loader.image(url: url, pixels: 256)
    let (first, _) = try await (a, b)
    _ = try await loader.image(url: url, pixels: 256)
    let calls = await probe.calls
    XCTAssertEqual(calls, 1)
    XCTAssertLessThanOrEqual(first.image.width, 256)
    XCTAssertLessThanOrEqual(first.image.height, 256)
    XCTAssertLessThanOrEqual(first.cost, 256 * 256 * 4)
  }

  func testCancellingOneCardDoesNotCancelAnotherCardUsingSameImage() async throws {
    let probe = ThumbnailFetchProbe(data: try png())
    let loader = WorkThumbnailLoader(fetch: { try await probe.fetch($0) })
    let url = URL(string: "https://images.example.test/shared.png")!
    let first = Task { try await loader.image(url: url) }
    let second = Task { try await loader.image(url: url) }
    for _ in 0..<20 {
      if await loader.inFlightSubscriberCount == 2 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let subscribers = await loader.inFlightSubscriberCount
    XCTAssertEqual(subscribers, 2)
    first.cancel()
    let image = try await second.value
    XCTAssertGreaterThan(image.cost, 0)
    do { _ = try await first.value; XCTFail("Cancelled card must not paint") }
    catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
    let calls = await probe.calls
    XCTAssertEqual(calls, 1)
  }

  func testThumbnailConcurrencyAndMemoryAreBounded() async throws {
    let probe = ThumbnailFetchProbe(data: try png())
    let loader = WorkThumbnailLoader(concurrency: 2, budget: 150_000, fetch: { try await probe.fetch($0) })
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          _ = try await loader.image(url: URL(string: "https://images.example.test/\(index).png")!, pixels: 256)
        }
      }
      try await group.waitForAll()
    }
    let peak = await probe.peak
    let bytes = await loader.cachedByteCount
    XCTAssertEqual(peak, 2)
    XCTAssertLessThanOrEqual(bytes, 150_000)
  }

  func testVideoPosterRejectsSymlinkAndNonHashedPath() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("payload.mp4")
    try Data([0, 0, 0, 0]).write(to: outside)
    let hashed = String(repeating: "ab", count: 32) + ".mp4"
    let link = root.appendingPathComponent(hashed)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertNil(WorkThumbnailLoader.containedInternalVideoFile(link))
    XCTAssertNil(WorkThumbnailLoader.containedInternalVideoFile(outside))
    let loader = WorkThumbnailLoader(fetch: { _ in Data() })
    do {
      _ = try await loader.videoPoster(fileURL: link)
      XCTFail("symlink poster must fail closed")
    } catch {}
    do {
      _ = try await loader.videoPoster(fileURL: outside)
      XCTFail("non-hashed poster must fail closed")
    } catch {}
  }

  func testFailedThumbnailCanRetryAndCancelledCallerDoesNotReceiveImage() async throws {
    let probe = ThumbnailFetchProbe(data: try png(), failures: 1)
    let loader = WorkThumbnailLoader(fetch: { try await probe.fetch($0) })
    let url = URL(string: "https://images.example.test/retry.png")!
    do { _ = try await loader.image(url: url); XCTFail("Expected failure") } catch {}
    _ = try await loader.image(url: url)
    let calls = await probe.calls
    XCTAssertEqual(calls, 2)
    let pending = Task { try await loader.image(url: URL(string: "https://images.example.test/cancel.png")!) }
    pending.cancel()
    do { _ = try await pending.value; XCTFail("Cancelled task must not paint") }
    catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
  }

  func testMetricUnitsZeroUnknownAndStableTies() {
    let inputs = ["0", "1.2万", "2.5w", "3K", "1M", "1,234", "—", "NaN", "-1"]
    let actual = inputs.map(WorkSortOrder.metric)
    XCTAssertEqual(actual, [0, 12_000, 25_000, 3_000, 1_000_000, 1_234, nil, nil, nil])
    let values: [(String, String?)] = [("unknown", nil), ("zero", "0"), ("a", "2万"), ("b", "20000"), ("dash", "—")]
    XCTAssertEqual(WorkSortOrder.mostLiked.sorted(values, likes: { $0.1 }, published: { _ in nil }).map(\.0), ["a", "b", "zero", "unknown", "dash"])
    XCTAssertEqual(WorkSortOrder.leastLiked.sorted(values, likes: { $0.1 }, published: { _ in nil }).map(\.0), ["zero", "a", "b", "unknown", "dash"])
    XCTAssertEqual(WorkSortOrder.original.sorted(values, likes: { $0.1 }, published: { _ in nil }).map(\.0), values.map(\.0))
  }

  func testDateOrderUsesPublishedValuesAndExplicitReferenceForYearlessDates() {
    let values = ["unknown", "2026年8月31日 22:54", "2026-09-01T10:00:00Z", "1月13日"]
    XCTAssertEqual(WorkSortOrder.newest.sorted(values, likes: { _ in nil }, published: { $0 }), [values[2], values[1], values[0], values[3]])
    let reference = ISO8601DateFormatter().date(from: "2026-09-08T10:00:00Z")!
    XCTAssertEqual(WorkSortOrder.oldest.sorted(values, likes: { _ in nil }, published: { $0 }, referenceDate: reference), [values[3], values[1], values[2], values[0]])
  }
}
