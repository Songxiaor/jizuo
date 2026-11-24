import Foundation

/// 录制存放位置。默认在汲作资料目录下的「直播录制」；用户可以在录制面板里改到
/// 外接硬盘。只存路径，不复制文件——录制体积大，复制一次等于多占一份。
@MainActor
final class LiveRecordingPreferences: ObservableObject {
  static let directoryPathKey = "linkdigest.liveRecording.directoryPath"

  private let defaults: UserDefaults
  private let applicationSupportRoot: URL

  @Published private(set) var customDirectoryPath: String?

  init(defaults: UserDefaults = .standard, applicationSupportRoot: URL) {
    self.defaults = defaults
    self.applicationSupportRoot = applicationSupportRoot
    customDirectoryPath = defaults.string(forKey: Self.directoryPathKey)
  }

  var defaultDirectory: URL {
    LiveRecordingNaming.defaultDirectory(applicationSupportRoot: applicationSupportRoot)
  }

  var recordingDirectory: URL {
    Self.liveRecordingDirectory(
      defaultDirectory: defaultDirectory,
      customPath: customDirectoryPath
    )
  }

  var displayPath: String {
    recordingDirectory.path.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path,
      with: "~"
    )
  }

  func setDirectory(_ url: URL?) {
    let normalized = url?.standardizedFileURL.path
    if normalized == defaultDirectory.standardizedFileURL.path {
      defaults.removeObject(forKey: Self.directoryPathKey)
      customDirectoryPath = nil
    } else {
      defaults.set(normalized, forKey: Self.directoryPathKey)
      customDirectoryPath = normalized
    }
  }

  static func liveRecordingDirectory(defaultDirectory: URL, customPath: String?) -> URL {
    guard let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return defaultDirectory.standardizedFileURL
    }
    return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
  }

  /// 目录在第一次录制时才建，设置页只显示路径，不留下空文件夹。
  func ensureRecordingDirectory() throws -> URL {
    let directory = recordingDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
