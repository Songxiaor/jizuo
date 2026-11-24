import Foundation

/// 从直播间页面 HTML 里读出来的房间信息。只在内存里用，不落盘。
public struct DouyinLiveRoom: Sendable, Equatable {
  public let pageURL: String
  public let roomID: String
  public let anchorName: String?
  public let title: String?
  public let variants: [LiveStreamVariant]

  public init(
    pageURL: String,
    roomID: String,
    anchorName: String? = nil,
    title: String? = nil,
    variants: [LiveStreamVariant]
  ) {
    self.pageURL = pageURL
    self.roomID = roomID
    self.anchorName = anchorName
    self.title = title
    self.variants = variants
  }
}

/// 抖音直播间页面解析。
///
/// 房间数据被拆成若干 `self.__pace_f.push([1,"…"])` 片段，片段里是转义过的
/// JSON。这里按页面执行时的顺序拼回去，再取第一个 `stream_url` 对象。
/// 断线续录靠它重新拿地址：签名会过期，不能用开始录制时那一份。
public enum DouyinLivePageParser {
  public static func roomID(fromPageURL raw: String) -> String? {
    guard let url = URL(string: raw) else { return nil }
    guard url.host?.lowercased() == "live.douyin.com" else { return nil }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard path.range(of: "^[0-9]{6,25}$", options: .regularExpression) != nil else { return nil }
    return path
  }

  public static func joinPaceChunks(_ html: String) -> String {
    // 不能用「字符串内容」正则：真实页面里房间数据被套了两层转义，嵌套的
    // `\\\"` 会让匹配提前收尾，几百 KB 的那一块整段丢掉。按 JS 字符串字面量
    // 的规则逐字符找闭引号，和浏览器执行时一致。
    let marker = "self.__pace_f.push([1,"
    var output = ""
    var index = html.startIndex
    while index < html.endIndex {
      guard let start = html.range(of: marker, range: index..<html.endIndex) else { break }
      var cursor = start.upperBound
      guard cursor < html.endIndex, html[cursor] == "\"" else {
        index = cursor
        continue
      }
      let literalStart = cursor
      cursor = html.index(after: cursor)
      var escaped = false
      while cursor < html.endIndex {
        let char = html[cursor]
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          break
        }
        cursor = html.index(after: cursor)
      }
      guard cursor < html.endIndex else { break }
      let literal = String(html[literalStart...cursor])
      if let data = literal.data(using: .utf8),
         let decoded = try? JSONDecoder().decode(String.self, from: data) {
        output += decoded
      } else {
        output += unescapeJavaScriptString(String(literal.dropFirst().dropLast()))
      }
      index = html.index(after: cursor)
    }
    return output
  }

  static func unescapeJavaScriptString(_ value: String) -> String {
    var output = ""
    var iterator = value.makeIterator()
    while let char = iterator.next() {
      guard char == "\\" else {
        output.append(char)
        continue
      }
      guard let next = iterator.next() else { break }
      if next == "u" {
        var hex = ""
        for _ in 0..<4 {
          guard let digit = iterator.next() else { break }
          hex.append(digit)
        }
        if let scalar = UInt32(hex, radix: 16), let unicode = UnicodeScalar(scalar) {
          output.append(Character(unicode))
        }
      } else if next == "n" {
        output.append("\n")
      } else {
        output.append(next)
      }
    }
    return output
  }

  /// 从 `{` 开始取一个平衡的 JSON 对象；字符串里的括号不算。
  static func firstJSONObject(in text: String, from start: String.Index) -> String? {
    var depth = 0
    var inString = false
    var escaped = false
    var index = start
    while index < text.endIndex {
      let char = text[index]
      if escaped {
        escaped = false
      } else if char == "\\" {
        escaped = true
      } else if char == "\"" {
        inString.toggle()
      } else if !inString {
        if char == "{" { depth += 1 }
        if char == "}" {
          depth -= 1
          if depth == 0 {
            return String(text[start...index])
          }
        }
      }
      index = text.index(after: index)
    }
    return nil
  }

  public static func parse(
    html: String,
    pageURL: String,
    title: String? = nil,
    resourceURLs: [String] = []
  ) -> DouyinLiveRoom? {
    guard let roomID = roomID(fromPageURL: pageURL) else { return nil }
    let payload = joinPaceChunks(html)
    var parsedVariants: [LiveStreamVariant] = []
    var anchorName: String?
    if let marker = payload.range(of: "\"stream_url\""),
       let brace = payload[marker.upperBound...].firstIndex(of: "{") {
      if let object = firstJSONObject(in: payload, from: brace),
         let data = object.data(using: .utf8),
         let stream = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        parsedVariants = variants(from: stream)
        anchorName = ownerNickname(in: payload, startingAt: marker.lowerBound)
      }
    }
    if parsedVariants.isEmpty {
      parsedVariants = variantsFromResourceURLs(resourceURLs)
    }
    guard !parsedVariants.isEmpty else { return nil }
    let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return DouyinLiveRoom(
      pageURL: pageURL,
      roomID: roomID,
      anchorName: anchorName,
      title: (cleanedTitle?.isEmpty == false) ? cleanedTitle : nil,
      variants: parsedVariants
    )
  }

  /// 房间对象里的 `owner` 就是主播。按对象解析，不依赖字段顺序：JSON 序列化
  /// 不保证顺序，owner 可能排在 stream_url 前面也可能在后面。
  static func ownerNickname(in payload: String, startingAt start: String.Index) -> String? {
    let windowStart = payload.index(start, offsetBy: -2_000, limitedBy: payload.startIndex)
      ?? payload.startIndex
    let windowEnd = payload.index(start, offsetBy: 20_000, limitedBy: payload.endIndex)
      ?? payload.endIndex
    var searchStart = windowStart
    while let marker = payload.range(of: "\"owner\":", range: searchStart..<windowEnd) {
      if let brace = payload[marker.upperBound...].firstIndex(of: "{"),
         let object = firstJSONObject(in: payload, from: brace),
         let data = object.data(using: .utf8),
         let owner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
         let nickname = owner["nickname"] as? String {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
      }
      searchStart = marker.upperBound
    }
    return nil
  }

  static let mapKey: [LiveQuality: String] = [
    .origin: "FULL_HD1",
    .hd: "HD1",
    .sd: "SD2",
    .ld: "SD1",
  ]

  public static func variants(from stream: [String: Any]) -> [LiveStreamVariant] {
    let flv = stringMap(stream["flv_pull_url"])
    let hls = stringMap(stream["hls_pull_url_map"])
    var qualities: [(LiveQuality, String?, String?)] = []
    if let core = stream["live_core_sdk_data"] as? [String: Any],
       let pull = core["pull_data"] as? [String: Any],
       let options = pull["options"] as? [String: Any],
       let rows = options["qualities"] as? [[String: Any]] {
      var seen = Set<LiveQuality>()
      for row in rows {
        guard let key = row["sdk_key"] as? String,
              let quality = LiveQuality(rawValue: key),
              seen.insert(quality).inserted
        else { continue }
        qualities.append((quality, row["name"] as? String, row["resolution"] as? String))
      }
    }
    if qualities.isEmpty {
      qualities = LiveQuality.allCases.map { ($0, nil, nil) }
    }
    qualities.sort { a, b in
      (LiveQuality.allCases.firstIndex(of: a.0) ?? 0) < (LiveQuality.allCases.firstIndex(of: b.0) ?? 0)
    }

    var variants: [LiveStreamVariant] = []
    var seen = Set<String>()
    for (quality, name, resolution) in qualities {
      guard let key = mapKey[quality] else { continue }
      let candidates: [(LiveStreamContainer, String?)] = quality == .origin
        ? [(.hls, hls[key]), (.flv, flv[key])]
        : [(.flv, flv[key]), (.hls, hls[key])]
      for (container, raw) in candidates {
        guard let raw,
              LiveRecordingRequest.admittedStreamURL(raw, container: container)
        else { continue }
        let identity = "\(quality.rawValue):\(container.rawValue)"
        guard seen.insert(identity).inserted else { continue }
        variants.append(
          LiveStreamVariant(
            quality: quality,
            container: container,
            url: raw,
            resolution: resolution,
            label: name
          )
        )
      }
    }
    return variants
  }

  public static func variantsFromResourceURLs(_ urls: [String]) -> [LiveStreamVariant] {
    var variants: [LiveStreamVariant] = []
    var seen = Set<String>()
    for raw in urls {
      guard let url = URL(string: raw) else { continue }
      let file = url.path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
      let container: LiveStreamContainer
      if file.hasSuffix(".m3u8") { container = .hls }
      else if file.hasSuffix(".flv") { container = .flv }
      else { continue }
      guard let quality = quality(fromFileName: file) else { continue }
      guard seen.insert(raw).inserted else { continue }
      variants.append(LiveStreamVariant(quality: quality, container: container, url: raw))
    }
    return variants
  }

  static func quality(fromFileName file: String) -> LiveQuality? {
    let stem = (file as NSString).deletingPathExtension
    if stem.hasSuffix("_or4") || stem.hasSuffix("_origin") { return .origin }
    if stem.hasSuffix("_hd") || stem.hasSuffix("_hd5") { return .hd }
    if stem.hasSuffix("_sd") || stem.hasSuffix("_sd5") { return .sd }
    if stem.hasSuffix("_ld") || stem.hasSuffix("_ld5") { return .ld }
    // 没有后缀的是原画（H.265 那一路）。FLV 原画录不出画面，选档时会自动跳过。
    return .origin
  }

  private static func stringMap(_ value: Any?) -> [String: String] {
    guard let record = value as? [String: Any] else { return [:] }
    var output: [String: String] = [:]
    for (key, item) in record {
      if let string = item as? String, string.range(of: "^https?://", options: .regularExpression) != nil {
        output[key] = string
      }
    }
    return output
  }
}
