import LinkDigestShared
import SwiftUI

public extension Notification.Name {
  static let linkDigestOpenSettings = Notification.Name("linkdigest.openSettings")
}

public struct NotesRootView: View {
  @Bindable var model: NotesViewModel
  @State private var showCompose = false
  @State private var showSettings = false
  @State private var selected: SyncNoteCard?

  public init(model: NotesViewModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      Group {
        if model.visibleNotes.isEmpty {
          ContentUnavailableView(
            "还没有笔记",
            systemImage: "square.and.pencil",
            description: Text("点下方 +，手写、口述或粘贴链接。")
          )
        } else {
          List {
            syncStatusSection
            ForEach(model.visibleNotes) { note in
              Button {
                selected = note
              } label: {
                NoteRowView(note: note)
              }
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("汲作")
      .searchable(text: $model.searchText, prompt: "搜索笔记")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          if model.visibleNotes.isEmpty {
            // 空列表时仍显示简短同步状态
            Text(shortSyncLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 12) {
            Button {
              showSettings = true
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")

            Button {
              Task { await model.synchronize() }
            } label: {
              if model.isSynchronizing {
                ProgressView()
              } else {
                Image(systemName: "arrow.triangle.2.circlepath")
              }
            }
            .accessibilityLabel("同步")
            .disabled(model.isSynchronizing)
          }
        }
      }
      .safeAreaInset(edge: .top) {
        if model.visibleNotes.isEmpty {
          syncBanner
        }
      }
      .safeAreaInset(edge: .bottom) {
        composeBar
      }
      .task {
        await model.reload()
        // 同步失败只更新状态文案，不得在无 iCloud 能力时崩进程。
        await model.synchronize()
        if ProcessInfo.processInfo.arguments.contains("-openSettings") {
          showSettings = true
        }
      }
      .sheet(isPresented: $showCompose) {
        ComposeSheet(model: model)
      }
      .sheet(isPresented: $showSettings) {
        ProviderSettingsSheet(model: model)
      }
      .onReceive(NotificationCenter.default.publisher(for: .linkDigestOpenSettings)) { _ in
        showSettings = true
      }
      .navigationDestination(item: $selected) { note in
        NoteDetailView(model: model, note: note)
      }
      .alert(
        "出错了",
        isPresented: Binding(
          get: { model.loadError != nil },
          set: { if !$0 { /* cleared on next success */ } }
        )
      ) {
        Button("好", role: .cancel) {}
      } message: {
        Text(model.loadError ?? "")
      }
      .overlay(alignment: .top) {
        if let banner = model.shareImportBanner {
          Text(banner)
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .task(id: banner) {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              model.clearShareImportBanner()
            }
        }
      }
    }
  }

  private var syncStatusSection: some View {
    Section {
      Button {
        Task { await model.synchronize() }
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: syncIconName)
            .foregroundStyle(syncIconColor)
          VStack(alignment: .leading, spacing: 4) {
            Text("iCloud 同步")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
            Text(model.syncStatusSummary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          if model.isSynchronizing {
            ProgressView()
          } else {
            Text("立即同步")
              .font(.caption.weight(.medium))
              .foregroundStyle(.tint)
          }
        }
        .padding(.vertical, 4)
      }
      .disabled(model.isSynchronizing)
    }
  }

  private var syncBanner: some View {
    Button {
      Task { await model.synchronize() }
    } label: {
      HStack {
        Image(systemName: syncIconName)
        Text(model.syncStatusSummary)
          .lineLimit(2)
        Spacer()
        Text("同步")
          .font(.caption.weight(.semibold))
      }
      .font(.caption)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(.bar)
    }
    .buttonStyle(.plain)
    .disabled(model.isSynchronizing)
  }

  private var shortSyncLabel: String {
    switch model.syncStatus.phase {
    case .idle:
      return model.syncStatus.lastSuccessAtMilliseconds == nil ? "未同步" : "已同步"
    case .pushing, .pulling:
      return "同步中"
    case .failed:
      return "同步失败"
    }
  }

  private var syncIconName: String {
    if model.isSynchronizing { return "arrow.triangle.2.circlepath" }
    switch model.syncStatus.phase {
    case .failed: return "exclamationmark.icloud"
    case .idle where model.syncStatus.lastSuccessAtMilliseconds != nil:
      return "checkmark.icloud"
    default:
      return "icloud"
    }
  }

  private var syncIconColor: Color {
    if model.syncStatus.phase == .failed { return .orange }
    if model.syncStatus.lastSuccessAtMilliseconds != nil { return .secondary }
    return .secondary
  }

  private var composeBar: some View {
    HStack {
      Spacer()
      Button {
        showCompose = true
      } label: {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 44))
          .symbolRenderingMode(.hierarchical)
      }
      .accessibilityLabel("新建")
      Spacer()
    }
    .padding(.vertical, 8)
    .background(.bar)
  }
}

private struct NoteRowView: View {
  let note: SyncNoteCard

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(kindLabel)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.15), in: Capsule())
        Spacer()
      }
      Text(note.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
      Text(note.previewLine)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 4)
  }

  private var kindLabel: String {
    switch note.kind {
    case .text: "文字"
    case .voice: "口述"
    case .link: "链接"
    }
  }
}
