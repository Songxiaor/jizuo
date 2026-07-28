import Foundation
import LinkDigestCore

/// 没跑完的运行要主动说出来。
///
/// 成功有横幅（「翻译已完成」），失败和中断却什么都不显示——状态只落在详情里
/// 一个被动的元数据字段上。于是关掉 App 时被打断的那次翻译，表现是「点了翻译，
/// 什么也没发生」，用户既不知道它断过，也没有地方重试。
///
/// 这是今天修的那一批「静默失败」里的同一类：不报错、不崩溃，只是让人以为
/// 功能坏了。
enum UnfinishedRunNotice {
  struct Notice: Equatable {
    let kind: RunKind
    let status: RunStatus
    let message: String
  }

  /// 只有「同类运行之后再没成功过」才提示。
  ///
  /// 断过一次然后重跑成功是常态，那种不该再打扰；而按 kind 分别判断是因为
  /// 翻译断了不代表总结也断了，两者互不遮蔽。
  static func latest(in runs: [HistoryDetailProjection.RunDetail]) -> Notice? {
    let ordered = runs.sorted { lhs, rhs in
      (lhs.run.createdAtMilliseconds, lhs.run.id.rawValue)
        < (rhs.run.createdAtMilliseconds, rhs.run.id.rawValue)
    }
    var pending: [RunKind: Notice] = [:]
    for projection in ordered {
      let run = projection.run
      switch run.status {
      case .completed:
        pending[run.kind] = nil
      case .failed, .interrupted:
        pending[run.kind] = Notice(kind: run.kind, status: run.status, message: message(for: run))
      case .queued, .running, .stopped:
        // 进行中另有转圈提示；用户主动停止的不算故障，不提示。
        pending[run.kind] = nil
      }
    }
    // 同时有多类未完成时只提示最近那一次，避免叠一排横幅。
    return ordered.reversed().compactMap { pending[$0.run.kind] }.first
  }

  private static func message(for run: HistoryRun) -> String {
    let name = label(for: run.kind)
    switch run.status {
    case .interrupted:
      // APP_INTERRUPTED 是「App 退出时被打断」，不是模型或网络出错——
      // 说清这一点，用户才知道重试大概率会成功。
      return "上次\(name)在 App 退出时中断，没有结果。"
    default:
      return "上次\(name)没有完成。"
    }
  }

  static func label(for kind: RunKind) -> String {
    switch kind {
    case .summarize: "总结"
    case .translate: "翻译"
    }
  }
}
