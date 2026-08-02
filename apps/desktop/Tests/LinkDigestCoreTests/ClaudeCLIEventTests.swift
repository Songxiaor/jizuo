import Foundation
import XCTest
@testable import LinkDigestCore

/// CLI 事件流的解析契约。
///
/// 这里的样本是 2026-08-02 对 claude 2.1.220 的**真实输出**,不是手写的假数据。
/// CLI 由用户自己更新,字段随时可能变——这组测试的作用是:升级之后如果我们
/// 依赖的那几个字段动了,在这里失败,而不是等用户点了「生成」才发现没反应。
final class ClaudeCLIEventTests: XCTestCase {
  func testParsesSessionInit() {
    let line = #"{"type":"system","subtype":"init","cwd":"/private/tmp","session_id":"37f943e9","tools":["Task","Bash","Read"],"model":"claude-opus-5","permissionMode":"auto"}"#
    guard case let .started(sessionID, toolCount, mode) = ClaudeCLIEvent.parse(line: line) else {
      return XCTFail("应解析为 started")
    }
    XCTAssertEqual(sessionID, "37f943e9")
    XCTAssertEqual(toolCount, 3)
    XCTAssertEqual(mode, "auto")
  }

  /// hook 事件必须跳过。
  ///
  /// 实测里用户配了五个 SessionStart hook,产生十条事件——不跳掉的话,
  /// 真正的进度会被淹没在一堆和任务无关的钩子日志里。
  func testSkipsHookNoise() {
    let started = #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup","session_id":"x"}"#
    let response = #"{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":0}"#
    XCTAssertEqual(ClaudeCLIEvent.parse(line: started), .ignored)
    XCTAssertEqual(ClaudeCLIEvent.parse(line: response), .ignored)
  }

  func testParsesAssistantText() {
    let line = #"{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"大多数人以为稀缺的是模型能力"}]},"session_id":"x"}"#
    XCTAssertEqual(ClaudeCLIEvent.parse(line: line), .text("大多数人以为稀缺的是模型能力"))
  }

  /// 限流不是隐形的——CLI 会主动报。
  ///
  /// 这条是实测最意外的收获:方案里原本把「订阅限流看不见」列为风险,
  /// 而实际上可以如实告诉用户「这是订阅额度,不是程序坏了」。
  func testParsesRateLimit() {
    let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1785651000,"rateLimitType":"five_hour","overageStatus":"rejected"}}"#
    guard case let .rateLimit(status, kind, resetsAt) = ClaudeCLIEvent.parse(line: line) else {
      return XCTFail("应解析为 rateLimit")
    }
    XCTAssertEqual(status, "allowed")
    XCTAssertEqual(kind, "five_hour")
    XCTAssertEqual(resetsAt?.timeIntervalSince1970, 1_785_651_000)
  }

  func testParsesFinalResult() {
    let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":6944,"total_cost_usd":0.1311,"result":"正文内容","session_id":"x"}"#
    guard case let .finished(text, isError, duration, cost) = ClaudeCLIEvent.parse(line: line) else {
      return XCTFail("应解析为 finished")
    }
    XCTAssertEqual(text, "正文内容")
    XCTAssertFalse(isError)
    XCTAssertEqual(duration, 6944)
    XCTAssertEqual(cost, 0.1311, accuracy: 0.0001)
  }

  /// 认不出的一律跳过,不能当成失败。
  ///
  /// CLI 升级会带来新事件类型。如果解析器对陌生输入抛错,那么每次 CLI
  /// 更新都可能让这个功能整体失灵——而它本可以继续工作。
  func testUnknownAndMalformedLinesAreToleratedNotFatal() {
    for line in [
      #"{"type":"some_future_event","payload":{}}"#,
      "不是 JSON",
      "",
      "   ",
      #"{"type":"assistant","message":{}}"#,
    ] {
      XCTAssertEqual(ClaudeCLIEvent.parse(line: line), .ignored, "「\(line)」不该让整条流失败")
    }
  }

  /// 危险工具必须在参数里被明确禁掉。
  ///
  /// 「把素材写成稿子」不需要任何工具:素材随提示词给,产出是纯文本。
  /// 没有工具就没有权限确认,非交互下也就不会卡住。
  func testRequestDeniesToolsThatCouldTouchTheMachine() {
    let request = ClaudeCLIRequest(
      prompt: "写一段", workingDirectory: URL(fileURLWithPath: "/private/tmp/x")
    )
    let joined = request.arguments.joined(separator: " ")
    XCTAssertTrue(joined.contains("--disallowed-tools"))
    for tool in ["Bash", "Edit", "Write", "Task"] {
      XCTAssertTrue(
        ClaudeCLIRequest.deniedTools.contains(tool),
        "\(tool) 必须被禁——它能碰这台机器"
      )
    }
    // 实测 `--allowed-tools ""` 不生效(工具数仍是 33),所以不能靠它。
    XCTAssertFalse(joined.contains("--allowed-tools"))
    XCTAssertTrue(joined.contains("--max-turns 1"), "写作任务一轮就够,给上限防止绕进循环")
  }
}
