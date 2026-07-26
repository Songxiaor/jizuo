import AVFoundation
import Foundation
import LinkDigestCore

public struct TranscriptionTempFile: Sendable, Equatable {
  public let attemptID: String
  public let workspaceURL: URL
  public let fileURL: URL
  public let durationSeconds: Double?

  public init(attemptID: String, workspaceURL: URL, fileURL: URL, durationSeconds: Double?) {
    self.attemptID = attemptID
    self.workspaceURL = workspaceURL
    self.fileURL = fileURL
    self.durationSeconds = durationSeconds
  }
}

public struct TranscriptionAttemptWorkspace: Sendable, Equatable {
  public let attemptID: String
  public let directoryURL: URL

  public var extractedAudioURL: URL {
    directoryURL.appendingPathComponent("extracted-audio.m4a", isDirectory: false)
  }
}

public enum TranscriptionTempStoreError: Error, Sendable, Equatable {
  case unavailable
  case insufficientDiskSpace
  case cleanupFailed(String)

  public var userMessage: String {
    switch self {
    case .unavailable:
      "无法准备转写临时媒体，请检查网络、格式和磁盘空间后重试。"
    case .insufficientDiskSpace:
      "本机磁盘空间不足，无法准备最多 2GB 的临时转写媒体。请释放空间后重试。"
    case .cleanupFailed:
      "转写已结束，但临时媒体清理失败。请点击“重试清理”，避免文件继续占用空间。"
    }
  }
}

/// Attempt-scoped transient media. Files never enter `Media/`, never produce a
/// `MediaAsset`, and are deleted after every terminal outcome.
public final class TranscriptionTempStore: @unchecked Sendable {
  /// This is attempt-scoped input for local transcription, not a durable
  /// `Media/` asset. Keep its larger ceiling independent from the 200MB
  /// permanent-media limit.
  public static let maxBytes = 2 * 1024 * 1024 * 1024
  public static let maximumDurationSeconds: Double = 7_200

  private let root: URL
  private let resources: any SafeResourceFetching
  private let fileManager: FileManager
  private let removeItem: @Sendable (URL) throws -> Void
  private let availableDiskBytes: @Sendable (URL) throws -> Int64

  public init(
    applicationSupportRoot: URL,
    resources: any SafeResourceFetching,
    fileManager: FileManager = .default,
    removeItem: (@Sendable (URL) throws -> Void)? = nil,
    availableDiskBytes: (@Sendable (URL) throws -> Int64)? = nil
  ) {
    root = applicationSupportRoot.appendingPathComponent("LinkDigest/TranscriptionTemp", isDirectory: true)
    self.resources = resources
    self.fileManager = fileManager
    self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }
    self.availableDiskBytes = availableDiskBytes ?? { directory in
      let values = try directory.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      return values.volumeAvailableCapacityForImportantUsage
        ?? values.volumeAvailableCapacity.map(Int64.init)
        ?? Int64.max
    }
  }

  public var tempRoot: URL { root }

  public func createWorkspace() throws -> TranscriptionAttemptWorkspace {
    let attemptID = UUID().uuidString.lowercased()
    let directory = root.appendingPathComponent(attemptID, isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      return .init(attemptID: attemptID, directoryURL: directory)
    } catch {
      if fileManager.fileExists(atPath: directory.path) {
        do { try cleanup(attemptID: attemptID) }
        catch { throw TranscriptionTempStoreError.cleanupFailed(attemptID) }
      }
      throw TranscriptionTempStoreError.unavailable
    }
  }

  /// `overrideAudioURL` 是转写专用音轨（见 `BilibiliPlaybackRefresher.audioOnlyTrackURL`）。
  /// 只在整段 progressive 这种「没有独立音轨」的情况下由调用方补上；给了就优先用它，
  /// 免得为了声音把整段视频拉下来。
  public func prepare(
    descriptor: MediaDescriptor,
    overrideAudioURL: String? = nil
  ) async throws -> TranscriptionTempFile {
    // B 站 DASH 等拆轨源：ephemeralPlaybackURL 只有画面，companionAudioURL 才是
    // 可导出的音轨。有伴随音轨时只下音频——既修转写失败，也把临时占用从整段
    // 视频降到音频。合流 mp4（抖音/微信/X）没有独立音轨，仍走主播放地址。
    guard descriptor.kind == .directFile,
          descriptor.transcriptionCapability != .unavailable
    else { throw MediaDownloadError.invalidURL }
    let rawURL = overrideAudioURL ?? Self.preferredTranscriptionSourceURL(descriptor)
    guard let rawURL,
          let remoteURL = URL(string: rawURL),
          remoteURL.scheme?.lowercased() == "https"
    else { throw MediaDownloadError.invalidURL }
    if let duration = descriptor.durationSeconds,
       duration.isFinite,
       duration > Self.maximumDurationSeconds {
      throw LocalVideoTranscriptionError.mediaTooLong
    }

    let workspace = try createWorkspace()
    let attemptID = workspace.attemptID
    let directory = workspace.directoryURL
    do {
      try Task.checkCancellation()
      var headers = ["Accept": "video/mp4,video/quicktime,audio/mp4,application/octet-stream,*/*"]
      if descriptor.platform == "douyin" {
        let referer = Self.publicReferer(descriptor.pageURL) ?? "https://www.douyin.com/"
        headers["Referer"] = referer
        headers["Origin"] = "https://www.douyin.com"
      }
      // 实测 `*.bilivideo.com` 无 Referer 一律 403，带站点根 Referer 即 206。
      if descriptor.platform == "bilibili" {
        headers["Referer"] = "https://www.bilibili.com/"
      }
      let response = try await resources.fetchResource(.init(
        url: remoteURL,
        headers: headers,
        byteLimit: Self.maxBytes
      ))
      try Task.checkCancellation()
      guard (200...299).contains(response.statusCode) else { throw MediaDownloadError.responseStatus }
      guard !response.body.isEmpty else { throw MediaDownloadError.emptyBody }
      guard response.body.count <= Self.maxBytes else { throw MediaDownloadError.responseTooLarge }
      let ext = try LocalMediaStore.validatedContainer(body: response.body, contentType: response.contentType)
      try assertDiskSpace(forByteCount: response.body.count)
      let fileURL = directory.appendingPathComponent("media.\(ext)", isDirectory: false)
      try response.body.write(to: fileURL, options: [.atomic])
      try Task.checkCancellation()

      let verifiedDuration = try await verifiedDurationSeconds(fileURL: fileURL)
      if let verifiedDuration,
         verifiedDuration > Self.maximumDurationSeconds {
        throw LocalVideoTranscriptionError.mediaTooLong
      }
      return .init(
        attemptID: attemptID,
        workspaceURL: directory,
        fileURL: fileURL,
        durationSeconds: verifiedDuration ?? descriptor.durationSeconds
      )
    } catch {
      do { try cleanup(attemptID: attemptID) }
      catch { throw TranscriptionTempStoreError.cleanupFailed(attemptID) }
      if error is CancellationError { throw MediaDownloadError.cancelled }
      if let value = error as? TranscriptionTempStoreError { throw value }
      if let value = error as? LocalVideoTranscriptionError { throw value }
      if let value = error as? MediaDownloadError { throw value }
      if let value = error as? ManualLinkError { throw Self.mapManual(value) }
      throw TranscriptionTempStoreError.unavailable
    }
  }

  /// 转写输入源：优先伴随音轨，否则主播放地址。供测试与调用方断言选轨逻辑。
  public static func preferredTranscriptionSourceURL(_ descriptor: MediaDescriptor) -> String? {
    if let companion = descriptor.companionAudioURL,
       let url = URL(string: companion),
       url.scheme?.lowercased() == "https" {
      return companion
    }
    return descriptor.ephemeralPlaybackURL
  }

  public func cleanup(attemptID: String) throws {
    guard UUID(uuidString: attemptID)?.uuidString.lowercased() == attemptID else {
      throw TranscriptionTempStoreError.cleanupFailed(attemptID)
    }
    let directory = root.appendingPathComponent(attemptID, isDirectory: true)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    do { try removeItem(directory) }
    catch { throw TranscriptionTempStoreError.cleanupFailed(attemptID) }
  }

  public func cleanupAll() throws {
    guard fileManager.fileExists(atPath: root.path) else { return }
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw TranscriptionTempStoreError.cleanupFailed("startup")
    }
    for entry in entries {
      do { try removeItem(entry) }
      catch { throw TranscriptionTempStoreError.cleanupFailed(entry.lastPathComponent) }
    }
  }

  private func assertDiskSpace(forByteCount byteCount: Int) throws {
    let available = try availableDiskBytes(root)
    let required = Int64(byteCount) + LocalMediaStore.minimumFreeBytesAfterWrite
    guard available >= required else { throw TranscriptionTempStoreError.insufficientDiskSpace }
  }

  private func verifiedDurationSeconds(fileURL: URL) async throws -> Double? {
    let duration: CMTime
    do { duration = try await AVURLAsset(url: fileURL).load(.duration) }
    catch { return nil }
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds >= 0 else { return nil }
    return seconds
  }

  private static func publicReferer(_ raw: String) -> String? {
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return components?.url?.absoluteString
  }

  private static func mapManual(_ error: ManualLinkError) -> MediaDownloadError {
    switch error {
    case .unsafeURL: .unsafeURL
    case .responseStatus: .responseStatus
    case .responseTooLarge: .responseTooLarge
    case .timedOut: .timedOut
    case .cancelled: .cancelled
    case .invalidURL: .invalidURL
    default: .network
    }
  }
}
