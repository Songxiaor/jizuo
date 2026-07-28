import AppKit
import LinkDigestCore
import SwiftUI

struct MediaStorageSettingsView: View {
  @ObservedObject var model: MediaStorageSettingsViewModel

  var body: some View {
    Form {
      // 原来「历史在线播放」和「B 站清晰度」挤在同一个 Section，footer 还把
      // 播放缓存、清晰度、登录依赖三件事混成一段。拆成各自的卡。
      Section {
        SettingsCard(
          title: "历史在线播放",
          // 签名播放地址会过期、从不入库，所以历史里的视频要在线播就得现去换一个。
          // 这两个选项决定的只是「什么时候去换」。
          summary: "历史里的视频要在线播，必须现去平台换一个临时地址。这里决定打开条目时是自动去换，还是等你点。",
          details: "临时播放地址从不写入历史。退出 App 后只在内存中保留最近最多 10 条已恢复的播放结果，更早的条目需要再次获取；打开列表或启动 App 不会批量刷新。\n本地已保存的视频、刚抓取的当前条目和 YouTube 不走这条路，不受此项影响。",
          summaryPlacement: .aboveControl
        ) {
          SettingsChoiceList(
            choices: SessionMediaRestoreMode.allCases.map {
              .init(value: $0, title: $0.settingsTitle, explanation: $0.settingsExplanation)
            },
            selection: $model.sessionMediaRestoreMode,
            identifierPrefix: "media-storage-session-restore-mode"
          )
        }
      }

      Section {
        SettingsCard(
          title: "B 站重新获取清晰度",
          summary: "「重新获取播放」时请求的清晰度上限。档位越高，起播越慢。",
          details: "公开接口一般只到 720P；4K 与会员专属档需要你自己的账号权限。实际拿到哪一档，可以看播放器下方那行选流诊断——它会写明接口返回了哪些档、最后选了哪条。",
          summaryPlacement: .aboveControl
        ) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("B 站重新获取清晰度", selection: $model.bilibiliStreamQuality) {
              ForEach(BilibiliStreamQualityPreference.allCases, id: \.self) { quality in
                Text(quality.settingsTitle).tag(quality)
              }
            }
            .labelsHidden()
            .accessibilityIdentifier("media-storage-bilibili-quality")

            Text(model.bilibiliStreamQuality.settingsExplanation)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("media-storage-bilibili-quality-explanation")

            // 跨页依赖必须给出去处：只说「依赖本机会话」，读者还得自己找那一页。
            SettingsCrossReference(
              message: "高清依赖「站点登录 → B 站」里的本机会话；未登录时回退公开接口。"
            )
            .accessibilityIdentifier("media-storage-bilibili-login-hint")
          }
        }
      }

      Section {
        SettingsCard(
          title: "已保存的视频",
          summary: "自动保存默认关闭：抓取后的视频只在线速览、不落盘，需要长期保留时点「保存到本地」。",
          details: "手动保存和自动保存都受单个视频上限与磁盘空间预检约束。已保存视频优先从该文件夹播放；在历史里删除条目不会删除用户文件夹中的视频。"
        ) {
          VStack(alignment: .leading, spacing: 8) {
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
          }
        }
      }

      Section {
        SettingsCard(
          title: "单个视频上限",
          summary: "超过这个大小的视频不会下载。",
          details: "实际生效值还会再减去磁盘可用空间不足的部分，并为系统保留 2 GB；空间不够时会在开始下载前告知你。"
        ) {
          Stepper(
            value: $model.downloadLimitGigabytes,
            in: MediaStorageSettingsViewModel.minimumLimitGigabytes...MediaStorageSettingsViewModel.maximumLimitGigabytes
          ) {
            LabeledContent("上限") {
              Text("\(model.downloadLimitGigabytes) GB")
                .monospacedDigit()
                .accessibilityIdentifier("media-storage-download-limit-value")
            }
          }
          .accessibilityIdentifier("media-storage-download-limit")
        }
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
