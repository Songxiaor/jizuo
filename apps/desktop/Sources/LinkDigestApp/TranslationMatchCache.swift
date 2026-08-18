import LinkDigestCore

/// 「捕获内容与输出语言是否相同」的判定缓存。
///
/// 判定本身是纯函数，但它在 SwiftUI 视图 body 内被反复调用——工具栏按钮的
/// 可用状态、翻译入口的 `.disabled` 修饰符都要问它。每次重求值都要把整篇
/// 正文先剥 frontmatter、再逐字符遍历 unicodeScalars 判断是否字母，正文越
/// 长越贵，点一下别处都要重付一遍整篇扫描的钱。
///
/// 这里按 (正文, 输出语言) 备忘，两者都不变时直接返回上次的 Bool。键的
/// 基数很低：同一时刻通常只有一篇正文 × 少数几个输出语言在比。
///
/// 只在主线程使用；条目数用小容量 LRU 限住，正文不会被无限持有。
@MainActor
enum TranslationMatchCache {
  /// 同时驻留的缓存条目数。键基数很低：同一时刻只有当前文档 × 少数几个
  /// 输出语言在比较，16 足以覆盖「当前文档 + 最近几篇」的余量。
  private static let capacity = 16

  private struct MatchKey: Hashable {
    let text: String?
    let outputLanguage: String
  }

  private static var entries: [MatchKey: Bool] = [:]
  private static var order: [MatchKey] = []

  static func isMatch(text: String?, outputLanguage: String) -> Bool {
    let key = MatchKey(text: text, outputLanguage: outputLanguage)
    if let cached = lookup(key, in: entries, order: &order) { return cached }
    let result = compute(text: text, outputLanguage: outputLanguage)
    remember(result, forKey: key, in: &entries, order: &order)
    return result
  }

  private static func compute(text: String?, outputLanguage: String) -> Bool {
    guard let text else { return false }
    // 判断语言时先剥掉开头的元数据块：那段 YAML 全是英文键名，
    // 混进去会稀释中文正文的占比，让「内容已是中文」误判成「可翻译」。
    let body = MarkdownNoteFrontmatter.parse(text).body
    return CapturedContentLanguage.isSameOutputLanguage(
      content: body.isEmpty ? text : body,
      outputLanguage: outputLanguage
    )
  }

  /// 命中即续命：把命中的键挪到队尾，淘汰顺序从 FIFO 变成 LRU。
  private static func lookup<Key: Hashable, Value>(
    _ key: Key,
    in entries: [Key: Value],
    order: inout [Key]
  ) -> Value? {
    guard let value = entries[key] else { return nil }
    if order.last != key, let index = order.lastIndex(of: key) {
      order.remove(at: index)
      order.append(key)
    }
    return value
  }

  private static func remember<Key: Hashable, Value>(
    _ value: Value,
    forKey key: Key,
    in entries: inout [Key: Value],
    order: inout [Key],
    capacity: Int = capacity
  ) {
    entries[key] = value
    order.append(key)
    if order.count > capacity {
      let evicted = order.removeFirst()
      entries.removeValue(forKey: evicted)
    }
  }
}
