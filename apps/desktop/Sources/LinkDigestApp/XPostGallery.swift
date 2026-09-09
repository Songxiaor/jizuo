import LinkDigestCore
import SwiftUI

/// X gallery remains a thin wrapper so existing accessibility IDs and tests stay stable.
struct XPostGallery: View {
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
      accessibilityPrefix: "x-post-gallery"
    )
  }
}
