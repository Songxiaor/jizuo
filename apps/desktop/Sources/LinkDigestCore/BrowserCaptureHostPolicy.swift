import Foundation

/// 浏览器代抓能自动处理的站点名单。
///
/// 名单只有一份：`Resources/relay-host-permissions.json`。扩展构建（`wxt.config.ts`）用它
/// 生成 `host_permissions`，App 用它决定「这个链接值不值得开标签」。两边对不上时的后果
/// 是噪声很大的：扩展没有站点权限，连标签地址都看不到，最后只能等 90 秒超时。所以：
///
/// - 不在名单里的站点不开标签，立刻以 `browser_capture_permission_missing` 结束并说明原因；
/// - 名单与扩展 `host_permissions` 的一致性由两侧测试各自盯住。
public enum BrowserCaptureHostPolicy {
  private struct Document: Decodable {
    let formatVersion: Int
    let hosts: [String]
  }

  /// 资源读不到时的兜底，与 JSON 内容保持一致（有测试比对两份）。
  static let fallbackHosts: [String] = [
    "douyin.com", "iesdouyin.com", "xiaohongshu.com", "xhslink.com", "xhslink.cn",
    "x.com", "twitter.com", "bilibili.com", "b23.tv", "mp.weixin.qq.com",
    "youtube.com", "youtu.be", "zhihu.com", "reddit.com", "github.com", "medium.com",
  ]

  public static let hosts: [String] = loadHosts()

  /// 域名是不是名单里的站点（含子域，大小写不敏感）。
  public static func allows(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    return hosts.contains { entry in
      let name = entry.lowercased()
      return host == name || host.hasSuffix(".\(name)")
    }
  }

  private static func loadHosts() -> [String] {
    guard let url = CoreResourceBundle.resolved()?.url(
      forResource: "relay-host-permissions", withExtension: "json"
    ),
    let data = try? Data(contentsOf: url),
    let document = try? JSONDecoder().decode(Document.self, from: data),
    document.formatVersion == 1,
    !document.hosts.isEmpty
    else { return fallbackHosts }
    return document.hosts
  }
}
