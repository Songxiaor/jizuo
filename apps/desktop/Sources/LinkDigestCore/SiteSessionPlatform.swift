import Foundation

/// App 自有、按平台隔离的登录会话。
/// B 站用于播放地址刷新；抖音和小红书用于手动抓取与主页发现。
/// X 原先没有会话消费者，单条 resolver 至今仍使用公开端点；
/// 现在仅为用户主动打开的博主主页提供持久 WebKit 分区，不重放私有接口。
/// 不读取系统浏览器 Cookie 数据库。用户可在设置中清除各平台会话。
public enum SiteSessionPlatform: String, Codable, Sendable, Equatable, CaseIterable {
  /// 会过期的高清播放地址，需要按账号权限重新获取。
  case bilibili
  /// 未登录拿不到正文：手动链接抓取会撞登录墙 / 风控页。
  case douyin
  case xiaohongshu
  /// User-authorized rendered profile discovery; no private API replay.
  case x

  public var displayName: String {
    switch self {
    case .bilibili: "B 站"
    case .douyin: "抖音"
    case .xiaohongshu: "小红书"
    case .x: "X"
    }
  }
}
