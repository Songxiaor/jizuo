import LinkDigestCore

struct StorageErrorPresentation: Equatable {
  let message: String
  let recoveryAction: String

  var visibleText: String { "\(message) \(recoveryAction)" }
}

/// 错误文案统一模板：发生了什么 + 数据安不安全 + 现在能做什么。
/// 不允许出现 provider / API Key / Base URL / 网络 这类工程词（有条测试盯着）。
enum StorageErrorCatalog {
  static func presentation(for code: StorageErrorCode) -> StorageErrorPresentation {
    switch code {
    case .unavailable:
      .init(message: "资料库暂时没有打开。", recoveryAction: "现有内容没有被改动，重新打开 \(ProductDisplay.name) 就能继续。")
    case .writeFailed:
      .init(message: "这次没能写进资料库。", recoveryAction: "已保留最后一次成功保存的结果，请稍后重试。")
    case .futureSchema:
      .init(message: "资料库是更新版本的 \(ProductDisplay.name) 建的。", recoveryAction: "现有内容没有被改动，请升级 \(ProductDisplay.name) 后再继续。")
    case .migrationFailed:
      .init(message: "资料库升级没有完成。", recoveryAction: "原数据已留了一份备份，重新打开 \(ProductDisplay.name) 会再试一次。")
    case .readOnly:
      .init(message: "资料库现在只能看、不能改。", recoveryAction: "现有内容都还在，暂时不能保存新网页或生成总结；重新打开 \(ProductDisplay.name) 通常就能恢复。")
    case .integrityFailed:
      .init(message: "资料库的完整性检查没有通过。", recoveryAction: "现有内容还在，\(ProductDisplay.name) 已停止写入。请先在「数据与备份」里备份，再重新打开。")
    case .stateConflict:
      .init(message: "资料库里的这条内容刚刚变过。", recoveryAction: "没有内容被改写，请从浏览器重新保存这个页面，或重新开始操作。")
    case .captureIdempotencyConflict:
      .init(message: "这次保存跟原来的请求对不上。", recoveryAction: "没有写入新内容，请从浏览器重新保存当前页面。")
    case .runIdempotencyConflict:
      .init(message: "这次生成跟原来的请求对不上。", recoveryAction: "没有覆盖已有结果，请重新点击总结或翻译。")
    }
  }
}
