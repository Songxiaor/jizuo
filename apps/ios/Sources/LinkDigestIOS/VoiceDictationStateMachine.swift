import Foundation

/// 口述转写 UI / 控制器共用的阶段（可单测，不依赖麦克风）。
public enum VoiceDictationPhase: Equatable, Sendable {
  case idle
  case requestingPermission
  case ready
  case recording
  case stopping
  case denied
  case failed
}

/// 纯事件驱动输入，便于 Fake 引擎与单测驱动状态机。
public enum VoiceDictationEvent: Equatable, Sendable {
  case prepareStarted
  case permissionGranted
  case permissionDenied(message: String)
  case startRecording
  case stopRecording
  case partial(String)
  case finalSegment(String)
  /// 引擎已完全停止（无更多结果）；从 stopping → ready。
  case recordingEnded
  case engineFailed(message: String)
  case clearError
  case reset
}

public struct VoiceDictationState: Equatable, Sendable {
  public var phase: VoiceDictationPhase
  /// 已确认（isFinal）段落。
  public var committedTranscript: String
  /// 当前未定稿（volatile）片段。
  public var volatileTranscript: String
  public var errorMessage: String?

  public init(
    phase: VoiceDictationPhase = .idle,
    committedTranscript: String = "",
    volatileTranscript: String = "",
    errorMessage: String? = nil
  ) {
    self.phase = phase
    self.committedTranscript = committedTranscript
    self.volatileTranscript = volatileTranscript
    self.errorMessage = errorMessage
  }

  /// 界面展示：已确认 + 当前 partial。
  public var displayTranscript: String {
    let committed = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let volatile = volatileTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if committed.isEmpty { return volatile }
    if volatile.isEmpty { return committed }
    return committed + volatile
  }

  public var canSave: Bool {
    !displayTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var isRecording: Bool {
    phase == .recording || phase == .stopping
  }
}

/// 无副作用归约：权限、录音、转写与错误文案。
public enum VoiceDictationStateMachine {
  public static func reduce(
    _ state: VoiceDictationState,
    event: VoiceDictationEvent
  ) -> VoiceDictationState {
    var next = state
    switch event {
    case .prepareStarted:
      next.phase = .requestingPermission
      next.errorMessage = nil

    case .permissionGranted:
      next.phase = .ready
      next.errorMessage = nil

    case .permissionDenied(let message):
      next.phase = .denied
      next.errorMessage = message

    case .startRecording:
      guard next.phase == .ready || next.phase == .idle || next.phase == .failed else { break }
      // idle 未先 prepare 时也允许尝试启动（控制器会先要权限）。
      if next.phase == .denied { break }
      next.phase = .recording
      next.volatileTranscript = ""
      next.errorMessage = nil

    case .stopRecording:
      guard next.phase == .recording else { break }
      next.phase = .stopping

    case .partial(let text):
      guard next.phase == .recording || next.phase == .stopping else { break }
      next.volatileTranscript = text

    case .finalSegment(let text):
      guard next.phase == .recording || next.phase == .stopping else { break }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        if next.committedTranscript.isEmpty {
          next.committedTranscript = trimmed
        } else {
          let needsSpace = !next.committedTranscript.hasSuffix("\n")
            && !trimmed.hasPrefix("，")
            && !trimmed.hasPrefix("。")
            && !trimmed.hasPrefix("、")
            && !trimmed.hasPrefix("！")
            && !trimmed.hasPrefix("？")
          next.committedTranscript += needsSpace ? " \(trimmed)" : trimmed
        }
      }
      next.volatileTranscript = ""

    case .recordingEnded:
      if next.phase == .stopping || next.phase == .recording {
        next.phase = .ready
      }
      next.volatileTranscript = ""

    case .engineFailed(let message):
      next.phase = .failed
      next.volatileTranscript = ""
      next.errorMessage = message

    case .clearError:
      next.errorMessage = nil
      if next.phase == .failed {
        next.phase = .ready
      }

    case .reset:
      next = VoiceDictationState()
    }
    return next
  }
}
