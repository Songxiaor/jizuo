import AppKit
import Foundation
import LinkDigestCore
import LinkDigestPersistence
import SwiftUI

/// 「数据与备份」的取数与动作。
///
/// 自己解析数据目录、自己按需开连接，而不是等外面注入一个 `HistoryApplicationService`：
/// 备份和恢复要的是**整个库文件**，不是历史记录这一层的读写接口，从仓库协议里
/// 拿不到；而设置页又不该为了这一件事在全局组合根上多挂一根线。
///
/// 只在真的要备份/恢复时才开连接，开完就关：设置页平时只列目录里的文件，那一步
/// 完全不碰数据库。
@MainActor
final class DataBackupViewModel: ObservableObject {
  @Published private(set) var backups: [DatabaseBackupFile] = []
  @Published private(set) var isWorking = false
  @Published var notice: String?
  @Published var noticeIsError = false
  /// 等待二次确认的那份备份。非 nil 时弹确认框。
  @Published var pendingRestore: DatabaseBackupFile?
  /// 恢复完成，等用户重启 App。
  @Published private(set) var needsRestart = false

  private var resolvedLocation: LocalDatabaseLocation?

  var backupsDirectoryURL: URL? {
    location().map { DatabaseBackupStore(location: $0).directoryURL }
  }

  private func location() -> LocalDatabaseLocation? {
    if let resolvedLocation { return resolvedLocation }
    guard let root = try? AppApplicationSupportRoot.resolve() else { return nil }
    let value = LocalDatabaseLocation(applicationSupportRoot: root)
    resolvedLocation = value
    return value
  }

  func reload() {
    guard let location = location() else {
      backups = []
      return
    }
    backups = (try? DatabaseBackupStore(location: location).backups()) ?? []
  }

  func backupNow() {
    perform(busyMessage: nil) { maintenance in
      let file = try maintenance.backupToStore()
      return "已备份到 \(file.name)（\(Self.sizeText(file.byteCount))）"
    }
  }

  func restore(from file: DatabaseBackupFile) {
    perform(busyMessage: nil) { maintenance in
      let safety = try maintenance.restoreInPlace(from: file.url)
      return "已从 \(file.name) 恢复。恢复前的资料另存为 \(safety.name)，请退出并重新打开汲作。"
    } onSuccess: { [weak self] in
      self?.needsRestart = true
    }
  }

  func revealBackupsFolder() {
    guard let directory = backupsDirectoryURL else {
      show("找不到资料目录。", isError: true)
      return
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }

  private func perform(
    busyMessage: String?,
    _ body: @escaping @Sendable (DatabaseMaintenance) throws -> String,
    onSuccess: (() -> Void)? = nil
  ) {
    guard !isWorking else { return }
    guard let location = location() else {
      show("找不到资料目录。", isError: true)
      return
    }
    isWorking = true
    if let busyMessage { notice = busyMessage; noticeIsError = false }
    // 备份要整库读一遍，大库上是秒级的；放后台，别把设置窗口冻住。
    Task {
      let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
        do {
          let database = try LocalDatabase.open(at: location)
          defer { try? database.close() }
          return .success(try body(DatabaseMaintenance(database: database)))
        } catch {
          return .failure(error)
        }
      }.value
      isWorking = false
      switch outcome {
      case let .success(message):
        show(message, isError: false)
        onSuccess?()
      case let .failure(error):
        show(Self.message(for: error), isError: true)
      }
      reload()
    }
  }

  private func show(_ message: String, isError: Bool) {
    notice = message
    noticeIsError = isError
  }

  private static func message(for error: Error) -> String {
    guard let failure = error as? RepositoryFailure else { return "操作没能完成，请稍后再试。" }
    switch failure {
    case .invalidInput: return "这个文件不能用：它可能已经被移走，或者同名文件已经存在。"
    case .integrityCheckFailed: return "这份备份的内容校验没通过，没有改动当前资料。"
    case .readOnly: return "当前资料库是只读打开的，不能写入。"
    default: return "操作没能完成，请稍后再试。"
    }
  }

  nonisolated static func sizeText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  nonisolated static func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

/// 数据与备份。
///
/// 这一页存在的理由很直接：汲作把所有东西都存在这台电脑上，而在此之前，用户
/// 没有任何一个地方可以按一下「先存一份」。升级时 App 会自动存，但那份备份
/// 用户也看不见、拿不到。
struct DataBackupSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @StateObject private var model = DataBackupViewModel()

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "数据与备份",
        symbol: "externaldrive.badge.timemachine",
        caption: "汲作的资料都存在这台电脑上。这里可以随时存一份，或者把资料换回之前的某一份。",
        fill: SettingsCategoryChip.fill(for: "dataBackup", theme: appTheme)
      )

      SettingsCard(
        title: "立即备份",
        summary: "把当前全部资料完整存成一个文件，放在这台电脑的备份文件夹里。",
        details: """
        升级汲作时会自动先存一份，自动存的只保留最近 3 份；你自己按下的这些一份都不会被删。
        备份包含历史记录、笔记、标签、总结和阅读进度；视频等大文件不在里面，它们本来就单独存在媒体文件夹。
        备份文件可以直接拷到移动硬盘或另一台电脑。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            if let notice = model.notice {
              SettingsInlineNotice(
                message: notice,
                tone: model.noticeIsError ? .danger : (model.needsRestart ? .warning : .info)
              )
              .accessibilityIdentifier("data-backup-status")
            }
            SettingsActionRow(showsProgress: model.isWorking) {
              Button("打开备份文件夹") { model.revealBackupsFolder() }
                .buttonStyle(.appQuiet)
                .accessibilityIdentifier("data-backup-reveal")
              Button(model.isWorking ? "处理中…" : "立即备份") { model.backupNow() }
                .buttonStyle(.appProminent(appTheme.accent))
                .disabled(model.isWorking)
                .accessibilityIdentifier("data-backup-now")
            }
          }
        }
      )

      SettingsCardGroup(header: "已有的备份") {
        if model.backups.isEmpty {
          SettingsRowGroup {
            SettingsRow(title: "还没有备份", caption: "按上面的「立即备份」存第一份。") { EmptyView() }
          }
        } else {
          SettingsRowGroup {
            ForEach(model.backups) { file in
              SettingsRow(
                title: DataBackupViewModel.dateText(file.createdAt),
                caption: "\(DataBackupViewModel.sizeText(file.byteCount)) · \(file.isAutomatic ? "升级前自动存" : "手动存")"
              ) {
                Button("恢复到这一份") { model.pendingRestore = file }
                  .buttonStyle(.appNormal)
                  .disabled(model.isWorking)
              }
            }
          }
        }
      }
    }
    .onAppear { model.reload() }
    .confirmationDialog(
      "确定把资料换回这一份备份吗？",
      isPresented: Binding(
        get: { model.pendingRestore != nil },
        set: { if !$0 { model.pendingRestore = nil } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingRestore
    ) { file in
      Button("恢复", role: .destructive) {
        model.pendingRestore = nil
        model.restore(from: file)
      }
      Button("取消", role: .cancel) { model.pendingRestore = nil }
    } message: { file in
      Text("""
        当前的全部资料会被这份 \(DataBackupViewModel.dateText(file.createdAt)) 的备份替换。
        换之前汲作会先把现在的资料另存一份，所以还能再换回来。
        换完需要退出并重新打开汲作才会生效。
        """)
    }
  }
}
