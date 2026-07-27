import XCTest

/// PRD 的用户承诺第五条：「失败可恢复——提取、连接、模型和存储错误必须给出人话原因和
/// 下一步动作。」这个文件是那条承诺的护栏，收集**用户主动操作 + 写入失败无出口**的路径。
///
/// 为什么是源码断言而不是行为测试：这些路径要么需要注入一个会失败的存储（脑图保存），
/// 要么需要真实 UI 交互（NSSavePanel）。行为测试当然更好，能写就写；写不了的用这里钉住
/// 「不许退回 `try?`」，至少让回归有人拦。**这类断言证明不了运行时行为，只证明写法。**
///
/// 排查方法记在这里，方便下次接着做：
/// ```bash
/// grep -rn 'try?' apps/desktop/Sources/LinkDigestApp --include='*.swift' \
///   | grep -E 'store\.|repository\.|\.save|\.write|\.delete|\.add|\.update'
/// ```
/// 2026-07-27 那次扫描：App 层 70 处 `try?`，其中命中写入的 11 处，确认 3 处是用户可见的
/// 静默失败（本文件三条）。其余为读取回退、一次性迁移清理、AI 附赠标签等可接受的降级。
final class SilentFailureGuardTests: XCTestCase {
  private func source(_ relativePath: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(relativePath)"),
      encoding: .utf8)
  }

  /// 只留代码行。
  ///
  /// 必须这样过滤：这些修复的注释里都会引用被替换掉的旧写法（「原来是 `try? …`」），
  /// 直接对全文 `contains` 会被自己的注释判红——第一版就是这么绿转红的。
  private func codeLines(_ text: String) -> String {
    text
      .components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
  }

  /// 脑图编辑是「先上屏、后落库」，所以落库失败必须说话。
  ///
  /// 原来两处都是 `Task.detached { try? store.saveMindMap(record) }`：改完大纲或换完配色
  /// 界面立刻变了，写库失败却完全无声，下次打开这条记录编辑就没了。和「删掉的摘录刷新后
  /// 复活」是同一类问题——先上屏后落库，而落库没有出口。
  func testMindMapEditsReportPersistenceFailures() throws {
    let text = try source("HistoryViewModel.swift")
    let code = codeLines(text)

    XCTAssertFalse(
      code.contains("try? store.saveMindMap"),
      "脑图保存又退回 `try?` 了：用户的编辑会静默丢失")
    XCTAssertTrue(
      code.contains("private func persistMindMap("),
      "脑图保存应当走统一入口，两处各写一份必然有一处漏掉失败处理")

    // 入口里必须真的把失败接出去，而不是 catch 完什么都不做。
    let body = code
      .components(separatedBy: "private func persistMindMap(")
      .dropFirst().first ?? ""
    let scope = body.components(separatedBy: "\n  func ").first ?? body
    XCTAssertTrue(
      scope.contains("catch"), "persistMindMap 没有 catch，等于还是吞掉")
    XCTAssertTrue(
      scope.contains("annotationFailureMessage"),
      "捕获到失败却没有接到用户可见的提示通道上")
  }

  /// 「存储图片」是用户选完位置、明确点了保存的重动作，写失败不能什么都不发生。
  ///
  /// 原来是 `try? data.write(to: destination)`：磁盘满、无权限、目标被占用都表现为
  /// 「点了没反应」，人会以为存好了，去那个目录才发现没有。旁边的 copyImage 尚且有
  /// flash 反馈，保存反而无声。
  func testSavingAnInlineImageReportsWriteFailures() throws {
    let text = try source("MarkdownPresentation.swift")
    let code = codeLines(text)

    XCTAssertFalse(
      code.contains("try? data.write(to: destination)"),
      "保存图片又退回 `try?` 了：写失败会表现为「点了没反应」")
    XCTAssertTrue(
      code.contains("presentFailure("),
      "保存失败应当有用户可见的出口")

    // 缓存缺失和写入失败是两种原因，文案不能合并成一句含糊的「失败」。
    XCTAssertTrue(
      text.contains("这张图片的本机缓存已经不在了"),
      "缓存已被清理时要给出对应的下一步，而不是笼统报错")
    XCTAssertTrue(
      text.contains("图片没能保存到所选位置"),
      "写入失败要带上系统给的原因")
  }
}
