import Foundation
import LinkDigestCore
import LinkDigestTransport

/// Default includes cold-start budget: open App + bootstrap socket + one capture write.
let socketPath = ProcessInfo.processInfo.environment["LINKDIGEST_SOCKET_PATH"]
  ?? "/tmp/linkdigest-\(getuid()).sock"
let hostTimeout = Double(ProcessInfo.processInfo.environment["LINKDIGEST_TIMEOUT_SECONDS"] ?? "") ?? 25

func errorResponse(_ code: String, requestId: String = "native-host") -> NativeResponse {
  let appUnavailable = code == "APP_UNAVAILABLE"
  let networkFailure = appUnavailable || code == "NATIVE_MESSAGE_TIMEOUT" || code == "NATIVE_MESSAGE_FAILED"
  return .error(
    AppError(
      version: 1,
      requestId: requestId,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      category: networkFailure ? "network" : "protocol",
      code: code,
      retryable: networkFailure,
      action: appUnavailable ? "open_app" : "retry",
      safeDetail: nil
    )
  )
}

func transportErrorCode(_ error: Error) -> String {
  if case FramingError.timeout = error { return "NATIVE_MESSAGE_TIMEOUT" }
  // Swift may surface POSIX failures as NSError in the POSIX domain.
  let ns = error as NSError
  if ns.domain == NSPOSIXErrorDomain {
    let code = POSIXErrorCode(rawValue: Int32(ns.code))
    if code == .EAGAIN || code == .ETIMEDOUT || code == .EWOULDBLOCK {
      return "NATIVE_MESSAGE_TIMEOUT"
    }
    return "APP_UNAVAILABLE"
  }
  if let posix = error as? POSIXError {
    return posix.code == .EAGAIN || posix.code == .ETIMEDOUT ? "NATIVE_MESSAGE_TIMEOUT" : "APP_UNAVAILABLE"
  }
  return "APP_UNAVAILABLE"
}

func isOfflineTransport(_ error: Error) -> Bool {
  transportErrorCode(error) == "APP_UNAVAILABLE"
}

func framingErrorCode(_ error: Error) -> String {
  guard let error = error as? FramingError else { return "CAPTURE_SCHEMA_INVALID" }
  switch error {
  case .tooLarge: return "CAPTURE_PAYLOAD_TOO_LARGE"
  case .timeout: return "NATIVE_MESSAGE_TIMEOUT"
  default: return "CAPTURE_SCHEMA_INVALID"
  }
}

func hostExecutableURL() -> URL {
  if let path = CommandLine.arguments.first, !path.isEmpty {
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
  }
  return URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    .resolvingSymlinksInPath()
    .standardizedFileURL
}

func decodeResponse(_ data: Data, requestId: String) -> NativeResponse {
  (try? JSONDecoder().decode(NativeResponse.self, from: data))
    ?? errorResponse("NATIVE_RESPONSE_INVALID", requestId: requestId)
}

/// 拉起这个 host 的浏览器。
///
/// native host 永远由浏览器 spawn，所以父进程就是浏览器。设置页需要知道「哪个浏览器
/// 真的在用」，而 App 自己看不进浏览器里（macOS 不许读别的 App 的数据目录），父进程
/// 是唯一不需要任何权限就能拿到的浏览器身份。
func callingBrowser() -> BrowserSupportBrowser? {
  var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
  let written = buffer.withUnsafeMutableBytes { proc_pidpath(getppid(), $0.baseAddress, UInt32($0.count)) }
  guard written > 0 else { return nil }
  let path = String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
  return BrowserSupportBrowser.identify(executablePath: path)
}

/// 只在内容真的进了 App 之后才记。记「试过」没有意义——这一行要陈述的是既成事实。
func recordDeliveryIfSucceeded(_ response: NativeResponse) {
  if case .error = response { return }
  guard let browser = callingBrowser() else { return }
  BrowserDeliveryLog.standard().record(browser)
}

/// Hot path: one send. Cold path: open co-located App, then retry send until budget ends.
/// No connect-only probes — they steal the App's accept queue.
func deliverToApp(_ body: Data, requestId: String) -> NativeResponse {
  let start = Date()
  let total = hostTimeout
  let log = AppColdStart.logToStderr

  func attemptSend() throws -> NativeResponse {
    // Keep each attempt short so we can re-try after the App finishes bootstrapping.
    let remaining = AppColdStart.remainingTimeout(since: start, total: total, floor: 0.5)
    let slice = min(3.0, remaining)
    let response = try UnixSocketClient.send(body, path: socketPath, timeout: max(0.5, slice))
    return decodeResponse(response, requestId: requestId)
  }

  // 1) Fast hot path
  do {
    return try attemptSend()
  } catch {
    guard isOfflineTransport(error) else {
      log("first send failed: \(transportErrorCode(error)) \(error.localizedDescription)")
      return errorResponse(transportErrorCode(error), requestId: requestId)
    }
    log("app offline (\(error.localizedDescription)); attempting cold start")
  }

  // 2) Cold start: open peer app once
  let launched = AppColdStart.launchPeerAppIfNeeded(
    hostExecutable: hostExecutableURL(),
    log: log
  )
  if !launched {
    log("cold start launch skipped or failed; host=\(hostExecutableURL().path)")
  }

  // 3) Retry send until the overall budget is exhausted
  var lastCode = "APP_UNAVAILABLE"
  while Date() < start.addingTimeInterval(total) {
    do {
      let result = try attemptSend()
      log("capture delivered after cold start in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
      return result
    } catch {
      lastCode = transportErrorCode(error)
      if !isOfflineTransport(error) && lastCode != "NATIVE_MESSAGE_TIMEOUT" {
        log("post-launch send failed non-offline: \(lastCode)")
        return errorResponse(lastCode, requestId: requestId)
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
  }

  log("gave up after \(String(format: "%.2f", Date().timeIntervalSince(start)))s last=\(lastCode)")
  return errorResponse(lastCode, requestId: requestId)
}

// 诊断写入默认关闭：host 会经手用户抓取的正文，不能默认往世界可读的 /tmp 落
// 任何东西。需要排查时设 LINKDIGEST_HOST_DEBUG=1，只写计数/状态码（不含正文）。
private let hostDebugEnabled = ProcessInfo.processInfo.environment["LINKDIGEST_HOST_DEBUG"] == "1"

private func writeDebugLog(_ line: String) {
  guard hostDebugEnabled else { return }
  let timestamped = "\(Date().ISO8601Format()) \(line)\n"
  let url = URL(fileURLWithPath: "/tmp/linkdigest-host-debug.log")
  if let data = timestamped.data(using: .utf8) {
    if FileManager.default.fileExists(atPath: url.path) {
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      }
    } else {
      try? data.write(to: url)
    }
  }
}

do {
  writeDebugLog("host_started")
  let body = try ChromiumFramer.readFrame(from: .standardInput, timeout: hostTimeout)
  writeDebugLog("frame_read_bytes=\(body.count)")
  // 抓取正文含推文/文章全文，绝不默认落盘。仅在显式开启调试时留一份，供排查。
  if hostDebugEnabled {
    try? body.write(to: URL(fileURLWithPath: "/tmp/linkdigest-last-envelope.json"))
  }

  // 收藏夹 / 时间线同步走独立消息：它带的是一串推文 id，不是页面捕获，所以
  // 不能过 capture envelope 的 schema。识别到就直接转发给 App，让它的
  // CaptureReceiver 路由到 bookmarksSink——否则会被下面的校验挡成 schema 错误。
  // decode 返回 nil 表示「不是这类消息」，继续走 capture 校验；抛错表示「是这类
  // 消息但不合法」，如实回错，不再当作页面捕获。
  do {
    if let bookmarks = try XBookmarksSyncRequest.decode(body) {
      writeDebugLog("bookmarks_sync ids=\(bookmarks.tweetIDs.count)")
      let result = deliverToApp(body, requestId: bookmarks.requestId)
      recordDeliveryIfSucceeded(result)
      try ChromiumFramer.writeFrame(try JSONEncoder().encode(result), to: .standardOutput)
      exit(0)
    }
  } catch let issue as CaptureValidationError {
    writeDebugLog("bookmarks_decode_failed=\(issue.rawValue)")
    try ChromiumFramer.writeFrame(
      try JSONEncoder().encode(errorResponse(issue.rawValue)),
      to: .standardOutput
    )
    exit(0)
  }

  let envelope: CaptureWireEnvelope
  do {
    envelope = try CaptureWireEnvelope.decode(body)
  } catch let issue as CaptureValidationError {
    writeDebugLog("decode_failed=\(issue.rawValue) bytes=\(body.count)")
    try ChromiumFramer.writeFrame(
      try JSONEncoder().encode(errorResponse(issue.rawValue)),
      to: .standardOutput
    )
    exit(0)
  } catch {
    writeDebugLog("decode_failed_generic bytes=\(body.count) error=\(error)")
    try ChromiumFramer.writeFrame(
      try JSONEncoder().encode(errorResponse("CAPTURE_SCHEMA_INVALID")),
      to: .standardOutput
    )
    exit(0)
  }
  writeDebugLog("decoded_ok chars=\(envelope.characterCount) bytes=\(body.count)")
  let result = deliverToApp(body, requestId: envelope.requestId)
  recordDeliveryIfSucceeded(result)
  try ChromiumFramer.writeFrame(try JSONEncoder().encode(result), to: .standardOutput)
} catch {
  writeDebugLog("framing_error=\(framingErrorCode(error))")
  try? ChromiumFramer.writeFrame(
    try JSONEncoder().encode(errorResponse(framingErrorCode(error))),
    to: .standardOutput
  )
}
