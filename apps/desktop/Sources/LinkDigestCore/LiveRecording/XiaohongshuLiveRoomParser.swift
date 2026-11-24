import Foundation

/// 小红书直播取流。`pullConfig` 是页面运行时状态里的字符串 JSON；地址无签名、
/// 只有 FLV。roomId 超过 2^53，绝不从解析出的数字重建地址，只用 master_url。
public enum XiaohongshuLivePageParser {
  public static func roomID(fromPageURL raw: String) -> String? {
    guard let url = URL(string: raw) else { return nil }
    let host = url.host?.lowercased() ?? ""
    guard host == "www.xiaohongshu.com" || host == "xiaohongshu.com" else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count == 2, (parts[0] == "livestream" || parts[0] == "live") else { return nil }
    guard parts[1].range(of: "^[0-9]{6,25}$", options: .regularExpression) != nil else { return nil }
    return parts[1]
  }

  public static func room(
    pullConfig: String,
    pageURL: String,
    anchorName: String? = nil,
    title: String? = nil,
    fallbackFLVURL: String? = nil
  ) -> DouyinLiveRoom? {
    guard let roomID = roomID(fromPageURL: pageURL) else { return nil }
    let variants = variants(pullConfig: pullConfig, fallbackFLVURL: fallbackFLVURL)
    guard !variants.isEmpty else { return nil }
    let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return DouyinLiveRoom(
      pageURL: pageURL,
      roomID: roomID,
      anchorName: anchorName?.trimmingCharacters(in: .whitespacesAndNewlines),
      title: (cleanedTitle?.isEmpty == false) ? cleanedTitle : nil,
      variants: variants
    )
  }

  public static func variants(pullConfig: String, fallbackFLVURL: String? = nil) -> [LiveStreamVariant] {
    let fallback = fallbackFLVURL.flatMap(admittedVariantURL)
    guard
      let data = pullConfig.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let streams = object["streams"] as? [[String: Any]]
    else {
      return fallback.map { [LiveStreamVariant(quality: .origin, container: .flv, url: $0)] } ?? []
    }

    var origin: LiveStreamVariant?
    var others: [(bitrate: Int, variant: LiveStreamVariant)] = []
    for stream in streams {
      let protocolName = ((stream["protocol"] as? String) ?? "flv").lowercased()
      guard protocolName == "flv",
            let raw = stream["master_url"] as? String,
            let url = admittedVariantURL(raw)
      else { continue }
      let name = stream["quality_type_name"] as? String
      let type = stream["quality_type"] as? String
      let isOrigin = (name?.contains("原画") == true) || type == "FLV"
      let bitrate = (stream["max_bitrate"] as? NSNumber)?.intValue ?? 0
      let variant = LiveStreamVariant(
        quality: isOrigin ? .origin : .hd,
        container: .flv,
        url: url,
        label: name
      )
      if isOrigin {
        if origin == nil { origin = variant }
      } else {
        others.append((bitrate, variant))
      }
    }
    others.sort { $0.bitrate > $1.bitrate }
    let slots: [LiveQuality] = [.hd, .sd, .ld]
    let mapped = others.enumerated().map { index, row in
      LiveStreamVariant(
        quality: slots[min(index, slots.count - 1)],
        container: .flv,
        url: row.variant.url,
        resolution: row.variant.resolution,
        label: row.variant.label
      )
    }
    if origin == nil, let fallback {
      origin = LiveStreamVariant(quality: .origin, container: .flv, url: fallback)
    }
    return [origin].compactMap { $0 } + mapped
  }

  /// http 统一换 https（App 有 ATS 限制；实测 https 可拉）。
  static func admittedVariantURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: "^https?://", options: .regularExpression) != nil else { return nil }
    return trimmed.replacingOccurrences(of: "http://", with: "https://", options: [.anchored])
  }
}
