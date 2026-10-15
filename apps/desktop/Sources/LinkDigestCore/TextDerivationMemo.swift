import Foundation

/// 长正文的派生结果（去掉属性头后的正文、属性头字段……）按原文备忘。
///
/// 详情页刷新一次，同一份几万字的正文要被十几处各自解析一遍：判断有没有配文、拆引用、
/// 数评论、比标题……每处都从头扫全文、再整篇复制一份（2026-10-16 采样：打开一条时主线程
/// 约一成时间花在反复做 `MarkdownNoteFrontmatter.parse` 和 `LayeredSourceDocument.body`）。
/// 结果只由原文决定，原文没变就直接拿上次的。
///
/// 只记长文本（短文本重算比查表还快），只留最近几份。按原文本身比对：同一份正文在内存里
/// 是同一块存储，比对是常数时间；内容相同、存储不同时退回逐字比较，仍远比重新解析便宜。
/// 任何线程都能用。
final class TextDerivationMemo<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(source: String, value: Value)] = []
  private let capacity: Int
  private let minimumUTF8Length: Int

  init(capacity: Int = 16, minimumUTF8Length: Int = 2_048) {
    self.capacity = capacity
    self.minimumUTF8Length = minimumUTF8Length
  }

  func value(for source: String, compute: (String) -> Value) -> Value {
    let length = source.utf8.count
    guard length >= minimumUTF8Length else { return compute(source) }
    lock.lock()
    if let index = entries.lastIndex(where: { $0.source.utf8.count == length && $0.source == source }) {
      let hit = entries[index]
      if index != entries.count - 1 {
        entries.remove(at: index)
        entries.append(hit)
      }
      lock.unlock()
      return hit.value
    }
    lock.unlock()
    let value = compute(source)
    lock.lock()
    entries.append((source, value))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    lock.unlock()
    return value
  }
}
