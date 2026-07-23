import Foundation

/// Resolves the co-located desktop app for the Chromium native-messaging host.
/// The host must only ever open this peer bundle — never an arbitrary path from the page.
public enum AppBundleLocator: Sendable {
  /// Walks up from the host executable (…/LinkDigest.app/Contents/Resources/NativeHost/…/LinkDigestNativeHost).
  public static func resolveAppBundle(fromNativeHostExecutable hostExecutable: URL) -> URL? {
    var current = hostExecutable.resolvingSymlinksInPath().standardizedFileURL
    if !current.hasDirectoryPath {
      current = current.deletingLastPathComponent()
    }
    for _ in 0..<12 {
      if current.pathExtension == "app" {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return nil
  }

  /// Optional override for tests / packaging drills (`LINKDIGEST_APP_BUNDLE_PATH`).
  public static func resolveAppBundle(
    fromNativeHostExecutable hostExecutable: URL,
    environment: [String: String]
  ) -> URL? {
    if let raw = environment["LINKDIGEST_APP_BUNDLE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !raw.isEmpty {
      let url = URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
      if url.pathExtension == "app" { return url }
      return nil
    }
    return resolveAppBundle(fromNativeHostExecutable: hostExecutable)
  }
}
