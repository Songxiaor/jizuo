import LinkDigestCore

struct StorageErrorPresentation: Equatable {
  let message: String
  let recoveryAction: String

  var visibleText: String { "\(message) \(recoveryAction)" }
}

enum StorageErrorCatalog {
  static func presentation(for code: StorageErrorCode) -> StorageErrorPresentation {
    switch code {
    case .unavailable:
      .init(message: "本地历史暂时不可用。", recoveryAction: "请重新打开 APP 后重试。")
    case .writeFailed:
      .init(message: "本地历史写入失败。", recoveryAction: "已保留最后一次成功保存的结果，请稍后重试。")
    case .futureSchema:
      .init(message: "本地历史由更新版本创建。", recoveryAction: "请升级 \(ProductDisplay.name) 后再继续。")
    case .migrationFailed:
      .init(message: "本地历史升级未完成。", recoveryAction: "原数据库已保留，请重新打开 APP 后重试。")
    case .readOnly:
      .init(message: "本地历史当前为只读。", recoveryAction: "当前无法新增捕获或运行。")
    case .integrityFailed:
      .init(message: "本地历史完整性检查失败。", recoveryAction: "请停止写入并保留现有数据。")
    case .stateConflict:
      .init(message: "本地历史状态已变化。", recoveryAction: "请重新发送页面或重新开始操作。")
    case .captureIdempotencyConflict:
      .init(message: "这次页面传输与原请求不一致。", recoveryAction: "请从浏览器重新发送当前页面。")
    case .runIdempotencyConflict:
      .init(message: "这次运行与原请求不一致。", recoveryAction: "请重新点击总结或翻译。")
    }
  }
}
