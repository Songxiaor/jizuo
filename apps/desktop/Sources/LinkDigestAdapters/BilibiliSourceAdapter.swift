import Foundation
import LinkDigestCore

/// B 站手动链接：短链只沿现有安全 fetcher 解开，正文与媒体均来自公开 API。
/// 不读取 Cookie、不解析页面壳，也不把分享追踪参数写入 canonical URL。
public struct BilibiliSourceAdapter: SourceAdapting, Sendable {
  private let fetcher: any WebPageFetcher
  private let playback: BilibiliPlaybackRefresher
  private let now: @Sendable () -> Date

  public init(
    fetcher: any WebPageFetcher,
    resources: any SafeResourceFetching,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.fetcher = fetcher
    self.playback = BilibiliPlaybackRefresher(resources: resources)
    self.now = now
  }

  public func takesOwnership(of url: URL) -> Bool {
    BilibiliManualURL.isShortLink(url) || BilibiliPlaybackRefresher.videoID(from: url.absoluteString) != nil
  }

  public func capture(url: URL) async throws -> CapturedDocument {
    guard takesOwnership(of: url) else { throw ManualLinkError.invalidURL }
    let resolvedURL: URL
    if BilibiliManualURL.isShortLink(url) {
      do {
        resolvedURL = try await fetcher.fetch(url: url).url
      } catch let error as ManualLinkError {
        throw error
      } catch is CancellationError {
        throw ManualLinkError.cancelled
      } catch {
        throw ManualLinkError.network
      }
    } else {
      resolvedURL = url
    }
    guard let videoID = BilibiliPlaybackRefresher.videoID(from: resolvedURL.absoluteString) else {
      throw ManualLinkError.invalidPageResult
    }

    let metadata: BilibiliViewMetadata
    do {
      metadata = try await playback.fetchViewMetadata(videoID: videoID)
    } catch BilibiliPlaybackRefresher.RefreshError.accessRestricted {
      throw ManualLinkError.loginRequired
    } catch BilibiliPlaybackRefresher.RefreshError.videoUnavailable {
      throw ManualLinkError.responseStatus
    } catch BilibiliPlaybackRefresher.RefreshError.missingCID,
            BilibiliPlaybackRefresher.RefreshError.invalidResponse {
      throw ManualLinkError.invalidPageResult
    } catch is CancellationError {
      throw ManualLinkError.cancelled
    } catch {
      throw ManualLinkError.network
    }

    let canonical = "https://www.bilibili.com/video/\(metadata.bvid)"
    let descriptor: MediaDescriptor
    do {
      descriptor = try await playback.refresh(pageURL: canonical, metadata: metadata)
    } catch BilibiliPlaybackRefresher.RefreshError.noPlayableStream {
      throw ManualLinkError.extensionCaptureRequired
    } catch is CancellationError {
      throw ManualLinkError.cancelled
    } catch {
      throw ManualLinkError.network
    }
    guard let videoURL = descriptor.ephemeralPlaybackURL else {
      throw ManualLinkError.extensionCaptureRequired
    }

    let timestamp = ISO8601DateFormatter().string(from: now())
    return CapturedDocument(
      createdAt: timestamp,
      idempotencyKey: "manual-bilibili:\(UUID().uuidString.lowercased())",
      origin: .manualLink,
      url: canonical,
      title: metadata.title,
      platform: "bilibili",
      method: "bilibili_public_api",
      text: Self.markdown(metadata),
      completeness: "complete",
      capturedAt: timestamp,
      sourceLabel: "手动链接（B 站公开视频）",
      media: CaptureMedia(
        platform: "bilibili",
        videoURL: videoURL,
        companionAudioURL: descriptor.companionAudioURL,
        coverURL: metadata.coverURL?.absoluteString,
        durationSeconds: descriptor.durationSeconds,
        author: metadata.author
      )
    )
  }

  static func markdown(_ metadata: BilibiliViewMetadata) -> String {
    func yaml(_ value: String) -> String {
      "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ") + "\""
    }
    var frontmatter: [String] = []
    if let author = metadata.author { frontmatter.append("author: \(yaml(author))") }
    if let published = metadata.publishedAt { frontmatter.append("published: \(yaml(published))") }
    if let likes = metadata.likes { frontmatter.append("likes: \(yaml(likes))") }
    if let comments = metadata.comments { frontmatter.append("comments: \(yaml(comments))") }
    if let shares = metadata.shares { frontmatter.append("shares: \(yaml(shares))") }
    if let collects = metadata.collects { frontmatter.append("collects: \(yaml(collects))") }
    if let views = metadata.views { frontmatter.append("views: \(yaml(views))") }

    var body: [String] = []
    if let description = metadata.description { body.append(description) }
    if let cover = metadata.coverURL { body.append("![视频封面](\(cover.absoluteString))") }
    if body.isEmpty { body.append("B 站公开视频：\(metadata.title)") }
    let header = frontmatter.isEmpty ? "" : "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n"
    return header + body.joined(separator: "\n\n")
  }
}

public enum BilibiliManualURL {
  public static func isShortLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = PublicWebURLPolicy.normalizedHost(url.host ?? "")
    else { return false }
    return host == "b23.tv"
  }
}
