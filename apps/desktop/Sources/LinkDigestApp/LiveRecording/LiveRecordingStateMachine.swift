import Foundation

enum LiveRecordingPhase: Equatable {
  case preparing
  case recording
  case reconnecting(attempt: Int)
  case merging
  case completed
  case failed(String)
}

enum LiveRecordingStopReason: Equatable {
  /// 用户点了停止。
  case userStopped
  /// 页面还能打开，但没有可拉的流：判断为已下播。
  case streamEnded
  /// 连续刷新失败，放弃续录；已录部分仍然合并保留。
  case gaveUp
  /// 直播平台要求人机验证；自动续录无法继续。
  case verificationRequired
  /// 磁盘剩余空间低于 1 GB，自动停止并收尾。
  case diskSpaceLow

  var displayText: String {
    switch self {
    case .userStopped: return "已手动停止"
    case .streamEnded: return "直播已结束"
    case .gaveUp: return "直播流多次中断，已停止续录"
    case .verificationRequired: return "直播平台要求验证，已停止续录"
    case .diskSpaceLow: return "磁盘空间不足，已自动停止并合并"
    }
  }
}

enum LiveRecordingEvent: Equatable {
  case begin
  case segmentStarted
  case segmentExited(status: Int32)
  /// 重新取地址成功，直播还在。
  case streamRefreshFoundLive
  /// 页面能打开，但读不到流：下播。
  case streamRefreshEnded
  /// 网络或解析失败，可以再试。
  case streamRefreshFailed
  /// ffmpeg 连续几次都写不出内容（地址失效、编码不兼容等），停止再试。
  case recordingKeptFailing
  /// 重新取地址时撞上人机验证。
  case verificationRequired
  /// 录制中磁盘剩余空间低于 1 GB。
  case diskSpaceLow
  case userRequestedStop
  case mergeSucceeded
  case mergeFailed
}

enum LiveRecordingAction: Equatable {
  case startSegment
  case reconnect(after: TimeInterval)
  case merge(LiveRecordingStopReason)
  case completed
  case failed
  case none
}

struct LiveRecordingPolicy: Equatable {
  var maxConsecutiveFailures = 5
  var retryDelays: [TimeInterval] = [2, 4, 8, 15, 30]

  func delay(forFailure count: Int) -> TimeInterval {
    guard !retryDelays.isEmpty else { return 2 }
    let index = min(max(count - 1, 0), retryDelays.count - 1)
    return retryDelays[index]
  }
}

/// 续录状态机。它不碰进程和网络，只回答「下一步做什么」，测试可以直接推事件。
struct LiveRecordingStateMachine: Equatable {
  private(set) var phase: LiveRecordingPhase = .preparing
  private(set) var segmentCount = 0
  private(set) var consecutiveFailures = 0
  private(set) var stopReason: LiveRecordingStopReason?
  let policy: LiveRecordingPolicy

  init(policy: LiveRecordingPolicy = LiveRecordingPolicy()) {
    self.policy = policy
  }

  var hasSegments: Bool { segmentCount > 0 }

  mutating func handle(_ event: LiveRecordingEvent) -> LiveRecordingAction {
    switch event {
    case .begin:
      phase = .preparing
      return .startSegment

    case .segmentStarted:
      segmentCount += 1
      consecutiveFailures = 0
      phase = .recording
      return .none

    case .segmentExited:
      if let reason = stopReason {
        return finish(reason)
      }
      phase = .reconnecting(attempt: consecutiveFailures + 1)
      return .reconnect(after: 0.5)

    case .streamRefreshFoundLive:
      consecutiveFailures = 0
      phase = .preparing
      return .startSegment

    case .streamRefreshEnded:
      stopReason = .streamEnded
      return finish(.streamEnded)

    case .streamRefreshFailed:
      consecutiveFailures += 1
      if consecutiveFailures >= policy.maxConsecutiveFailures {
        stopReason = .gaveUp
        return finish(.gaveUp)
      }
      phase = .reconnecting(attempt: consecutiveFailures)
      return .reconnect(after: policy.delay(forFailure: consecutiveFailures))

    case .recordingKeptFailing:
      stopReason = .gaveUp
      return finish(.gaveUp)

    case .verificationRequired:
      stopReason = .verificationRequired
      return finish(.verificationRequired)

    case .diskSpaceLow:
      stopReason = .diskSpaceLow
      return finish(.diskSpaceLow)

    case .userRequestedStop:
      stopReason = .userStopped
      switch phase {
      case .recording:
        // 先让控制器停掉 ffmpeg，进程退出后再走合并。
        return .none
      case .merging, .completed, .failed:
        return .none
      case .preparing, .reconnecting:
        return finish(.userStopped)
      }

    case .mergeSucceeded:
      phase = .completed
      return .completed

    case .mergeFailed:
      phase = .failed("分段合并失败；分段文件仍保留在录制目录的 .parts 里。")
      return .failed
    }
  }

  private mutating func finish(_ reason: LiveRecordingStopReason) -> LiveRecordingAction {
    guard hasSegments else {
      phase = .completed
      return .completed
    }
    phase = .merging
    return .merge(reason)
  }
}
