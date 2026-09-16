import Combine
import Foundation
import Sparkle
import SwiftUI

struct AppUpdateConfiguration: Equatable {
  let feedURL: URL
  let publicEDKey: String
  let automaticallyUpdates: Bool

  init?(infoDictionary: [String: Any]?) {
    guard
      let infoDictionary,
      let feedURLText = infoDictionary["SUFeedURL"] as? String,
      let feedURL = URL(string: feedURLText),
      feedURL.scheme == "https",
      feedURL.user == nil,
      feedURL.password == nil,
      let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
      Data(base64Encoded: publicEDKey)?.count == 32,
      let automaticallyUpdates = infoDictionary["SUAutomaticallyUpdate"] as? Bool
    else { return nil }

    self.feedURL = feedURL
    self.publicEDKey = publicEDKey
    self.automaticallyUpdates = automaticallyUpdates
  }
}

@MainActor
final class AppUpdateController {
  let updaterController: SPUStandardUpdaterController

  init(bundle: Bundle = .main) {
    // `swift run` and test bundles do not use the release Info.plist. Keeping
    // Sparkle stopped there avoids a misleading "updater misconfigured" alert;
    // packaged Apps always carry the validated feed and Ed25519 public key.
    let configuration = AppUpdateConfiguration(infoDictionary: bundle.infoDictionary)
    updaterController = SPUStandardUpdaterController(
      startingUpdater: configuration != nil,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    // `SUAutomaticallyUpdate` 从 Info.plist 解析出来之后，必须**显式写进 updater**。
    //
    // 在此之前它只是被读进了 `AppUpdateConfiguration.automaticallyUpdates`，然后
    // 就没有任何一处用过它——Sparkle 于是走自己的默认值。守这条承诺的测试断言的
    // 又是源码里有没有那行字，源码里确实有，所以测试一直绿着，而真实行为可以
    // 是任何值。字段解析了不用，比没解析更危险：它看起来像已经生效了。
    //
    // 这一版固定不静默下载（plist 里是 false）：更新要经过用户点一次「安装」，
    // 而不是某天打开 App 发现版本自己变了。
    updaterController.updater.automaticallyDownloadsUpdates = configuration?.automaticallyUpdates ?? false
  }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
  @Published private(set) var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }
}

@MainActor
private struct CheckForUpdatesButton: View {
  @ObservedObject private var model: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    model = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    Button("检查更新…", action: updater.checkForUpdates)
      .disabled(!model.canCheckForUpdates)
  }
}

struct AppUpdateCommands: Commands {
  let updater: SPUUpdater

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      CheckForUpdatesButton(updater: updater)
    }
  }
}
