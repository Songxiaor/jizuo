import Foundation
import Observation

/// 口述转写控制器：状态机 + 可注入引擎；无真实麦克风路径可单测。
@MainActor
@Observable
public final class VoiceDictationController {
  public private(set) var state = VoiceDictationState()

  public var phase: VoiceDictationPhase { state.phase }
  public var displayTranscript: String { state.displayTranscript }
  public var errorMessage: String? { state.errorMessage }
  public var canSave: Bool {
    !transcriptForSave().isEmpty
  }
  public var isRecording: Bool { state.isRecording }

  /// 界面可编辑文本；录音过程中跟随引擎，停止后允许手工改。
  public var editableTranscript: String = ""

  private let engine: any VoiceSpeechEngining
  private let localeIdentifier: String
  private var prepared = false

  public init(
    engine: any VoiceSpeechEngining = AppleVoiceSpeechEngine(),
    localeIdentifier: String = AppleVoiceSpeechEngine.defaultLocaleIdentifier
  ) {
    self.engine = engine
    self.localeIdentifier = localeIdentifier
  }

  public func prepareIfNeeded() async {
    guard !prepared, state.phase != .denied else { return }
    apply(.prepareStarted)
    let status = await engine.requestPermissions()
    switch status {
    case .granted:
      prepared = true
      apply(.permissionGranted)
    case .denied(let message), .restricted(let message):
      apply(.permissionDenied(message: message))
    }
  }

  /// 点击切换：未录音则开始，录音中则停止。
  public func toggleRecording() async {
    if state.phase == .recording {
      await stopRecording()
    } else {
      await startRecording()
    }
  }

  public func startRecording() async {
    if state.phase == .denied { return }
    if !prepared {
      await prepareIfNeeded()
      if state.phase == .denied { return }
    }
    guard state.phase == .ready || state.phase == .idle || state.phase == .failed else { return }

    apply(.startRecording)
    do {
      try await engine.startRecognition(
        localeIdentifier: localeIdentifier,
        onPartial: { [weak self] text in
          Task { @MainActor in
            self?.handlePartial(text)
          }
        },
        onFinal: { [weak self] text in
          Task { @MainActor in
            self?.handleFinal(text)
          }
        },
        onError: { [weak self] message in
          Task { @MainActor in
            self?.apply(.engineFailed(message: "转写失败：\(message)"))
          }
        }
      )
    } catch {
      apply(.engineFailed(message: error.localizedDescription))
      await engine.stopRecognition()
    }
  }

  public func stopRecording() async {
    guard state.phase == .recording else { return }
    apply(.stopRecording)
    await engine.stopRecognition()
    apply(.recordingEnded)
    editableTranscript = state.displayTranscript
  }

  public func transcriptForSave() -> String {
    editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func clearError() {
    apply(.clearError)
  }

  /// 测试用：直接喂事件，不碰引擎。
  public func applyForTesting(_ event: VoiceDictationEvent) {
    apply(event)
  }

  private func handlePartial(_ text: String) {
    apply(.partial(text))
    editableTranscript = state.displayTranscript
  }

  private func handleFinal(_ text: String) {
    apply(.finalSegment(text))
    editableTranscript = state.displayTranscript
  }

  private func apply(_ event: VoiceDictationEvent) {
    state = VoiceDictationStateMachine.reduce(state, event: event)
  }
}
