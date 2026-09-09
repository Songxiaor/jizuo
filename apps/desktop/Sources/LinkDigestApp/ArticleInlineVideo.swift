import AVKit
import SwiftUI

/// 长文正文里的一段视频：能播就地播放，不能播就留位置并给出原页入口。
struct ArticleEmbeddedVideo: Equatable {
  enum Kind: String, Equatable {
    case youtube
    case bilibili
    case vimeo
    case mux
    case direct
    case unknown
  }

  var kind: Kind
  var platform: String
  var id: String?
  var url: URL?
  var title: String?

  var bindsLocalFile: Bool { kind != .youtube }

  var platformLabel: String {
    switch kind {
    case .youtube: "YouTube"
    case .bilibili: "B站"
    case .vimeo: "Vimeo"
    case .mux: "视频"
    case .direct: "视频"
    case .unknown: "视频"
    }
  }

  var openURL: URL? {
    if let url { return url }
    if kind == .youtube, let id {
      return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }
    return nil
  }
}

struct ArticleInlineVideoCard: View {
  let video: ArticleEmbeddedVideo
  var localFileURL: URL?
  var pageURL: URL?
  var onOpenURL: (URL) -> Void

  @ObservedObject private var cinema = VideoCinemaController.shared
  @State private var player: AVPlayer?

  private var isInCinema: Bool {
    if let player { return cinema.isPresenting(player: player) }
    return false
  }

  var body: some View {
    Group {
      if let youTubeID {
        YouTubeEmbedPlayerCard(videoID: youTubeID, hasCaptions: true)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          header
          if let localFileURL, LocalMediaExport.isSupportedLocalFile(localFileURL) {
            localPlayer(localFileURL)
          } else {
            placeholder
          }
        }
        .padding(12)
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
      }
    }
    .accessibilityIdentifier("history-article-inline-video")
    .onDisappear {
      if isInCinema { cinema.dismiss() }
      player?.pause()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label(video.platformLabel, systemImage: "play.rectangle.fill")
        .themedFont(.callout, weight: .semibold)
      if let title = video.title, !title.isEmpty {
        Text(title)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let destination = video.openURL ?? pageURL {
        Button("在浏览器打开") { onOpenURL(destination) }
          .buttonStyle(.link)
          .themedFont(.caption)
          .accessibilityIdentifier("history-article-inline-video-open")
      }
    }
  }

  private var youTubeID: String? {
    if video.kind == .youtube, let id = video.id, YouTubeWatchLink.videoID(from: "https://www.youtube.com/watch?v=\(id)") == id {
      return id
    }
    if let url = video.url { return YouTubeWatchLink.videoID(from: url.absoluteString) }
    return nil
  }

  @ViewBuilder
  private func localPlayer(_ fileURL: URL) -> some View {
    Group {
      if isInCinema {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
          .fill(Color.black.opacity(0.85))
          .overlay {
            Text("正在放大播放…")
              .themedFont(.caption)
              .foregroundStyle(.white.opacity(0.7))
          }
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
      } else if let player {
        VideoPlayer(player: player)
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .frame(maxHeight: VideoDisplayGeometry.inlineMaximumHeight)
          .onTapGesture(count: 2) {
            cinema.present(player: player, aspectRatio: 16.0 / 9.0)
          }
      }
    }
    .onAppear {
      if player == nil { player = AVPlayer(url: fileURL) }
    }
    .onChange(of: fileURL) { _, newURL in
      player?.pause()
      player = AVPlayer(url: newURL)
    }

    if !isInCinema, let player {
      HStack {
        Spacer(minLength: 0)
        Button {
          cinema.present(player: player, aspectRatio: 16.0 / 9.0)
        } label: {
          Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.link)
        .themedFont(.caption)
        .accessibilityIdentifier("history-article-inline-video-cinema")
      }
    }
  }

  private var placeholder: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "play.rectangle")
        .font(.title2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(video.title?.isEmpty == false ? video.title! : "原文中的视频")
          .themedFont(.callout, weight: .medium)
        Text(placeholderDetail)
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .accessibilityIdentifier("history-article-inline-video-placeholder")
  }

  private var placeholderDetail: String {
    switch video.kind {
    case .bilibili: "B站嵌入，点右上角在浏览器打开"
    case .vimeo: "Vimeo 嵌入，点右上角在浏览器打开"
    case .mux, .direct, .unknown: "未保存到本机，可在浏览器打开原页"
    case .youtube: "YouTube"
    }
  }
}
