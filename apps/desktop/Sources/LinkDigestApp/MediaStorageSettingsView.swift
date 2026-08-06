import AppKit
import LinkDigestCore
import SwiftUI

struct MediaStorageSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
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
          details: "临时播放地址从不写入历史。同一次运行里，最近取过的 10 条会留在内存里，来回切换不会重复请求；退出 App 即清空。\n只有「当前打开的那一条」会触发，打开列表或启动 App 都不会批量刷新。同时最多一个请求在飞，切到别的条目会真正中止上一个——包括抖音那个后台页面，不会堆积。\n本地已保存的视频、刚抓取的当前条目和 YouTube 不走这条路，不受此项影响。",
          summaryPlacement: .aboveControl,
          controlWidth: .full
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
        // 清晰度是这张卡唯一的主控件，放标题行右端；否则它单独占一行，
        // 前面是说明、后面是解释，选择器夹在中间和谁都对不齐。
        SettingsCard(
          title: "B 站重新获取清晰度",
          summary: "「重新获取播放」时请求的清晰度上限。档位越高，起播越慢。",
          details: "公开接口一般只到 720P；4K 与会员专属档需要你自己的账号权限。实际拿到哪一档，可以看播放器下方那行选流诊断——它会写明接口返回了哪些档、最后选了哪条。",
          summaryPlacement: .aboveControl,
          control: {
            VStack(alignment: .leading, spacing: 8) {
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
          },
          titleAccessory: {
            Picker("B 站重新获取清晰度", selection: $model.bilibiliStreamQuality) {
              ForEach(BilibiliStreamQualityPreference.allCases, id: \.self) { quality in
                Text(quality.settingsTitle).tag(quality)
              }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("media-storage-bilibili-quality")
          }
        )
      }

      Section {
        // 这张卡有两件事——开不开自动保存、存到哪。不是单主控件，所以不上标题行，
        // 但要放开到整行：默认的 440pt 上限会把开关卡在卡片中间、把路径甩到半空。
        SettingsCard(
          title: "已保存的视频",
          summary: "自动保存默认关闭：抓取后的视频只在线速览、不落盘，需要长期保留时点「保存到本地」。",
          details: "手动保存和自动保存都受单个视频上限与磁盘空间预检约束。已保存视频优先从该文件夹播放；在历史里删除条目不会删除用户文件夹中的视频。",
          controlWidth: .full
        ) {
          VStack(alignment: .leading, spacing: 12) {
            // 整行 Toggle：标签在左、开关贴右边缘，就是系统设置里那种标准行。
            Toggle("抓取视频后自动保存到本地", isOn: $model.autoSaveCapturedVideo)
              .accessibilityIdentifier("media-storage-auto-save-captured-video")

            Divider()

            // 文件夹路径和它的按钮排成一行：标签+路径在左，按钮贴右。
            // 原来用 LabeledContent 把路径推到最右端，隔着大半张卡，读着像断开的两截。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("当前文件夹")
                .foregroundStyle(.secondary)
              Text(model.directoryPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("media-storage-directory")
              Spacer(minLength: 12)
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
        // 步进器是这张卡唯一的主控件，上标题行。「上限」标签和卡片标题重复，去掉，
        // 步进器自己显示当前值就够。
        SettingsCard(
          title: "单个视频上限",
          summary: "超过这个大小的视频不会下载。",
          details: "实际生效值还会再减去磁盘可用空间不足的部分，并为系统保留 2 GB；空间不够时会在开始下载前告知你。",
          control: { EmptyView() },
          titleAccessory: {
            Stepper(
              value: $model.downloadLimitMegabytes,
              in: MediaStorageSettingsViewModel.minimumLimitMegabytes...MediaStorageSettingsViewModel.maximumLimitMegabytes,
              step: MediaStorageSettingsViewModel.limitStepMegabytes
            ) {
              Text(MediaStorageSettingsViewModel.formattedLimit(megabytes: model.downloadLimitMegabytes))
                .monospacedDigit()
                .accessibilityIdentifier("media-storage-download-limit-value")
            }
            .fixedSize()
            .accessibilityIdentifier("media-storage-download-limit")
          }
        )
      }

      if case let .failed(message) = model.state {
        Section { Text(message).foregroundStyle(appTheme.danger) }
      }
    }
    .formStyle(.grouped)
    .settingsDetailContentMargins()
    .onAppear(perform: model.load)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = "选择 \(ProductDisplay.name) 保存视频的文件夹"
    guard panel.runModal() == .OK else { return }
    model.applySelection(panel.url)
  }
}
