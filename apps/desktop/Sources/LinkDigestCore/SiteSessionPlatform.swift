import Foundation

/// 持有 App 自有登录会话的平台。
///
/// 这个会话**只服务于会过期的高清播放地址刷新**，不服务于抓取——抓取是浏览器扩展
/// 的职责，它跑在用户自己的登录会话里，本来就能看到登录后的内容。
///
/// 会话有两种用途，别混：
/// 1. **刷新会过期的播放地址**（B 站）——高清档要按账号权限重新获取。
/// 2. **拿到登录后才可见的正文**（抖音、小红书）——手动链接抓取需要带上会话，
///    否则服务端返回登录墙 / 风控页。
///
/// 曾经这里还列着 x 和 youtube 两个 "reserved" case，零调用方，而设置页据此写着
/// 「即将支持」。逐个核对消费端后确认它们确实不该实现：
///
/// - YouTube：走 nocookie embed，`SessionMediaRefreshService` 直接
///   `throw .youtubeUsesEmbed`，没有能接受 cookie 的入口。
/// - X：`XTweetResolver` 用的是 X 给第三方嵌入的**公开**端点，那个端点不认账号，
///   加 cookie 不产生任何效果。要让登录起作用只能改走需鉴权的私有接口，
///   而项目明确回避私有接口 replay。
///
/// 抖音和小红书一度也被判成「不需要」，理由是适配器注释写着 "does not read browser
/// cookies"。那句话说的是**不去偷读系统浏览器的 cookie 库**，与「用户主动登录、
/// 存在隔离 WebKit 分区的 App 自有会话」是两回事——后者正是 B 站在用的模式。
/// 混淆这两者会把该做的功能判成不该做。
public enum SiteSessionPlatform: String, Codable, Sendable, Equatable, CaseIterable {
  /// 会过期的高清播放地址，需要按账号权限重新获取。
  case bilibili
  /// 未登录拿不到正文：手动链接抓取会撞登录墙 / 风控页。
  case douyin
  case xiaohongshu

  public var displayName: String {
    switch self {
    case .bilibili: "B 站"
    case .douyin: "抖音"
    case .xiaohongshu: "小红书"
    }
  }
}
