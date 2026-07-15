import Foundation
import LinkDigestCore
import LinkDigestTransport

let socketPath = ProcessInfo.processInfo.environment["LINKDIGEST_SOCKET_PATH"] ?? "/tmp/linkdigest-\(getuid()).sock"
let hostTimeout = Double(ProcessInfo.processInfo.environment["LINKDIGEST_TIMEOUT_SECONDS"] ?? "") ?? 10
func errorResponse(_ code: String, requestId: String = "native-host") -> NativeResponse {
  let appUnavailable = code == "APP_UNAVAILABLE"
  let networkFailure = appUnavailable || code == "NATIVE_MESSAGE_TIMEOUT" || code == "NATIVE_MESSAGE_FAILED"
  return .error(AppError(version: 1, requestId: requestId, createdAt: ISO8601DateFormatter().string(from: Date()), category: networkFailure ? "network" : "protocol", code: code, retryable: networkFailure, action: appUnavailable ? "open_app" : "retry", safeDetail: nil))
}

func transportErrorCode(_ error: Error) -> String {
  if case FramingError.timeout = error { return "NATIVE_MESSAGE_TIMEOUT" }
  guard let error = error as? POSIXError else { return "APP_UNAVAILABLE" }
  return error.code == .EAGAIN || error.code == .ETIMEDOUT ? "NATIVE_MESSAGE_TIMEOUT" : "APP_UNAVAILABLE"
}

func framingErrorCode(_ error: Error) -> String {
  guard let error = error as? FramingError else { return "CAPTURE_SCHEMA_INVALID" }
  switch error {
  case .tooLarge: return "CAPTURE_PAYLOAD_TOO_LARGE"
  case .timeout: return "NATIVE_MESSAGE_TIMEOUT"
  default: return "CAPTURE_SCHEMA_INVALID"
  }
}

do {
  let body = try ChromiumFramer.readFrame(from: .standardInput, timeout: hostTimeout)
  let envelope: CaptureEnvelopeV1
  do { envelope = try CaptureValidator.decode(body) } catch let issue as CaptureValidationError { try ChromiumFramer.writeFrame(try JSONEncoder().encode(errorResponse(issue.rawValue)), to: .standardOutput); exit(0) }
  let result: NativeResponse
  do { let response = try UnixSocketClient.send(body, path: socketPath, timeout: hostTimeout); result = (try? JSONDecoder().decode(NativeResponse.self, from: response)) ?? errorResponse("NATIVE_RESPONSE_INVALID", requestId: envelope.requestId) } catch { result = errorResponse(transportErrorCode(error), requestId: envelope.requestId) }
  try ChromiumFramer.writeFrame(try JSONEncoder().encode(result), to: .standardOutput)
} catch {
  try? ChromiumFramer.writeFrame(try JSONEncoder().encode(errorResponse(framingErrorCode(error))), to: .standardOutput)
}
