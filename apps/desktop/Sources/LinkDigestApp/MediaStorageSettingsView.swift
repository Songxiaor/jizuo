import AppKit
import SwiftUI

struct MediaStorageSettingsView: View {
  @ObservedObject var model: MediaStorageSettingsViewModel

  var body: some View {
    Form {
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
        Text("自动保存默认开启，会占用所选文件夹的磁盘空间；手动保存和自动保存都受单个视频上限与磁盘空间预检约束。已保存视频优先从该文件夹播放；历史删除不会删除用户文件夹中的视频。")
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
