import Foundation

/// `claude -p --output-format stream-json` 吐出来的事件。
///
/// 只解析我们真正用到的那几种,其余一律归入 `.ignored` 而不是报错——
/// CLI 由用户自己更新,版本一变就可能多出新的事件类型。对未知事件宽容,
/// 是这条集成能活过下一次 CLI 升级的前提。
///
/// 事件形状来自 2026-08-02 对 claude 2.1.220 的实测。
public enum ClaudeCLIEvent: Sendable, Equatable {
  /// 会话开始。带回话 id 与本次实际可用的工具清单。
  case started(sessionID: String, toolCount: Int, permissionMode: String)
  /// 模型产出的一段文字。
  case text(String)
  /// 订阅额度状态。
  ///
  /// 这是实测里最意外的收获:限流**不是隐形的**,CLI 会主动告诉你。
  /// 所以「跑不动了」可以如实说成「这是订阅额度」,而不是让用户以为程序坏了。
  case rateLimit(status: String, kind: String, resetsAt: Date?)
  /// 跑完了。`text` 是最终正文。
  case finished(text: String, isError: Bool, durationMilliseconds: Int, costUSD: Double)
  /// 认不出的事件。宽容跳过,不作为失败。
  case ignored

  public static func parse(line: String) -> ClaudeCLIEvent {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .ignored }

    switch object["type"] as? String {
    case "system":
      // hook 事件是用户自己配的钩子在说话,和这次任务无关。
      // 实测里五个 SessionStart hook 产生了十条事件,不跳掉会淹没真正的进度。
      let subtype = object["subtype"] as? String ?? ""
      guard subtype == "init" else { return .ignored }
      return .started(
        sessionID: object["session_id"] as? String ?? "",
        toolCount: (object["tools"] as? [Any])?.count ?? 0,
        permissionMode: object["permissionMode"] as? String ?? ""
      )

    case "assistant":
      guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]] else { return .ignored }
      let text = content
        .filter { $0["type"] as? String == "text" }
        .compactMap { $0["text"] as? String }
        .joined()
      return text.isEmpty ? .ignored : .text(text)

    case "rate_limit_event":
      guard let info = object["rate_limit_info"] as? [String: Any] else { return .ignored }
      let resets = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
      return .rateLimit(
        status: info["status"] as? String ?? "",
        kind: info["rateLimitType"] as? String ?? "",
        resetsAt: resets
      )

    case "result":
      return .finished(
        text: object["result"] as? String ?? "",
        isError: object["is_error"] as? Bool ?? false,
        durationMilliseconds: object["duration_ms"] as? Int ?? 0,
        costUSD: object["total_cost_usd"] as? Double ?? 0
      )

    default:
      return .ignored
    }
  }
}

/// 起一次 `claude -p` 需要的参数。
public struct ClaudeCLIRequest: Sendable, Equatable {
  public let prompt: String
  /// 工作目录。
  ///
  /// 必须锁在一个专用目录里。即便下面禁掉了文件工具,进程的 cwd 仍然是它
  /// 能看到的世界——把它放在仓库或家目录下,等于给一个不需要文件的任务
  /// 开了一扇不需要的门。
  public let workingDirectory: URL
  /// 一次任务最多几轮。写作任务一轮就够,给上限是防止它自己绕进循环。
  public let maxTurns: Int

  public init(prompt: String, workingDirectory: URL, maxTurns: Int = 1) {
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.maxTurns = maxTurns
  }

  /// 明确禁掉的工具。
  ///
  /// 「把素材写成一篇稿子」不需要任何工具——素材随提示词一起给,产出是纯文本。
  /// 没有工具就没有权限确认,非交互模式下也就不会卡住。
  ///
  /// 用 `--disallowed-tools` 而不是 `--allowed-tools ""`:实测后者不生效,
  /// 工具数仍然是 33;前者能把危险工具清空(33 → 27,Bash/Edit/Write/Task 全没了)。
  public static let deniedTools = [
    "Bash", "Edit", "Write", "Read", "NotebookEdit",
    "Task", "WebFetch", "WebSearch", "Skill",
  ]

  public var arguments: [String] {
    [
      "-p", prompt,
      "--output-format", "stream-json",
      "--verbose",
      "--max-turns", String(maxTurns),
      "--disallowed-tools", Self.deniedTools.joined(separator: ","),
    ]
  }
}
