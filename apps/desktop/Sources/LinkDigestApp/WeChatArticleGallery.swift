import Foundation
import LinkDigestCore
import SwiftUI

/// WeChat keeps its horizontal editorial layout; column count follows readable text width.
enum WeChatArticleLayout {
  static let coverAspect: CGFloat = CreatorWorkCardLayout.coverAspect
  static let cardHeight: CGFloat = 132
  static func columnCount(availableWidth: CGFloat) -> Int { availableWidth >= 1_000 ? 2 : 1 }
}

struct WeChatArticleGallery: View {
  @ObservedObject var model: HistoryViewModel
  let theme: HistoryThemeTokens
  var searchFocused: FocusState<Bool>.Binding
  let onOpen: (TaskID) -> Void

  private var rows: [HistoryRowProjection] {
    model.rows.filter { HistoryPlatformRegistry.canonicalHost(for: $0.host) == "mp.weixin.qq.com" }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("公众号").themedFont(.headline)
        Spacer()
        TextField("搜索标题、正文、总结、标签", text: $model.searchText)
          .textFieldStyle(.roundedBorder)
          .focused(searchFocused)
          .frame(maxWidth: 360)
          .accessibilityIdentifier("wechat-gallery-search")
      }
      .padding(.horizontal, 16).padding(.top, 14)
      GeometryReader { geometry in
        ScrollView {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                   count: WeChatArticleLayout.columnCount(availableWidth: geometry.size.width)), spacing: 12) {
            ForEach(rows, id: \.taskID) { row in
              Button { onOpen(row.taskID) } label: {
                WeChatArticleCard(row: row, theme: theme) { cover in
                  await model.localCoverURL(for: row.taskID, matching: cover)
                }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("wechat-article-card-\(row.taskID.rawValue)")
              .onAppear { model.loadNextPageIfNeeded(after: row) }
            }
          }
          .padding(.horizontal, 16).padding(.bottom, 16)
          if rows.isEmpty {
            if model.listState == .loading || model.listState == .idle {
              ProgressView("正在载入公众号文章…").padding()
            } else if model.listState == .failed {
              Button("载入失败，点击重试", action: model.retryList).padding()
            } else {
              Text(model.searchText.isEmpty ? "尚未保存公众号文章" : "没有匹配的公众号文章")
                .foregroundStyle(theme.secondaryText).padding()
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.canvas)
    .accessibilityIdentifier("wechat-article-gallery")
  }
}

private struct WeChatArticleCard: View {
  let row: HistoryRowProjection
  let theme: HistoryThemeTokens
  let localCover: (String) async -> URL?
  @State private var image: NSImage?
  @State private var loading = false

  private var title: String { CapturedContentNaming.name(title: row.title, body: row.sourcePreview,
    host: row.host, author: row.author, published: row.published).text }
  private var author: String {
    let value = row.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "公众号" : value
  }

  var body: some View {
    GeometryReader { geometry in
      let coverWidth = min(235, max(100, (geometry.size.width - 28) * 0.32))
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(author).themedFont(.caption, weight: .medium)
            .foregroundStyle(theme.accent).lineLimit(1)
          Text(title).themedFont(.callout, weight: .medium)
            .foregroundStyle(theme.primaryText).lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
          Text(HistoryPublishedTimestampFormatter.directoryCardStamp(published: row.published,
            savedAtMilliseconds: row.createdAtMilliseconds ?? row.updatedAtMilliseconds))
            .themedFont(.caption2).foregroundStyle(theme.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Color.clear
          .frame(width: coverWidth, height: coverWidth / WeChatArticleLayout.coverAspect)
          .overlay {
            if let image {
              CreatorWorkCardFillImage(image: image)
            } else {
              theme.badge.overlay {
                if loading { ProgressView().controlSize(.small) }
                else { Text("封面未获取").themedFont(.caption2).foregroundStyle(theme.secondaryText) }
              }
            }
          }
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
      }
      .padding(14)
      .frame(width: geometry.size.width, height: WeChatArticleLayout.cardHeight)
      .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
      .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(theme.hairline, lineWidth: 1))
    }
    .frame(height: WeChatArticleLayout.cardHeight)
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    .help(title)
    .task(id: "\(row.taskID.rawValue)#\(row.coverURL ?? "")#\(row.updatedAtMilliseconds)") {
      image = nil
      guard let cover = row.coverURL, !cover.isEmpty else { loading = false; return }
      loading = true
      defer { loading = false }
      if let local = await localCover(cover) {
        let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: local) }.value
        guard !Task.isCancelled else { return }
        if let bytes, let decoded = NSImage(data: bytes) { image = decoded; return }
      }
      guard !Task.isCancelled, let url = DouyinProfilePreviewResource.admittedURL(cover),
            let bytes = try? await DouyinProfilePreviewResource.fetch(url), !Task.isCancelled else { return }
      image = NSImage(data: bytes)
    }
  }
}
