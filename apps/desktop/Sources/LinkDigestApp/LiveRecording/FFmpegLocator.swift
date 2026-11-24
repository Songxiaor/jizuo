import Foundation

enum FFmpegLocatorError: Error, Equatable {
  case notFound

  var userMessage: String {
    switch self {
    case .notFound:
      return "找不到录制组件（ffmpeg）。请更新或重装汲作；也可以在本机执行 brew install ffmpeg 后重试。"
    }
  }
}

/// ffmpeg 的查找顺序：App 包内 → Apple 芯片 Homebrew → Intel Homebrew。
///
/// 内置 ffmpeg 已获批，但打包与许可证核对放到发版前；这期只把顺序固定下来，
/// 包里没有时会落到本机安装的那份。查找本身不执行任何东西，也不改环境变量。
///
/// TODO(发版): 打包必须同时带上 ffprobe，和 ffmpeg 放在同一个目录。
/// 现在只带 ffmpeg 时，合并前的编码探测会全部返回 nil，断线前后编码不同的分段
/// 会被并成一组，合并大概率失败；面板会提示这个风险，但发版不能只靠提示。
enum FFmpegLocator {
  static func candidateURLs(
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    executableURL: URL? = Bundle.main.executableURL
  ) -> [URL] {
    var candidates: [URL] = []
    if let bundleResourceURL {
      candidates.append(bundleResourceURL.appendingPathComponent("ffmpeg", isDirectory: false))
    }
    // 某些打包方式把资源放在可执行文件旁边的 Resources/ 里，和 schema 查找同一种情况。
    if let executableURL {
      candidates.append(
        executableURL.deletingLastPathComponent()
          .appendingPathComponent("Resources", isDirectory: true)
          .appendingPathComponent("ffmpeg", isDirectory: false)
      )
    }
    candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
    candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
    return candidates
  }

  static func locate(
    candidates: [URL] = candidateURLs(),
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    candidates.first(where: isExecutable)
  }

  static func requireExecutable() throws -> URL {
    guard let url = locate() else { throw FFmpegLocatorError.notFound }
    return url
  }

  /// 编码探测用的 ffprobe。只找 ffmpeg 旁边的同名可执行文件；找不到就返回 nil。
  static func probeURL(
    near ffmpegURL: URL,
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) -> URL? {
    let probe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
    return isExecutable(probe) ? probe : nil
  }
}
