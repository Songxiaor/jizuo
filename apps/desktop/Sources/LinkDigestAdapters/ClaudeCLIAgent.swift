import Foundation
import LinkDigestCore

/// 起 `claude` 子进程,把它的事件流转成 App 能用的东西。
///
/// 为什么是「起 CLI」而不是「调 API」:Claude 订阅不是 API,没有可以填进
/// baseURL 的端点。官方 CLI 是唯一不碰凭据、不违反条款的接法——用户装自己的
/// CLI、登自己的账号,App 只负责启动进程和读输出,从不接触凭据。
public actor ClaudeCLIAgent {
  public enum Failure: Error, Sendable, Equatable {
    /// 没装,或者不在 PATH 里。
    case notInstalled
    /// 装了但没登录。
    case notLoggedIn
    /// 跑起来了但失败了。
    case failed(String)
    /// 撞上订阅额度。单独一类,因为它不是「程序坏了」。
    case rateLimited(resetsAt: Date?)
    case cancelled
  }

  /// 一次运行过程中吐给调用方的东西。
  public enum Progress: Sendable, Equatable {
    case started
    /// 正在产出的文字。可以直接往界面上刷。
    case text(String)
    case rateLimitWarning(kind: String, resetsAt: Date?)
  }

  private let executableName: String
  private var activeProcess: Process?

  public init(executableName: String = "claude") {
    self.executableName = executableName
  }

  /// 找到 CLI 的绝对路径。
  ///
  /// 必须用绝对路径起进程:App 从 Finder 启动时拿到的 PATH 和终端里的
  /// 完全不同(没有 /opt/homebrew/bin、没有 ~/.local/bin),直接 exec "claude"
  /// 在终端里能跑、双击打开就找不到——而后者才是用户的实际用法。
  public func locateExecutable() -> URL? {
    let candidates = [
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
      NSHomeDirectory() + "/.local/bin",
      NSHomeDirectory() + "/.claude/local",
    ]
    for directory in candidates {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
      if FileManager.default.isExecutableFile(atPath: path.path) { return path }
    }
    // 兜底问一次登录 shell——用户可能装在别处。
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/bin/zsh")
    which.arguments = ["-lc", "command -v \(executableName)"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    which.waitUntilExit()
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else { return nil }
    return URL(fileURLWithPath: output)
  }

  public func isAvailable() -> Bool { locateExecutable() != nil }

  /// 跑一次任务。
  ///
  /// `onProgress` 在流式产出时被调用,最终正文由返回值给出。
  public func run(
    _ request: ClaudeCLIRequest,
    onProgress: @Sendable @escaping (Progress) -> Void
  ) async throws -> String {
    guard let executable = locateExecutable() else { throw Failure.notInstalled }
    try FileManager.default.createDirectory(
      at: request.workingDirectory, withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = executable
    process.arguments = request.arguments
    process.currentDirectoryURL = request.workingDirectory
    // 继承一份最小环境:CLI 要靠 HOME 找到凭据与配置。
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_CODE_ENTRYPOINT"] = "jizuo-workbench"
    process.environment = environment

    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice

    activeProcess = process
    defer { activeProcess = nil }

    do { try process.run() } catch { throw Failure.notInstalled }

    var finalText = ""
    var rateLimitHit: Date?
    var sawResult = false

    // 逐行读:事件流是 JSONL,一行一个事件,不能等进程结束再整体解析——
    // 那样界面上就没有「正在写」这回事了。
    for try await line in output.fileHandleForReading.bytes.lines {
      switch ClaudeCLIEvent.parse(line: line) {
      case .started:
        onProgress(.started)
      case let .text(chunk):
        onProgress(.text(chunk))
      case let .rateLimit(status, kind, resetsAt):
        if status != "allowed" {
          rateLimitHit = resetsAt
          onProgress(.rateLimitWarning(kind: kind, resetsAt: resetsAt))
        }
      case let .finished(text, isError, _, _):
        sawResult = true
        finalText = text
        if isError { throw Failure.failed(text.isEmpty ? "生成失败" : text) }
      case .ignored:
        continue
      }
    }

    process.waitUntilExit()

    if let rateLimitHit, finalText.isEmpty { throw Failure.rateLimited(resetsAt: rateLimitHit) }
    guard process.terminationStatus == 0, sawResult else {
      let stderr = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      // 没登录时 CLI 会在 stderr 里说,这条要单独认出来:
      // 「去登录」和「出错了重试」是两件完全不同的事。
      if stderr.localizedCaseInsensitiveContains("login")
        || stderr.localizedCaseInsensitiveContains("authenticate") {
        throw Failure.notLoggedIn
      }
      throw Failure.failed(stderr.isEmpty ? "生成没有产出结果" : String(stderr.prefix(400)))
    }
    return finalText
  }

  /// 用户点了停。
  public func cancel() {
    activeProcess?.terminate()
    activeProcess = nil
  }
}
