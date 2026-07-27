import Foundation

/// User-facing naming comes from one bundled resource shared with the browser
/// extension manifest. Technical browser identity deliberately lives elsewhere.
public enum ProductDisplay {
  private struct Values: Decodable {
    let displayName: String
    let extensionDescription: String
    let extensionDisplayName: String
    let formatVersion: Int
  }

  /// 解析 `product-display.json`。
  ///
  /// 原来这里直接用 `Bundle.module`，那条路径在换机后必崩——原因、实测过程和两个实现
  /// 约束都写在 `CoreResourceBundle` 的类型注释里。这里只负责取文件。
  ///
  /// 崩溃点特别早：`LinkDigestApp` 的 `WindowGroup(ProductDisplay.name)` 在 SwiftUI 取
  /// `App.body` 的那一刻就要读它，早于任何窗口渲染。
  static func resourceURL(bundle: Bundle? = CoreResourceBundle.resolved()) -> URL? {
    bundle?.url(forResource: "product-display", withExtension: "json")
  }

  private static let values: Values = {
    guard
      let url = resourceURL(),
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(Values.self, from: data),
      decoded.formatVersion == 1,
      !decoded.displayName.isEmpty,
      !decoded.extensionDescription.isEmpty,
      !decoded.extensionDisplayName.isEmpty
    else {
      preconditionFailure("Product display resource is missing or invalid")
    }
    return decoded
  }()

  public static let name = values.displayName
  public static let extensionDescription = values.extensionDescription
  public static let extensionName = values.extensionDisplayName
}
