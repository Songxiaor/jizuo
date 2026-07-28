import Foundation
import LinkDigestCore

public enum SessionMediaRefreshError: Error, Equatable, Sendable {
  case unsupportedPlatform
  case youtubeUsesEmbed
  case networkOrParse
  case noPlayableMedia
  case cancelled

  public var userMessage: String {
    switch self {
    case .unsupportedPlatform:
      return "当前平台还不能在 App 内重新获取播放地址。"
    case .youtubeUsesEmbed:
      return "YouTube 使用官方嵌入播放，打开详情即可观看。"
    case .networkOrParse:
      return "暂时无法重新获取播放地址。请检查网络，或回到浏览器打开原页面后再试。"
    case .noPlayableMedia:
      return "没有找到可安全播放的视频源。请回到原页面确认视频可播放后再试。"
    case .cancelled:
      return "已取消获取播放。"
    }
  }
}

/// Re-obtains a process-only MediaDescriptor for history streaming recovery.
/// Never persists signed URLs.
public struct SessionMediaRefreshService: Sendable {
  private let resources: any SafeResourceFetching
  private let xResolver: XTweetResolver
  private let bilibili: BilibiliPlaybackRefresher
  private let bilibiliQuality: @Sendable () -> BilibiliStreamQualityPreference
  /// Returns a Cookie header for B 站 App-owned WebKit session, or nil.
  private let bilibiliCookieHeader: @Sendable () async -> String?
  /// Re-renders one Douyin item in the App-owned WebKit partition. The returned
  /// signed URL remains process-only and is never written into history.
  private let douyinRefresh: (@Sendable (String, String?) async throws -> MediaDescriptor)?

  /// 选流过程的可见记录，供 UI 展示；不含 Cookie 与签名 URL。
  public let bilibiliDiagnostics = BilibiliSelectionDiagnostics()

  public init(
    resources: any SafeResourceFetching,
    bilibiliQuality: @escaping @Sendable () -> BilibiliStreamQualityPreference = { .default },
    bilibiliCookieHeader: @escaping @Sendable () async -> String? = { nil },
    douyinRefresh: (@Sendable (String, String?) async throws -> MediaDescriptor)? = nil
  ) {
    self.resources = resources
    self.xResolver = XTweetResolver(resources: resources)
    self.bilibili = BilibiliPlaybackRefresher(
      resources: resources,
      diagnostics: bilibiliDiagnostics
    )
    self.bilibiliQuality = bilibiliQuality
    self.bilibiliCookieHeader = bilibiliCookieHeader
    self.douyinRefresh = douyinRefresh
  }

  /// `qualityOverride` 来自用户在某条视频上手动选的清晰度，优先于全局偏好，
  /// 且会让选流放弃「长片强制 progressive」的提速规则。
  public func refresh(
    platform: String?,
    sourceURL: String,
    author: String? = nil,
    qualityOverride: BilibiliStreamQualityPreference? = nil
  ) async throws -> MediaDescriptor {
    if YouTubeWatchLinkSupport.videoID(from: sourceURL) != nil {
      throw SessionMediaRefreshError.youtubeUsesEmbed
    }
    let normalized = (platform ?? "").lowercased()
    if normalized == "x" || XTweetResolver.tweetID(from: sourceURL) != nil {
      return try await refreshX(sourceURL: sourceURL, author: author)
    }
    if normalized == "douyin"
      || URL(string: sourceURL).map(DouyinURL.matches) == true {
      guard let douyinRefresh else {
        throw SessionMediaRefreshError.unsupportedPlatform
      }
      do {
        return try await douyinRefresh(sourceURL, author)
      } catch is CancellationError {
        throw SessionMediaRefreshError.cancelled
      } catch let error as SessionMediaRefreshError {
        throw error
      } catch {
        throw SessionMediaRefreshError.networkOrParse
      }
    }
    if normalized == "bilibili" || BilibiliPlaybackRefresher.videoID(from: sourceURL) != nil {
      do {
        let cookie = await bilibiliCookieHeader()
        return try await bilibili.refresh(
          pageURL: sourceURL,
          author: author,
          quality: qualityOverride ?? bilibiliQuality(),
          cookieHeader: cookie,
          userChoseQuality: qualityOverride != nil
        )
      } catch BilibiliPlaybackRefresher.RefreshError.unsupportedURL {
        throw SessionMediaRefreshError.unsupportedPlatform
      } catch BilibiliPlaybackRefresher.RefreshError.noPlayableStream,
              BilibiliPlaybackRefresher.RefreshError.missingCID {
        throw SessionMediaRefreshError.noPlayableMedia
      } catch {
        throw SessionMediaRefreshError.networkOrParse
      }
    }
    throw SessionMediaRefreshError.unsupportedPlatform
  }

  /// 转写专用音轨地址。拿不到就返回 nil，由调用方回退到原播放地址——
  /// 取音轨是省流量的优化，不该因为它失败就让整条转写失败。
  public func transcriptionAudioTrackURL(
    platform: String?,
    sourceURL: String
  ) async -> String? {
    let normalized = (platform ?? "").lowercased()
    guard normalized == "bilibili" || BilibiliPlaybackRefresher.videoID(from: sourceURL) != nil
    else { return nil }
    let cookie = await bilibiliCookieHeader()
    return try? await bilibili.audioOnlyTrackURL(pageURL: sourceURL, cookieHeader: cookie)
  }

  private func refreshX(sourceURL: String, author: String?) async throws -> MediaDescriptor {
    guard let tweetID = XTweetResolver.tweetID(from: sourceURL) else {
      throw SessionMediaRefreshError.unsupportedPlatform
    }
    guard let media = await xResolver.resolveVideo(tweetID: tweetID, author: author) else {
      throw SessionMediaRefreshError.noPlayableMedia
    }
    return MediaDescriptor(
      kind: .directFile,
      pageURL: sourceURL,
      canonicalURL: sourceURL,
      platform: "x",
      ephemeralPlaybackURL: media.videoURL,
      companionAudioURL: media.companionAudioURL,
      mimeType: "video/mp4",
      posterURL: media.coverURL,
      durationSeconds: media.durationSeconds,
      author: media.author,
      transcriptionCapability: .supported,
      selectionReason: .singleCandidate,
      playbackState: .unknown
    )
  }
}

/// App target also has `YouTubeWatchLink`; adapters keep a tiny duplicate to avoid
/// pulling SwiftUI/AVKit into LinkDigestAdapters.
enum YouTubeWatchLinkSupport {
  static func videoID(from urlString: String) -> String? {
    guard let components = URLComponents(string: urlString) else { return nil }
    var host = (components.host ?? "").lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if host.hasPrefix("m.") { host.removeFirst(2) }
    let idPattern = "^[A-Za-z0-9_-]{6,20}$"
    func isValid(_ id: String) -> Bool {
      id.range(of: idPattern, options: .regularExpression) != nil
    }
    if host == "youtu.be" {
      let id = components.path.split(separator: "/").first.map(String.init) ?? ""
      return isValid(id) ? id : nil
    }
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
    if components.path == "/watch" {
      let id = components.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
      return isValid(id) ? id : nil
    }
    for prefix in ["/shorts/", "/live/"] where components.path.hasPrefix(prefix) {
      let id = String(components.path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? ""
      return isValid(id) ? id : nil
    }
    return nil
  }
}
