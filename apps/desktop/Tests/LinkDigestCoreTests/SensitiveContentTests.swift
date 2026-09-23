import XCTest
@testable import LinkDigestCore

/// 密钥、令牌、账号密码不进素材库、不交给 AI 工具；普通文章不能被误判。
/// 夹具里的「密钥」全是随手拼的假串。
final class SensitiveContentTests: XCTestCase {
  func testRecognizesCommonSecretShapes() {
    let fake = String(repeating: "a1B2", count: 10)
    for sample in [
      "export OPENAI=sk-proj-\(fake)",
      "gemini AIza\(fake)",
      "ghp_\(fake)",
      "-----BEGIN OPENSSH PRIVATE KEY-----",
      "ssh-rsa AAAA\(fake)\(fake)",
      "http://127.0.0.1:18789/#token=\(fake)",
      "Authorization: Bearer \(fake)",
      "密码：Abc12345",
      "api_key = \(fake)",
    ] {
      XCTAssertTrue(SensitiveContent.looksSensitive(sample), sample)
    }
  }

  func testOrdinaryWritingIsNotFlagged() {
    for sample in [
      "今天聊了 API 设计和 token 计费的问题，密码学是另一个话题。",
      "用 Claude Code 写了一个 skill，重点是上下文管理。",
      "商业化方向：首先要确定各项人工成本",
      "https://example.com/article?id=12345",
    ] {
      XCTAssertFalse(SensitiveContent.looksSensitive(sample), sample)
    }
  }

  func testSensitiveFoldersAreExcludedByName() {
    for folder in ["🔑 API 密钥", "👤 账号密码", "Syc｜证件与财务", "📦 网盘与卡密", "🌐 代理与服务器", "Syc｜账号与密钥"] {
      XCTAssertTrue(SensitiveContent.isExcludedNotesFolder(folder), folder)
    }
    for folder in ["Syc｜内容与创作", "灵感库", "计划", "每日工作", nil] as [String?] {
      XCTAssertFalse(SensitiveContent.isExcludedNotesFolder(folder), folder ?? "nil")
    }
    XCTAssertTrue(SensitiveContent.isExcludedNotesFolder("私人", extra: ["私人"]))
  }
}
