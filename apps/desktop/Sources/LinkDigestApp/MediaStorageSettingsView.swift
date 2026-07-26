import AppKit
import LinkDigestCore
import SwiftUI

struct MediaStorageSettingsView: View {
  @ObservedObject var model: MediaStorageSettingsViewModel

  var body: some View {
    Form {
      Section {
        Picker("历史在线播放", selection: $model.sessionMediaRestoreMode) {
          ForEach(SessionMediaRestoreMode.allCases, id: \.self) { mode in
            Text(mode.settingsTitle).tag(mode)
          }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("media-storage-session-restore-mode")

        Text(model.sessionMediaRestoreMode.settingsExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("media-storage-session-restore-explanation")

        Picker("B 站重新获取清晰度", selection: $model.bilibiliStreamQuality) {
          ForEach(BilibiliStreamQualityPreference.allCases, id: \.self) { quality in
            Text(quality.settingsTitle).tag(quality)
          }
        }
        .accessibilityIdentifier("media-storage-bilibili-quality")

        Text(model.bilibiliStreamQuality.settingsExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("media-storage-bilibili-quality-explanation")
      } header: {
        Text("流式播放恢复")
      } footer: {
        Text("临时播放地址从不写入历史。退出 App 后只会在内存中保留最近最多 10 条已恢复的播放结果；更早的条目需要再次获取。打开列表或启动 App 不会批量刷新。B 站高清依赖「设置 → 站点登录」中的本机会话；未登录时回退公开接口。账号登录请到侧栏「站点登录」管理。")
      }

      Section {
        Toggle("抓取视频后自动保存到本地", isOn: $model.autoSaveCapturedVideo)
          .accessibilityIdentifier("media-storage-auto-save-captured-video")

        LabeledContent("当前文件夹") {
          Text(model.directoryPath)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityIdentifier("media-storage-directory")
        }
        HStack {
          Button(model.usesCustomDirectory ? "更改文件夹" : "选择文件夹", action: chooseDirectory)
            .accessibilityIdentifier("media-storage-choose")
          Button("恢复默认", action: model.restoreDefault)
            .disabled(!model.usesCustomDirectory)
            .accessibilityIdentifier("media-storage-default")
        }
      } header: {
        Text("已保存的视频")
      } footer: {
        Text("自动保存默认关闭，抓取后的视频默认只在线速览、不落盘；需要长期保留时请点「保存到本地」。手动保存和自动保存都受单个视频上限与磁盘空间预检约束。已保存视频优先从该文件夹播放；历史删除不会删除用户文件夹中的视频。")
      }

      Section {
        Stepper(
          value: $model.downloadLimitGigabytes,
          in: MediaStorageSettingsViewModel.minimumLimitGigabytes...MediaStorageSettingsViewModel.maximumLimitGigabytes
        ) {
          LabeledContent("单个视频上限") {
            Text("\(model.downloadLimitGigabytes) GB")
              .monospacedDigit()
              .accessibilityIdentifier("media-storage-download-limit-value")
          }
        }
        .accessibilityIdentifier("media-storage-download-limit")
      } footer: {
        Text("超过这个大小的视频不会下载。实际生效值还会再减去磁盘可用空间不足的部分，并为系统保留 2 GB；空间不够时会在开始下载前告知你。")
      }

      if case let .failed(message) = model.state {
        Section { Text(message).foregroundStyle(.red) }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .onAppear(perform: model.load)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = "选择 LinkDigest 保存视频的文件夹"
    guard panel.runModal() == .OK else { return }
    model.applySelection(panel.url)
  }
}
