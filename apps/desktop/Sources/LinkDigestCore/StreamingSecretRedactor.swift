import Foundation

/// 流式输出里的密钥脱敏。
///
/// 密钥可能被模型切在两个 delta 中间，所以尾部凡是"看起来像密钥开头"的字符
/// 都先扣着（holdback），等下一段到了再判断——这套窗口语义是这个类型存在的
/// 全部理由，改动时必须原样保留。
///
/// `append` 只返回**本次新增**的片段，不返回累积全文。
///
/// 原来返回累积全文：调用方拿到它、又把它存下来，于是每来一个 delta 都要把
/// 整串复制一遍（写时复制），外加一次整串比较去重。三万个 delta 的长翻译因此
/// 累计几十亿次字符拷贝，越到后面越慢。累积的活儿现在交给调用方的独占 buffer，
/// 这里只负责"放出来多少"。
struct StreamingSecretRedactor: Sendable {
  static let mask = "[已隐藏]"

  private let secret: String
  private var holdback = ""

  init(secret: String) {
    self.secret = secret
  }

  /// 返回本次可以安全放出的新增片段（可能为空：全被扣住了）。
  mutating func append(_ delta: String) -> String {
    holdback += delta
    return processCompleteInput()
  }

  /// 流结束：把还扣着的尾巴处理掉。扣着的尾巴是密钥的真前缀，永远不放原文。
  mutating func finalize() -> String {
    var released = processCompleteInput()
    if !holdback.isEmpty {
      released += Self.mask
      holdback = ""
    }
    return released
  }

  private mutating func processCompleteInput() -> String {
    guard !secret.isEmpty else {
      let released = holdback
      holdback = ""
      return released
    }

    var released = ""
    while let range = holdback.range(of: secret) {
      released += String(holdback[..<range.lowerBound])
      released += Self.mask
      holdback = String(holdback[range.upperBound...])
    }

    let bufferCharacters = Array(holdback)
    let secretCharacters = Array(secret)
    let upperBound = min(bufferCharacters.count, max(secretCharacters.count - 1, 0))
    var heldCount = 0
    if upperBound > 0 {
      for count in stride(from: upperBound, through: 1, by: -1) {
        if Array(bufferCharacters.suffix(count)) == Array(secretCharacters.prefix(count)) {
          heldCount = count
          break
        }
      }
    }
    let releaseCount = bufferCharacters.count - heldCount
    if releaseCount > 0 {
      released += String(bufferCharacters.prefix(releaseCount))
    }
    holdback = String(bufferCharacters.suffix(heldCount))
    return released
  }
}
