import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// CGImage is immutable; AppKit images are created only by the receiving view.
struct WorkThumbnail: @unchecked Sendable {
  let image: CGImage
  var cost: Int { image.bytesPerRow * image.height }
}

/// Bounded, shared thumbnails; transport policy stays in the existing safe fetcher.
actor WorkThumbnailLoader {
  static let shared = WorkThumbnailLoader(diskDirectory: defaultDiskDirectory())
  typealias Fetch = @Sendable (URL) async throws -> Data
  private struct Cached { let value: WorkThumbnail; var accessed: UInt64 }
  private struct Flight {
    let id: UUID
    let task: Task<WorkThumbnail, Error>
    var subscribers: Set<UUID>
  }
  private let fetch: Fetch
  private let concurrency: Int
  private let budget: Int
  /// 封面下载并缩到 640px 后落盘；下次打开 App 直接读本地，不再等网络。
  /// nil 表示只用内存（测试用）。
  private let diskDirectory: URL?
  private var cache: [String: Cached] = [:]
  private var flights: [String: Flight] = [:]
  private var clock: UInt64 = 0
  private var cost = 0
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(concurrency: Int = 3, budget: Int = 32 * 1_024 * 1_024,
       diskDirectory: URL? = nil,
       fetch: @escaping Fetch = { try await DouyinProfilePreviewResource.fetch($0) }) {
    self.concurrency = max(1, concurrency)
    self.budget = max(0, budget)
    self.diskDirectory = diskDirectory
    self.fetch = fetch
  }

  /// `~/Library/Application Support/LinkDigest/Thumbnails`，和数据库同一个家目录，不会被系统当缓存清掉。
  nonisolated static func defaultDiskDirectory() -> URL? {
    guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    return root
      .appendingPathComponent("LinkDigest", isDirectory: true)
      .appendingPathComponent("Thumbnails", isDirectory: true)
  }

  nonisolated static func diskFileURL(directory: URL, url: URL, pixels: Int) -> URL {
    let digest = SHA256.hash(data: Data("\(url.absoluteString)#\(pixels)".utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".jpg", isDirectory: false)
  }

  nonisolated private static func readDisk(directory: URL?, url: URL, pixels: Int) -> WorkThumbnail? {
    guard let directory else { return nil }
    let file = diskFileURL(directory: directory, url: url, pixels: pixels)
    guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
    return try? decode(data, pixels: pixels)
  }

  nonisolated private static func writeDisk(directory: URL?, url: URL, pixels: Int, image: CGImage) {
    guard let directory else { return }
    let file = diskFileURL(directory: directory, url: url, pixels: pixels)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return }
    try? (data as Data).write(to: file, options: .atomic)
  }

  func videoPoster(fileURL: URL, pixels: Int = 640) async throws -> WorkThumbnail {
    try Task.checkCancellation()
    guard let contained = Self.containedInternalVideoFile(fileURL) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let size = min(1_024, max(64, pixels))
    let key = "video-poster:\(contained.path)#\(size)"
    clock &+= 1
    if var hit = cache[key] {
      hit.accessed = clock
      cache[key] = hit
      return hit.value
    }
    let value = try await Task.detached(priority: .utility) {
      try Self.decodeVideoPoster(fileURL: contained, pixels: size)
    }.value
    try Task.checkCancellation()
    store(value, key: key)
    return value
  }

  func image(url: URL, localURL: URL? = nil, pixels: Int = 640) async throws -> WorkThumbnail {
    try Task.checkCancellation()
    let size = min(1_024, max(64, pixels))
    let key = "\(localURL?.path ?? url.absoluteString)#\(size)"
    clock &+= 1
    if var hit = cache[key] {
      hit.accessed = clock
      cache[key] = hit
      return hit.value
    }
    let subscriber = UUID()
    let flight: Flight
    if var existing = flights[key] {
      existing.subscribers.insert(subscriber)
      flights[key] = existing
      flight = existing
    } else {
      let id = UUID()
      let task = Task { [self] in
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let localURL {
          let local = Task.detached(priority: .utility) {
            guard let bytes = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  bytes <= 20 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: localURL),
                  let value = try? Self.decode(data, pixels: size) else { return nil as WorkThumbnail? }
            return value
          }
          if let value = await local.value { try Task.checkCancellation(); return value }
        }
        let directory = diskDirectory
        let stored = await Task.detached(priority: .utility) {
          Self.readDisk(directory: directory, url: url, pixels: size)
        }.value
        if let stored { try Task.checkCancellation(); return stored }
        let data = try await fetch(url)
        try Task.checkCancellation()
        let value = try await Task.detached(priority: .utility) {
          try Self.decode(data, pixels: size)
        }.value
        try Task.checkCancellation()
        let image = value.image
        Task.detached(priority: .background) {
          Self.writeDisk(directory: directory, url: url, pixels: size, image: image)
        }
        return value
      }
      flight = Flight(id: id, task: task, subscribers: [subscriber])
      flights[key] = flight
    }
    return try await withTaskCancellationHandler {
      do {
        let value = try await flight.task.value
        if flights[key]?.id == flight.id {
          flights.removeValue(forKey: key)
          store(value, key: key)
        }
        try Task.checkCancellation()
        return value
      } catch {
        if flights[key]?.id == flight.id { flights.removeValue(forKey: key) }
        throw error
      }
    } onCancel: {
      Task { await self.cancel(key: key, flightID: flight.id, subscriber: subscriber) }
    }
  }

  private func cancel(key: String, flightID: UUID, subscriber: UUID) {
    guard var flight = flights[key], flight.id == flightID else { return }
    flight.subscribers.remove(subscriber)
    if flight.subscribers.isEmpty {
      flights.removeValue(forKey: key)
      flight.task.cancel()
    } else { flights[key] = flight }
  }

  private func acquire() async {
    if active < concurrency { active += 1; return }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if !waiters.isEmpty { waiters.removeFirst().resume() }
    else { active -= 1 }
  }

  private func store(_ value: WorkThumbnail, key: String) {
    guard value.cost <= budget else { return }
    while cost + value.cost > budget || cache.count >= 64 {
      guard let oldest = cache.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
      cost -= oldest.value.value.cost
      cache.removeValue(forKey: oldest.key)
    }
    clock &+= 1
    cache[key] = Cached(value: value, accessed: clock)
    cost += value.cost
  }

  var cachedByteCount: Int { cost }
  var inFlightSubscriberCount: Int { flights.values.reduce(0) { $0 + $1.subscribers.count } }

  /// Gallery posters only accept this task's hashed `Media/` file: 64 hex
  /// chars, mp4/mov, regular file, never a symlink or an escaped path.
  nonisolated static func containedInternalVideoFile(_ fileURL: URL) -> URL? {
    guard fileURL.isFileURL else { return nil }
    let name = fileURL.lastPathComponent
    guard name == fileURL.standardizedFileURL.lastPathComponent,
          name.range(of: #"^[0-9a-f]{64}\.(mp4|mov)$"#, options: .regularExpression) != nil
    else { return nil }
    let url = fileURL.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
    return url
  }

  nonisolated static func decodeVideoPoster(fileURL: URL, pixels: Int) throws -> WorkThumbnail {
    let asset = AVURLAsset(url: fileURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let edge = CGFloat(min(1_024, max(64, pixels)))
    generator.maximumSize = CGSize(width: edge, height: edge)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
    var actual = CMTime.zero
    let image = try generator.copyCGImage(at: CMTime(seconds: 0.05, preferredTimescale: 600), actualTime: &actual)
    return WorkThumbnail(image: image)
  }

  nonisolated static func decode(_ data: Data, pixels: Int) throws -> WorkThumbnail {
    guard let source = CGImageSourceCreateWithData(data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(1_024, max(64, pixels)),
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
    return WorkThumbnail(image: image)
  }
}
