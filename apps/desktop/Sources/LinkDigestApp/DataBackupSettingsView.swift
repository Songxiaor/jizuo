import AppKit
import Foundation
import LinkDigestCore
import LinkDigestPersistence
import SwiftUI

/// 「备份恢复」的取数与动作。
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
  /// 每日自动备份的开关与上次结果。跟着数据目录走（见 `DailyBackupPreferences`），
  /// 不再从 UserDefaults 读——隔离数据目录的调试版不能改写真实 App 的备份状态。
  @Published private(set) var dailyBackupEnabled = true
  @Published private(set) var dailyLastSuccessAt: Date?
  @Published private(set) var dailyFailureReason: String?

  private var resolvedLocation: LocalDatabaseLocation?

  var backupsDirectoryURL: URL? {
    location().map { DatabaseBackupStore(location: $0).directoryURL }
  }

  private var preferences: DailyBackupPreferences? {
    location().map { DailyBackupPreferences(directoryURL: $0.directoryURL) }
  }

  func refreshDailyBackupStatus() {
    guard let preferences else { return }
    dailyBackupEnabled = preferences.isEnabled
    dailyLastSuccessAt = preferences.lastSuccessAt
    dailyFailureReason = preferences.lastFailureReason
  }

  func setDailyBackupEnabled(_ enabled: Bool) {
    guard let preferences else { return }
    preferences.isEnabled = enabled
    refreshDailyBackupStatus()
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
      // 文件名是内部格式（history-manual-时间戳.sqlite），用户看时间和大小就够；文件在下面列表里。
      return "已备份（\(Self.sizeText(file.byteCount))），在下面「备份记录」里"
    }
  }

  func restore(from file: DatabaseBackupFile) {
    perform(busyMessage: nil) { maintenance in
      _ = try maintenance.restoreInPlace(from: file.url)
      return "已恢复，恢复前的资料另存在下面「备份记录」里。请退出并重新打开汲作。"
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
        // 和每日自动备份互斥：整库读写同时跑两份没有好处。
        guard DatabaseBackupActivity.tryBegin() else {
          return .failure(DatabaseBackupBusyError())
        }
        defer { DatabaseBackupActivity.end() }
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
    if error is DatabaseBackupBusyError {
      return "正在自动备份，稍等一下再试。"
    }
    guard let failure = error as? RepositoryFailure else { return "操作没能完成，请稍后再试。" }
    switch failure {
    case .invalidInput: return "这个文件用不了：可能被移走了，或者已有同名文件。"
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

  nonisolated static func kindText(_ file: DatabaseBackupFile) -> String {
    if file.isDaily { return "每日自动备份" }
    if file.isBeforeRestore { return "恢复前备份" }
    if file.isAutomatic { return "升级前自动备份" }
    return "手动备份"
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

  private var dailyStatusText: String {
    var lines: [String] = []
    if let date = model.dailyLastSuccessAt {
      lines.append("上次自动备份：\(DataBackupViewModel.dateText(date))")
    } else {
      lines.append("还没有自动备份过；汲作开满几分钟后会存第一份。")
    }
    if let reason = model.dailyFailureReason {
      lines.append("最近一次没成功：\(reason)")
    }
    if !model.dailyBackupEnabled {
      lines.append("现在是关闭状态，不会自动备份。")
    }
    return lines.joined(separator: "\n")
  }

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "备份",
        symbol: "clock.arrow.circlepath",
        caption: "随时存一份，也能换回旧的",
        fill: SettingsCategoryChip.fill(for: "dataBackup", theme: appTheme)
      )

      SettingsCard(
        title: "每日自动备份",
        summary: "汲作开着时，每天替你存一份",
        details: """
        离上次成功备份满 24 小时才存一份；汲作没开着不备份，下次打开会补上。
        只留最近 7 份；手动备份、升级前备份和恢复前备份不受这个上限影响，一份都不会被删。
        备份只有资料库，不含视频等大文件。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Toggle("开启每日自动备份", isOn: Binding(
              get: { model.dailyBackupEnabled },
              set: { model.setDailyBackupEnabled($0) }
            ))
              .toggleStyle(.switch)
              .accessibilityIdentifier("data-backup-daily-enabled")
            Text(dailyStatusText)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("data-backup-daily-status")
          }
        }
      )

      SettingsCard(
        title: "立即备份",
        summary: "把全部资料存成一个文件",
        details: """
        你手动存的备份都不会自动删；升级汲作前 App 也会另存一份，那种自动备份只留最近 3 份。
        备份含历史、笔记、标签、总结和阅读进度；视频等大文件不在里面，它们单独存在媒体文件夹。
        备份文件可以直接拷到移动硬盘或别的电脑。
        """,
        summaryPlacement: .aboveControl,
        controlWidth: .full,
        control: {
          VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            if let notice = model.notice {
              SettingsInlineNotice(
                message: notice,
                tone: model.noticeIsError ? .danger : (model.needsRestart ? .warning : .success)
              )
              .accessibilityIdentifier("data-backup-status")
            }
            SettingsActionRow(showsProgress: model.isWorking) {
              Button("打开位置") { model.revealBackupsFolder() }
                .buttonStyle(.appNormal)
                .accessibilityIdentifier("data-backup-reveal")
              Button(model.isWorking ? "处理中…" : "立即备份") { model.backupNow() }
                .buttonStyle(.appProminent(appTheme.accent))
                .disabled(model.isWorking)
                .accessibilityIdentifier("data-backup-now")
            }
          }
        }
      )

      SettingsCardGroup(header: "备份记录") {
        if model.backups.isEmpty {
          SettingsRowGroup {
            SettingsRow(title: "还没有备份", caption: "按上面的「立即备份」存第一份。") { EmptyView() }
          }
        } else {
          SettingsRowGroup {
            ForEach(model.backups) { file in
              SettingsRow(
                title: DataBackupViewModel.dateText(file.createdAt),
                caption: "\(DataBackupViewModel.sizeText(file.byteCount)) · \(DataBackupViewModel.kindText(file))"
              ) {
                Button("恢复") { model.pendingRestore = file }
                  .buttonStyle(.appNormal)
                  .disabled(model.isWorking)
              }
            }
          }
        }
      }
    }
    .onAppear {
      model.reload()
      model.refreshDailyBackupStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: .dailyBackupDidFinish)) { _ in
      model.reload()
      model.refreshDailyBackupStatus()
    }
    .confirmationDialog(
      "换回这份备份？",
      isPresented: Binding(
        get: { model.pendingRestore != nil },
        set: { if !$0 { model.pendingRestore = nil } }
      ),
      titleVisibility: .visible,
      presenting: model.pendingRestore
    ) { file in
      Button("用这份备份替换当前资料", role: .destructive) {
        model.pendingRestore = nil
        model.restore(from: file)
      }
      Button("取消", role: .cancel) { model.pendingRestore = nil }
    } message: { file in
      Text("""
        当前资料会被这份 \(DataBackupViewModel.dateText(file.createdAt)) 的备份替换。
        换之前会先另存一份，还能换回来；换完要重新打开汲作。
        """)
    }
  }
}
