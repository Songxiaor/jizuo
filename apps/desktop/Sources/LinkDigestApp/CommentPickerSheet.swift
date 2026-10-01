import LinkDigestCore
import SwiftUI

/// 「抓取评论…」面板的状态：读取 → 勾选 → 保存。
@MainActor
final class CommentPickerModel: ObservableObject {
  enum Phase: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  @Published private(set) var phase: Phase = .loading
  @Published private(set) var comments: [CapturedComment] = []
  @Published private(set) var expectedCount: Int?
  @Published private(set) var loginRequired = false
  @Published var selectedIDs: Set<String> = []

  let url: URL
  let limit: Int
  private let service = CommentFetchService()
  private var task: Task<Void, Never>?

  init(url: URL, limit: Int = CapturePreferencesStore.standard().commentLimit) {
    self.url = url
    self.limit = limit
  }

  var selectedComments: [CapturedComment] { comments.filter { selectedIDs.contains($0.id) } }

  func start() {
    task?.cancel()
    phase = .loading
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let collection = try await service.fetch(url: url, limit: limit)
        guard !Task.isCancelled else { return }
        comments = collection.comments
        expectedCount = collection.expectedCount
        loginRequired = collection.loginRequired == true
        selectedIDs = Set(collection.comments.map(\.id))
        phase = collection.comments.isEmpty
          ? .failed(CommentFetchService.FetchError.unreadable.errorDescription ?? "没有读到评论。")
          : .loaded
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        phase = .failed((error as? LocalizedError)?.errorDescription ?? "读取评论失败，可重试。")
      }
    }
  }

  func cancel() {
    task?.cancel()
    service.cancel()
  }

  func toggle(_ id: String) {
    if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
  }

  func selectAll() { selectedIDs = Set(comments.map(\.id)) }
  func selectNone() { selectedIDs = [] }
}

/// 与「添加网页链接」同一套版式：标题 + 一句说明、内容区、底部取消与主操作。
struct CommentPickerSheet: View {
  @Environment(\.appTheme) private var theme
  @StateObject private var model: CommentPickerModel
  let title: String
  let onSave: ([CapturedComment], Int?) -> Void
  let onCancel: () -> Void

  init(url: URL, title: String, onSave: @escaping ([CapturedComment], Int?) -> Void, onCancel: @escaping () -> Void) {
    _model = StateObject(wrappedValue: CommentPickerModel(url: url))
    self.title = title
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.lg) {
      VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
        Text("选择要保存的评论").themedFont(.title3, weight: .semibold)
        Text(title)
          .themedFont(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      content
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 420, alignment: .top)

      HStack {
        Button("取消") {
          model.cancel()
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        if case .failed = model.phase {
          Button("重试") { model.start() }
            .accessibilityIdentifier("comment-picker-retry")
        }
        Button(saveTitle) {
          onSave(model.selectedComments, model.expectedCount)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.phase != .loaded)
        .accessibilityIdentifier("comment-picker-save")
      }
    }
    .padding(DesignTokens.Space.xl)
    .frame(width: 560)
    .onAppear { model.start() }
    .onDisappear { model.cancel() }
  }

  private var saveTitle: String {
    let count = model.selectedIDs.count
    return count == 0 ? "不保存评论" : "保存 \(count) 条评论"
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      VStack(spacing: DesignTokens.Space.sm) {
        ProgressView()
        Text("正在打开原文并读取前 \(model.limit) 条评论…")
          .themedFont(.callout)
          .foregroundStyle(.secondary)
        Text("会用「设置 → 站点登录」里的登录状态；页面不会显示出来。")
          .themedFont(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("comment-picker-loading")
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .themedFont(.callout)
        .foregroundStyle(theme.warning)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("comment-picker-error")
    case .loaded:
      VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
        HStack(spacing: DesignTokens.Space.sm) {
          Text(countLabel)
            .themedFont(.callout, weight: .semibold)
            .accessibilityIdentifier("comment-picker-count")
          Spacer()
          Button("全选") { model.selectAll() }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .disabled(model.selectedIDs.count == model.comments.count)
          Button("清空") { model.selectNone() }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .disabled(model.selectedIDs.isEmpty)
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            ForEach(model.comments) { comment in
              CommentPickerRow(
                comment: comment,
                isSelected: model.selectedIDs.contains(comment.id),
                toggle: { model.toggle(comment.id) }
              )
            }
          }
        }
        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(theme.hairline))
        if model.loginRequired {
          Label("这个网站要登录后才显示全部评论。可在「设置 → 站点登录」登录后重试，读满 \(model.limit) 条。", systemImage: "person.crop.circle.badge.exclamationmark")
            .themedFont(.caption)
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("保存后会替换这条内容原有的评论段；条数在「设置 → 收集 · 汲 → 评论」里改。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var countLabel: String {
    let base = "已选 \(model.selectedIDs.count) / \(model.comments.count) 条"
    if let expected = model.expectedCount, expected > model.comments.count {
      return "\(base) · 页面共约 \(expected) 条"
    }
    return base
  }
}

private struct CommentPickerRow: View {
  @Environment(\.appTheme) private var theme
  let comment: CapturedComment
  let isSelected: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(alignment: .top, spacing: DesignTokens.Space.sm) {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .foregroundStyle(isSelected ? theme.accent : Color.secondary)
          .font(.system(size: 14))
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          HStack(spacing: DesignTokens.Space.xs) {
            Text(displayAuthor)
              .themedFont(.callout, weight: .semibold)
              .lineLimit(1)
            if let likes = comment.likes ?? comment.score {
              Label(likes, systemImage: "hand.thumbsup")
                .labelStyle(.titleAndIcon)
                .themedFont(.caption)
                .foregroundStyle(.secondary)
            }
            if let published = comment.published {
              // 与阅读页评论同一套时间写法：ISO 时间显示成「3 小时前」，平台原文（「2年前·上海」）照原样。
              Text(CommentPublishedTime.relativeLabel(published))
                .themedFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(published)
            }
          }
          Text(comment.body)
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, DesignTokens.Space.xs + 2)
      .padding(.horizontal, DesignTokens.Space.sm)
      .padding(.leading, CGFloat(min(comment.depth, 3)) * DesignTokens.Space.lg)
      .background(
        isSelected ? theme.accent.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(displayAuthor)：\(comment.body)")
    .accessibilityValue(isSelected ? "已勾选" : "未勾选")
    .accessibilityAddTraits(.isToggle)
  }

  private var displayAuthor: String {
    comment.author.hasPrefix("u/") ? String(comment.author.dropFirst(2)) : comment.author
  }
}
