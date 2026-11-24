import AppKit
import LinkDigestCore
import SwiftUI

/// 「正在录制」列表。只讲三件事：在录谁、录了多久/多大、现在是什么状态。
/// 停止按钮只对进行中的记录出现；已经完成的可以打开文件或在汲作里找到那条素材。
struct LiveRecordingPanelView: View {
  @ObservedObject var controller: LiveRecordingController
  @ObservedObject private var preferences: LiveRecordingPreferences
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var appTheme

  init(controller: LiveRecordingController) {
    self.controller = controller
    _preferences = ObservedObject(wrappedValue: controller.preferences)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      header
      directoryRow
      if let warning = probeWarning {
        Text(warning)
          .font(.system(size: 11))
          .foregroundStyle(appTheme.warning)
      }
      if controller.items.isEmpty {
        emptyState
      } else {
        ScrollView {
          VStack(spacing: DesignTokens.Space.sm) {
            ForEach(controller.items) { item in
              row(item)
            }
          }
        }
      }
      HStack {
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(DesignTokens.Space.lg)
    .frame(width: 640, height: 520)
    .onAppear { controller.refreshFreeSpace() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
      Text("直播录制")
        .font(.system(size: 20, weight: .semibold))
      if controller.activeCount > 0 {
        Text("\(controller.activeCount) 场进行中")
          .font(.system(size: 12))
          .foregroundStyle(appTheme.secondaryText)
      }
      Spacer()
      Text("在抖音或小红书直播间点扩展里的「开始录制」")
        .font(.system(size: 11))
        .foregroundStyle(appTheme.secondaryText)
    }
  }

  private var directoryRow: some View {
    HStack(spacing: DesignTokens.Space.sm) {
      Text("存放位置")
        .font(.system(size: 12))
        .foregroundStyle(appTheme.secondaryText)
      Text(preferences.displayPath)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(preferences.recordingDirectory.path)
      Spacer()
      Button("更改…") { chooseDirectory() }
        .controlSize(.small)
      if preferences.customDirectoryPath != nil {
        Button("恢复默认") { preferences.setDirectory(nil) }
          .controlSize(.small)
      }
      Text(freeSpaceText)
        .font(.system(size: 11))
        .foregroundStyle(appTheme.secondaryText)
    }
  }

  private var emptyState: some View {
    VStack(spacing: DesignTokens.Space.sm) {
      Text("还没有录制")
        .font(.system(size: 15, weight: .medium))
      Text("打开抖音或小红书直播间，点浏览器扩展里的「开始录制」。录制在后台进行，关掉网页不影响。")
        .font(.system(size: 12))
        .foregroundStyle(appTheme.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func row(_ item: LiveRecordingController.Item) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: DesignTokens.Space.sm) {
        Text(item.displayName)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        phaseBadge(item.phase)
        Spacer()
        Text(Self.duration(item.elapsed))
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(appTheme.secondaryText)
        Text(Self.byteCount(item.bytes))
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(appTheme.secondaryText)
      }
      HStack(spacing: DesignTokens.Space.sm) {
        Text("\(item.quality.displayName) · \(item.segmentCount) 段 · 还能录\(LiveRecordingDiskSpace.estimatedHoursText(freeBytes: controller.freeBytes, quality: item.quality))")
          .font(.system(size: 11))
          .foregroundStyle(appTheme.secondaryText)
        if let title = item.title, !title.isEmpty, title != item.displayName {
          Text(title)
            .font(.system(size: 11))
            .foregroundStyle(appTheme.secondaryText)
            .lineLimit(1)
        }
        Spacer()
        if item.phase == .recording || isActive(item.phase) {
          Button("停止") { controller.stop(item.id) }
            .controlSize(.small)
        }
        if item.phase == .merging {
          Text("正在合成…")
            .font(.system(size: 11))
            .foregroundStyle(appTheme.secondaryText)
        }
        if item.phase == .completed {
          Button("打开文件") { controller.reveal(item.id) }
            .controlSize(.small)
          if item.isIngesting {
            Text("正在入库…")
              .font(.system(size: 11))
              .foregroundStyle(appTheme.secondaryText)
          }
          if Self.showsRemoveButton(phase: item.phase, isIngesting: item.isIngesting) {
            Button("移除") { controller.dismiss(item.id) }
              .controlSize(.small)
          }
        }
        if case .failed = item.phase {
          if Self.showsRemoveButton(phase: item.phase, isIngesting: item.isIngesting) {
            Button("移除") { controller.dismiss(item.id) }
              .controlSize(.small)
          }
        }
        if Self.showsSegmentsButton(phase: item.phase, failureMessage: item.failureMessage),
           let directory = item.segmentsDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
          Button("打开分段文件夹") { controller.revealSegments(item.id) }
            .controlSize(.small)
        }
      }
      if let failure = item.failureMessage, !failure.isEmpty {
        Text(failure)
          .font(.system(size: 11))
          .foregroundStyle(appTheme.danger)
      }
      if let note = item.qualityNote, !note.isEmpty {
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(appTheme.warning)
      }
      if item.phase == .completed, let reason = item.stopReason {
        Text(Self.stopReasonText(reason, platform: item.platform))
          .font(.system(size: 11))
          .foregroundStyle(appTheme.secondaryText)
      }
      if let fileURL = item.fileURL, item.phase == .completed {
        Text(fileURL.path)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(appTheme.secondaryText)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if item.phase == .completed, !item.additionalFileURLs.isEmpty {
        Text("共 \(item.additionalFileURLs.count + 1) 个文件（编码不同，分开保存）")
          .font(.system(size: 10.5))
          .foregroundStyle(appTheme.secondaryText)
      }
    }
    .padding(10)
    .background(appTheme.card, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(appTheme.hairline, lineWidth: 1)
    )
  }

  private func isActive(_ phase: LiveRecordingPhase) -> Bool {
    if case .reconnecting = phase { return true }
    return phase == .preparing
  }

  /// 找不到 ffprobe 时，只要还有在录的记录就提醒一次：合并阶段的编码分组靠它。
  private var probeWarning: String? {
    LiveRecordingController.probeWarning(
      isProbeAvailable: controller.isProbeAvailable,
      hasActiveRecording: controller.items.contains { item in
        switch item.phase {
        case .recording, .reconnecting, .preparing, .merging: return true
        case .completed, .failed: return false
        }
      }
    )
  }

  private var freeSpaceText: String {
    let quality = controller.items.first(where: { $0.phase == .recording })?.quality
      ?? controller.items.first?.quality
      ?? .origin
    return "剩余空间\(LiveRecordingDiskSpace.estimatedHoursText(freeBytes: controller.freeBytes, quality: quality))"
  }

  static func stopReasonText(_ reason: LiveRecordingStopReason, platform: LiveRecordingPlatform) -> String {
    switch reason {
    case .verificationRequired:
      return "\(platform.displayName)要你先在浏览器里完成验证。打开这个直播间完成验证后，再点一次「开始录制」。已录的部分保留了。"
    default:
      return reason.displayText
    }
  }

  private func phaseBadge(_ phase: LiveRecordingPhase) -> some View {
    let (text, color): (String, Color) = {
      switch phase {
      case .preparing: return ("连接中", appTheme.secondaryText)
      case .recording: return ("录制中", appTheme.danger)
      case let .reconnecting(attempt): return ("重连中 \(attempt)", appTheme.warning)
      case .merging: return ("正在合并", appTheme.secondaryText)
      case .completed: return ("已完成", appTheme.success)
      case .failed: return ("失败", appTheme.danger)
      }
    }()
    return Text(text)
      .font(.system(size: 10.5, weight: .semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "用这个文件夹"
    panel.directoryURL = preferences.recordingDirectory
    guard panel.runModal() == .OK, let url = panel.url else { return }
    preferences.setDirectory(url)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
  }

  static func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
  }

  /// 「移除」只在成品定下来之后出现：入库还没完成时移除，会把入库失败的提示一起弄丢。
  static func showsRemoveButton(phase: LiveRecordingPhase, isIngesting: Bool) -> Bool {
    switch phase {
    case .completed: return !isIngesting
    case .failed: return true
    default: return false
    }
  }

  /// 合并没全成功时（整条失败，或部分成品已入库、剩下的分组还在 .parts），
  /// 给一个能找到分段文件夹的入口，别只留一行路径文字。
  static func showsSegmentsButton(phase: LiveRecordingPhase, failureMessage: String?) -> Bool {
    switch phase {
    case .failed: return true
    case .completed: return failureMessage?.isEmpty == false
    default: return false
    }
  }
}
