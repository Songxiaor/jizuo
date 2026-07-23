import CryptoKit
import Foundation
import LinkDigestCore

@main
struct LinkDigestBrowserSupportCrashHarness {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard
      let home = value("--home", in: arguments),
      let host = value("--host", in: arguments),
      let action = value("--action", in: arguments),
      let phase = value("--phase", in: arguments),
      let browserValue = value("--browser", in: arguments),
      let browser = BrowserSupportBrowser(rawValue: browserValue)
    else { Foundation.exit(64) }

    do {
      let template = Data("""
      {"allowed_origins":["chrome-extension://fbpjhlcpfheecigibjghhodhhkgjdgma/"],"description":"LinkDigest Native Messaging Host","name":"com.syc.linkdigest.v01","path":"__LINKDIGEST_NATIVE_HOST_PATH__","type":"stdio"}
      """.utf8)
      let hash = SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
      let artifacts = try BrowserSupportFrozenArtifacts(
        templates: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allCases.map { ($0, template) }),
        templateHashes: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allCases.map { ($0, hash) }),
        extensionID: "fbpjhlcpfheecigibjghhodhhkgjdgma",
        hostName: "com.syc.linkdigest.v01",
        version: "0.2.0",
        hostExecutableURL: URL(fileURLWithPath: host)
      )
      let installer = BrowserSupportInstaller(
        homeRoot: URL(fileURLWithPath: home),
        artifacts: artifacts,
        terminationInjection: { $0 == phase }
      )
      switch action {
      case "install":
        let status = await installer.inspect().first(where: { $0.browser == browser })
        if let fingerprint = status?.replacementFingerprint {
          try await installer.confirmReplacement(browser, expectedFingerprint: fingerprint)
        } else {
          try await installer.install(browser)
        }
      case "uninstall":
        try await installer.uninstall(browser)
      case "restore":
        try await installer.restoreLatestBackup(browser)
      default:
        Foundation.exit(64)
      }
      Foundation.exit(0)
    } catch {
      Foundation.exit(70)
    }
  }

  private static func value(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}
