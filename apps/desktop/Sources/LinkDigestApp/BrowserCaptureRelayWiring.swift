import Foundation

/// 扩展 ↔ 代抓会话簿的三条接线。
///
/// 这三条原来直接写在 App 入口的闭包里。入口代码没有测试，漏传一个参数（例如
/// `allowsRelayTabFallback`）不会被任何测试发现：真机上只表现为「落地地址对不上、
/// 等到超时」。集中到这里以后，接收器的端到端测试可以直接复用同一条接线。
@MainActor
enum BrowserCaptureRelayWiring {
  static func jobSink(_ relay: BrowserCaptureRelay) -> CaptureReceiver.BrowserCaptureJobSink {
    { request in
      await MainActor.run {
        relay.claimJob(
          candidateURLs: request.urls,
          tabID: request.tabID,
          allowsRelayTabFallback: request.allowsRelayTabFallback
        )
      }
    }
  }

  static func deliverySink(_ relay: BrowserCaptureRelay) -> CaptureReceiver.BrowserCaptureDeliverySink {
    { jobID, wire in
      await MainActor.run { relay.deliver(jobID: jobID, envelope: wire) }
    }
  }

  static func outcomeSink(_ relay: BrowserCaptureRelay) -> CaptureReceiver.BrowserCaptureOutcomeSink {
    { outcome in
      await MainActor.run {
        relay.reportBlocked(
          jobID: outcome.jobID,
          reason: outcome.reason,
          finalURL: outcome.finalURL
        )
      }
    }
  }
}
