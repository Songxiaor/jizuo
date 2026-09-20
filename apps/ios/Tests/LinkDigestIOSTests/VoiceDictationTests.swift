import Foundation
import LinkDigestIOS
import XCTest

final class VoiceDictationStateMachineTests: XCTestCase {
  func testPermissionDeniedStoresReadableMessage() {
    var state = VoiceDictationState()
    state = VoiceDictationStateMachine.reduce(state, event: .prepareStarted)
    XCTAssertEqual(state.phase, .requestingPermission)

    state = VoiceDictationStateMachine.reduce(
      state,
      event: .permissionDenied(message: "未授权麦克风。")
    )
    XCTAssertEqual(state.phase, .denied)
    XCTAssertEqual(state.errorMessage, "未授权麦克风。")
  }

  func testRecordingPartialsAndFinalsComposeDisplayText() {
    var state = VoiceDictationStateMachine.reduce(VoiceDictationState(), event: .permissionGranted)
    state = VoiceDictationStateMachine.reduce(state, event: .startRecording)
    XCTAssertEqual(state.phase, .recording)

    state = VoiceDictationStateMachine.reduce(state, event: .partial("你好"))
    XCTAssertEqual(state.displayTranscript, "你好")

    state = VoiceDictationStateMachine.reduce(state, event: .finalSegment("你好世界"))
    XCTAssertEqual(state.committedTranscript, "你好世界")
    XCTAssertEqual(state.volatileTranscript, "")

    state = VoiceDictationStateMachine.reduce(state, event: .partial("继续"))
    XCTAssertEqual(state.displayTranscript, "你好世界继续")

    state = VoiceDictationStateMachine.reduce(state, event: .stopRecording)
    XCTAssertEqual(state.phase, .stopping)
    state = VoiceDictationStateMachine.reduce(state, event: .recordingEnded)
    XCTAssertEqual(state.phase, .ready)
  }

  func testDeniedBlocksStartRecording() {
    var state = VoiceDictationStateMachine.reduce(
      VoiceDictationState(),
      event: .permissionDenied(message: "拒绝")
    )
    state = VoiceDictationStateMachine.reduce(state, event: .startRecording)
    XCTAssertEqual(state.phase, .denied)
    XCTAssertFalse(state.isRecording)
  }

  func testEngineFailedSurfacesMessage() {
    var state = VoiceDictationStateMachine.reduce(VoiceDictationState(), event: .permissionGranted)
    state = VoiceDictationStateMachine.reduce(state, event: .startRecording)
    state = VoiceDictationStateMachine.reduce(
      state,
      event: .engineFailed(message: "转写失败：网络中断")
    )
    XCTAssertEqual(state.phase, .failed)
    XCTAssertEqual(state.errorMessage, "转写失败：网络中断")
  }
}

@MainActor
final class VoiceDictationControllerFakeEngineTests: XCTestCase {
  func testControllerWithFakeEngineWithoutMicrophone() async {
    let engine = FakeVoiceSpeechEngine()
    let controller = VoiceDictationController(engine: engine)

    await controller.prepareIfNeeded()
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertEqual(engine.permissionCalls, 1)

    await controller.startRecording()
    XCTAssertEqual(controller.phase, .recording)
    XCTAssertEqual(engine.startCalls, 1)

    engine.emitPartial("实时")
    await waitForMainActor()
    XCTAssertEqual(controller.displayTranscript, "实时")
    XCTAssertEqual(controller.editableTranscript, "实时")

    engine.emitFinal("实时最终稿")
    await waitForMainActor()
    XCTAssertEqual(controller.state.committedTranscript, "实时最终稿")

    await controller.stopRecording()
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertEqual(engine.stopCalls, 1)
    XCTAssertTrue(controller.canSave)
    XCTAssertEqual(controller.transcriptForSave(), "实时最终稿")
  }

  func testControllerSurfacesPermissionDenial() async {
    let engine = FakeVoiceSpeechEngine(
      permission: .denied(message: "未授权麦克风。请到「设置 → 汲作」打开麦克风权限后再口述。")
    )
    let controller = VoiceDictationController(engine: engine)
    await controller.prepareIfNeeded()
    XCTAssertEqual(controller.phase, .denied)
    XCTAssertEqual(
      controller.errorMessage,
      "未授权麦克风。请到「设置 → 汲作」打开麦克风权限后再口述。"
    )
    await controller.startRecording()
    XCTAssertEqual(engine.startCalls, 0)
    XCTAssertFalse(controller.canSave)
  }

  private func waitForMainActor() async {
    await Task.yield()
    await Task.yield()
  }
}

private final class FakeVoiceSpeechEngine: VoiceSpeechEngining, @unchecked Sendable {
  var permission: VoicePermissionStatus
  private(set) var permissionCalls = 0
  private(set) var startCalls = 0
  private(set) var stopCalls = 0

  private var onPartial: (@Sendable (String) -> Void)?
  private var onFinal: (@Sendable (String) -> Void)?
  private var onError: (@Sendable (String) -> Void)?

  init(permission: VoicePermissionStatus = .granted) {
    self.permission = permission
  }

  func requestPermissions() async -> VoicePermissionStatus {
    permissionCalls += 1
    return permission
  }

  func startRecognition(
    localeIdentifier: String,
    onPartial: @escaping @Sendable (String) -> Void,
    onFinal: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    startCalls += 1
    self.onPartial = onPartial
    self.onFinal = onFinal
    self.onError = onError
  }

  func stopRecognition() async {
    stopCalls += 1
  }

  func emitPartial(_ text: String) {
    onPartial?(text)
  }

  func emitFinal(_ text: String) {
    onFinal?(text)
  }

  func emitError(_ message: String) {
    onError?(message)
  }
}
