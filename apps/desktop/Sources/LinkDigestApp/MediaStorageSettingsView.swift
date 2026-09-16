import AppKit
import LinkDigestCore
import SwiftUI

struct MediaStorageSettingsView: View {
  // 错误色走主题：写死 .red 在暖褐主题上是全屏最跳的一块，
  // 在高对比主题上又不够黑。
  @Environment(\.appTheme) private var appTheme
  @ObservedObject var model: MediaStorageSettingsViewModel
  /// 删除扫出来的那份清单前先问一句：这些是已经落在本机磁盘上的视频文件，删了就没了。
  @State private var isUnusedDeletionConfirmationPresented = false
  /// 「恢复默认」会让之后的视频改存到 App 自己的目录，是一次会改变落盘位置的动作。
  @State private var isRestoreDefaultConfirmationPresented = false

  var body: some View {
    SettingsPlainPage {
      SettingsPageHeader(
        title: "视频存储",
        symbol: "externaldrive",
        caption: "决定历史里的视频怎么在线播、清晰度上限，以及要不要留一份在本机。",
        fill: SettingsCategoryChip.fill(for: "mediaStorage", theme: appTheme)
      )

      // 原来「历史在线播放」和「B 站清晰度」挤在同一个 Section，footer 还把
      // 播放缓存、清晰度、登录依赖三件事混成一段。拆成各自的卡。
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

      // 清晰度是这张卡唯一的主控件，放标题行右端；否则它单独占一行，
      // 前面是说明、后面是解释，选择器夹在中间和谁都对不齐。
      // 当前档位的解释收进 ⓘ（随选择变化），卡里只留一句跨页去处。
      // 原来三段说明层层递进：一句 summary、一段灰字、再一行带箭头的依赖提示，
      // 一个下拉配了三段字。
      SettingsCard(
        title: "B 站重新获取清晰度",
        summary: "「重新获取播放」时请求的清晰度上限。档位越高，起播越慢。",
        details: model.bilibiliStreamQuality.settingsExplanation
          + "\n公开接口一般只到 720P；4K 与会员专属档需要你自己的账号权限。实际拿到哪一档，可以看播放器下方那行选流诊断——它会写明接口返回了哪些档、最后选了哪条。",
        summaryPlacement: .aboveControl,
        control: {
          // 跨页依赖必须给出去处：只说「依赖本机会话」，读者还得自己找那一页。
          SettingsCrossReference(
            message: "高清需先在「站点登录 → B 站」登录；未登录时回退公开接口。"
          )
          .accessibilityIdentifier("media-storage-bilibili-login-hint")
        },
        titleAccessory: {
          SettingsMenuPicker(
            sections: [BilibiliStreamQualityPreference.allCases.map { .init(value: $0, title: $0.settingsTitle) }],
            selection: $model.bilibiliStreamQuality,
            identifier: "media-storage-bilibili-quality"
          )
          .accessibilityLabel("B 站重新获取清晰度")
        }
      )

      // 「自动保存开关」「保存文件夹」「单个视频上限」原来各占一张整卡，但三项
      // 都只是「一句说明 + 一个控件」，收进同一张行式卡片：都是在回答
      // 「已保存的视频存不存、存哪、多大不存」这一件事。
      // 三行都在回答「已保存的视频存不存、存哪、多大不存」；不再给它单独一个
      // 组标题——前两张卡都没有组标题，只有第三张有，看起来像漏了两个。
      SettingsRowGroup {
          // 整行 Toggle：标签在左、开关贴右边缘，就是系统设置里那种标准行。
          SettingsRow(
            title: "抓取视频后自动保存到本地",
            caption: "自动保存默认关闭：抓取后的视频只在线速览、不落盘，需要长期保留时点「保存到本地」。"
          ) {
            Toggle("", isOn: $model.autoSaveCapturedVideo)
              .toggleStyle(.switch)
              .labelsHidden()
              .accessibilityLabel("抓取视频后自动保存到本地")
              .accessibilityIdentifier("media-storage-auto-save-captured-video")
          }

          // 路径和按钮放进控件列：标签在左，路径+按钮贴右，与其它行同一套对齐。
          SettingsRow(
            title: "当前文件夹",
            details: "手动保存和自动保存都受单个视频上限与磁盘空间预检约束。已保存视频优先从该文件夹播放；在历史里删除条目不会删除用户文件夹中的视频。"
          ) {
            HStack(spacing: DesignTokens.Space.sm) {
              Text(model.directoryPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("media-storage-directory")
              Button(model.usesCustomDirectory ? "更改文件夹" : "选择文件夹", action: chooseDirectory)
                .buttonStyle(.appNormal)
                .accessibilityIdentifier("media-storage-choose")
              // 恢复默认会改掉之后视频的落盘位置，属于「重置」类动作：危险色 + 先问一句。
              Button("恢复默认") { isRestoreDefaultConfirmationPresented = true }
                .buttonStyle(.appDestructive(appTheme.danger))
                .disabled(!model.usesCustomDirectory)
                .accessibilityIdentifier("media-storage-default")
                .confirmationDialog(
                  "把保存位置改回汲作自己的文件夹？",
                  isPresented: $isRestoreDefaultConfirmationPresented,
                  titleVisibility: .visible
                ) {
                  Button("恢复默认", role: .destructive) { model.restoreDefault() }
                    .accessibilityIdentifier("media-storage-default-confirm")
                  Button("取消", role: .cancel) {}
                } message: {
                  Text("你现在这个文件夹里的视频一个都不会动，只是以后新下载的视频改存到汲作自己的文件夹。随时可以再选回来。")
                }
            }
          }

          // 「上限」标签和行标题重复，去掉，步进器自己显示当前值就够。
          SettingsRow(
            title: "单个视频上限",
            caption: "超过这个大小的视频不会下载。",
            details: "实际生效值还会再减去磁盘可用空间不足的部分，并为系统保留 2 GB；空间不够时会在开始下载前告知你。"
          ) {
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

          // 总容量上限：默认关闭 = 不限制。开启后新下载写盘前会按"最久没碰过"
          // 淘汰超出的部分——记录留在历史里，只是文件没了，可以重新获取。
          SettingsRow(
            title: "本地视频总容量上限",
            caption: "关闭时不限制。开启后，新下载写入前会自动删掉最久没碰过的本地视频文件。",
            details: "被删掉的只是文件，历史记录还在——那条记录会回到「暂不可播 / 重新获取」的状态，随时能再下一次。\n只清理 App 自己的视频目录；你自己选的文件夹里的视频永远不动。"
          ) {
            HStack(spacing: DesignTokens.Space.sm) {
              Toggle("", isOn: $model.totalCapacityEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("本地视频总容量上限")
                .accessibilityIdentifier("media-storage-total-capacity-enabled")
              Stepper(
                value: $model.totalCapacityGigabytes,
                in: MediaStorageSettingsViewModel.minimumCapacityGigabytes...MediaStorageSettingsViewModel.maximumCapacityGigabytes,
                step: MediaStorageSettingsViewModel.capacityStepGigabytes
              ) {
                Text("\(model.totalCapacityGigabytes) GB")
                  .monospacedDigit()
                  .accessibilityIdentifier("media-storage-total-capacity-value")
              }
              .fixedSize()
              .disabled(!model.totalCapacityEnabled)
              .accessibilityIdentifier("media-storage-total-capacity")
            }
          }

          // 没被任何内容用到的视频：扫描和删除分两步，中间一定停在"有多少、多大"上。
          // 这些是用户已经保存到本机的视频，删了就没了，不给一键删。
          SettingsRow(
            title: "没被任何内容用到的视频",
            caption: orphanCaption,
            details: "视频文件夹里有些视频，已经不属于你保存的任何一条内容了——多数是早期版本删记录时没一起删掉的。扫描只看不删，确认之后才会删除，而且只删这次扫出来的那份清单。"
          ) {
            HStack(spacing: DesignTokens.Space.sm) {
              Button("扫描一下", action: model.scanOrphans)
                .buttonStyle(.appNormal)
                .disabled(model.orphanState == .unavailable || model.orphanState == .scanning)
                .accessibilityIdentifier("media-storage-scan-orphans")
              if case let .scanned(count, bytes) = model.orphanState, count > 0 {
                // 删除是不可逆的：文件从磁盘上消失，不进废纸篓。先问一句，并把
                // 数量和体积再报一遍——用户点确认之前要看见自己删的是多少东西。
                Button("删除这 \(count) 个文件") { isUnusedDeletionConfirmationPresented = true }
                  .buttonStyle(.appDestructive(appTheme.danger))
                  .accessibilityIdentifier("media-storage-delete-orphans")
                  .confirmationDialog(
                    "删除这 \(count) 个没被用到的视频文件？",
                    isPresented: $isUnusedDeletionConfirmationPresented,
                    titleVisibility: .visible
                  ) {
                    Button("删除这 \(count) 个文件", role: .destructive) { model.deleteScannedOrphans() }
                      .accessibilityIdentifier("media-storage-delete-orphans-confirm")
                    Button("取消", role: .cancel) {}
                  } message: {
                    Text("会从磁盘上删掉这 \(count) 个文件，共 \(MediaStorageSettingsViewModel.formattedBytes(bytes))，不进废纸篓，删了没法撤销。你保存的内容和历史记录一条都不会少，只删这次扫出来的这份清单。")
                  }
              }
            }
          }
      }

      if case let .failed(message) = model.state {
        Text(message)
          .foregroundStyle(appTheme.danger)
          .padding(.vertical, DesignTokens.Space.md)
          .padding(.horizontal, DesignTokens.Space.lg)
          .modifier(SettingsThemedCardChrome())
      }
    }
    .onAppear(perform: model.load)
  }

  /// 扫描结果直接写在说明行里：用户要先看见"多少个、多大"，才谈得上确认删除。
  private var orphanCaption: String {
    switch model.orphanState {
    case .unavailable:
      "现在读不到你保存的内容清单，所以暂时没法判断哪些视频没人用。重新打开汲作后再试。"
    case .idle:
      "看看视频文件夹里有哪些视频已经不属于你保存的任何内容。只扫描，不会直接删。"
    case .scanning:
      "正在扫描…"
    case let .scanned(count, bytes):
      count == 0
        ? "每个视频都还被用着，没有可清理的。"
        : "找到 \(count) 个没被用到的视频，共 \(MediaStorageSettingsViewModel.formattedBytes(bytes))。确认后才会删除。"
    case let .deleted(count, bytes):
      "已删除 \(count) 个文件，释放 \(MediaStorageSettingsViewModel.formattedBytes(bytes))。"
    case let .failed(message):
      message
    }
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
