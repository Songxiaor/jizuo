import Foundation
import LinkDigestTransport

/// Opens the co-located LinkDigest.app when the capture socket is offline so a
/// browser "send" can cold-start the product. Only the peer bundle is eligible.
enum AppColdStart {
  static func autoLaunchDisabledFrom(_ environment: [String: String]) -> Bool {
    let raw = environment["LINKDIGEST_DISABLE_AUTO_LAUNCH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return raw == "1" || raw == "true" || raw == "yes"
  }

  /// Launch the peer app once. Does not probe the socket (probes steal accept slots).
  static func launchPeerAppIfNeeded(
    hostExecutable: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    launcher: (URL) throws -> Void = launchWithOpen,
    log: (String) -> Void = { _ in }
  ) -> Bool {
    if autoLaunchDisabledFrom(environment) {
      log("auto-launch disabled by env")
      return false
    }
    guard let appBundle = AppBundleLocator.resolveAppBundle(
      fromNativeHostExecutable: hostExecutable,
      environment: environment
    ) else {
      log("could not resolve co-located .app from \(hostExecutable.path)")
      return false
    }
    guard appBundle.pathExtension == "app",
          fileManager.fileExists(atPath: appBundle.path)
    else {
      log("resolved path is not an existing .app: \(appBundle.path)")
      return false
    }
    do {
      log("opening \(appBundle.path)")
      try launcher(appBundle)
      return true
    } catch {
      log("open failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Uses `/usr/bin/open` so Launch Services reuses a running instance when possible.
  static func launchWithOpen(_ appBundle: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // Absolute .app path only — never a free-form name that could resolve elsewhere.
    // Bring the app forward so cold-start is visible (users previously reported "flash quit"
    // when the window never appeared in front).
    process.arguments = [appBundle.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw POSIXError(.EIO)
    }
  }

  static func remainingTimeout(since start: Date, total: TimeInterval, floor: TimeInterval = 1) -> TimeInterval {
    max(floor, total - Date().timeIntervalSince(start))
  }

  static func logToStderr(_ message: String) {
    let line = "[LinkDigestNativeHost] \(message)\n"
    if let data = line.data(using: .utf8) {
      try? FileHandle.standardError.write(contentsOf: data)
    }
  }
}
