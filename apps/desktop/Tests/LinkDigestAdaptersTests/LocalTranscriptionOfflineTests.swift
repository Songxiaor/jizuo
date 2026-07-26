import XCTest

@testable import LinkDigestAdapters

/// 本机转写必须在断网状态下全程可完成。
///
/// 这是 `docs/specs/P0_RC_LOOP_V_VIDEO_TRANSCRIPTION.md` 里 Loop V-2 的验收门，
/// 原计划靠人工拔网线跑一次。一次性手工验证证明不了以后：任何人往转写路径上加一个
/// 兜底请求、或让转写在模型缺失时顺手去下载，断网就会重新变成失败，而且在联网的
/// 开发机上永远发现不了。所以把它变成源码级不变式，每次 CI 都跑。
///
/// 钉三条：
/// 1. 转写适配器里没有任何网络类型；
/// 2. 唯一会触网的模型下载只出现在显式的 `downloadModel` 里；
/// 3. 真正做识别的 `recognize` 先断言模型已安装，缺模型时直接失败而不是去下载。
final class LocalTranscriptionOfflineTests: XCTestCase {
  private func source() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(
        "apps/desktop/Sources/LinkDigestAdapters/AppleSpeechVideoTranscriber.swift"),
      encoding: .utf8)
  }

  func testTranscriberHasNoNetworkingTypes() throws {
    let text = try source()
    for symbol in ["URLSession", "URLRequest", "NSURLConnection", "dataTask", "https://"] {
      XCTAssertFalse(
        text.contains(symbol),
        "本机转写路径出现了网络符号 \(symbol)——断网转写会失败，且只有断网才看得出来")
    }
  }

  func testOnlyTheExplicitDownloadMethodCanInstallModels() throws {
    let text = try source()
    let installCalls = text.components(separatedBy: "downloadAndInstall").count - 1
    XCTAssertEqual(installCalls, 1, "模型安装调用不止一处，转写路径可能会顺手触发下载")

    // 那唯一一处必须落在 downloadModel 里：从 downloadModel 开始到下一个 public
    // 方法之间的区间。
    guard let start = text.range(of: "public func downloadModel") else {
      return XCTFail("downloadModel 不存在了，模型安装的边界需要重新确认")
    }
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n  public func") ?? rest.range(of: "\n  private func")
    let body = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
    XCTAssertTrue(
      body.contains("downloadAndInstall"),
      "唯一的模型安装调用不在 downloadModel 里——转写可能会隐式触网")
  }

  func testRecognitionRefusesWhenTheModelIsMissingInsteadOfFetchingIt() throws {
    let text = try source()
    guard let start = text.range(of: "private static func recognize") else {
      return XCTFail("recognize 不存在了，断网不变式需要重新确认")
    }
    let rest = text[start.upperBound...]
    let body = String(rest.prefix(1_200))
    XCTAssertTrue(
      body.contains("status(forModules:") && body.contains("== .installed"),
      "recognize 没有先断言模型已安装；缺模型时它可能去下载，断网即失败")
    XCTAssertFalse(
      body.contains("downloadAndInstall"),
      "recognize 里直接安装模型，断网转写必然失败")
  }
}
