import Foundation
import LinkDigestCore
import SwiftUI

/// WeChat gallery shares CreatorDirectoryChrome column math; cards are compact vertical work cards.
enum WeChatArticleLayout {
  static let coverAspect: CGFloat = CreatorWorkCardLayout.coverAspect

  static func columnCount(availableWidth: CGFloat) -> Int {
    CreatorDirectoryChrome.xColumnCount(availableWidth: availableWidth)
  }

  /// Older articles declare the official CDN with http. Upgrade only that exact
  /// host; the shared downloader still rejects HTTP requests and redirects.
  static func coverURL(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw),
          components.scheme?.lowercased() == "http",
          components.host?.lowercased() == "mmbiz.qpic.cn",
          components.port == nil || components.port == 80
    else { return GalleryCoverAdmission.admittedURL(raw) }
    components.scheme = "https"
    components.port = nil
    guard let upgraded = components.url else { return nil }
    return GalleryCoverAdmission.admittedURL(upgraded.absoluteString)
  }
}

/// WeChat source-platform gallery — thin wrapper over the shared platform gallery.
struct WeChatArticleGallery: View {
  @ObservedObject var model: HistoryViewModel
  let theme: HistoryThemeTokens
  var searchFocused: FocusState<Bool>.Binding
  @Binding var scrollTarget: TaskID?
  let onOpen: (TaskID) -> Void
  let contextMenu: (HistoryRowProjection) -> AnyView

  var body: some View {
    PlatformHistoryGallery(
      model: model,
      theme: theme,
      searchFocused: searchFocused,
      scrollTarget: $scrollTarget,
      onOpen: onOpen,
      contextMenu: contextMenu,
      accessibilityPrefix: "wechat-article-gallery"
    )
  }
}
