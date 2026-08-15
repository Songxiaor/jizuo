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
    let isConfigured = AppUpdateConfiguration(infoDictionary: bundle.infoDictionary) != nil
    updaterController = SPUStandardUpdaterController(
      startingUpdater: isConfigured,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
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
