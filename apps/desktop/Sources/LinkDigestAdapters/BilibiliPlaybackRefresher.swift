import Foundation
import LinkDigestCore

public struct BilibiliViewMetadata: Sendable, Equatable {
  public let bvid: String
  public let cid: Int64
  public let title: String
  public let description: String?
  public let author: String?
  public let coverURL: URL?
  public let durationSeconds: Double?
  public let publishedAt: String?
  public let views: String?
  public let comments: String?
  public let shares: String?
  public let collects: String?
  public let likes: String?
}

/// App-side B 站播放地址刷新：只用公开 web 接口 + 站点 Referer，不写 Cookie、
/// 不绕过登录墙。成功率与清晰度上限通常低于「浏览器当前页 __playinfo__」
/// （浏览器侧带登录会话、用户当时正在播的那一档）。
///
/// 选流原则（面向 AVPlayer / AVFoundation）：
/// 1. **可播优先**：排除 Dolby Vision；同档优先 avc / AAC，其次 hevc。
/// 2. **双轨必须有声**：DASH 画面+声音都选到才返回 dual；否则优先 progressive mp4。
/// 3. **CDN 优先 bilivideo.com**：跳过易 404 的 mcdn:8082 主链，改用 backup。
/// 选流过程的可见记录。只放非敏感信息：档位号、分辨率、编码、被拒原因。
/// 不含签名 URL、不含 Cookie。
///
/// 加这个是因为「登录了还是 720P」靠读代码查不出来——每一环读起来都是通的，
/// 但结果就是不对。必须让 playurl 实际返回了什么变得可见。
public final class BilibiliSelectionDiagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  public init() {}

  public func record(_ summary: String) {
    lock.withLock { value = summary }
  }

  public func latest() -> String? {
    lock.withLock { value }
  }
}

public struct BilibiliPlaybackRefresher: Sendable {
  public enum RefreshError: Error, Equatable, Sendable {
    case unsupportedURL
    case networkOrHTTP
    case accessRestricted
    case videoUnavailable
    case invalidResponse
    case missingCID
    case noPlayableStream
  }

  private let resources: any SafeResourceFetching
  private static let maximumBodyBytes = 512 * 1024
  private static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

  private let diagnostics: BilibiliSelectionDiagnostics?

  public init(
    resources: any SafeResourceFetching,
    diagnostics: BilibiliSelectionDiagnostics? = nil
  ) {
    self.resources = resources
    self.diagnostics = diagnostics
  }

  public static func videoID(from rawURL: String) -> String? {
    guard let url = URL(string: rawURL),
          url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased()
    else { return nil }
    let normalized = host.hasPrefix("www.") ? String(host.dropFirst(4))
      : host.hasPrefix("m.") ? String(host.dropFirst(2))
      : host
    guard normalized == "bilibili.com" || normalized.hasSuffix(".bilibili.com") else { return nil }
    guard let match = url.path.range(
      of: #"^/video/(BV[0-9A-Za-z]{10}|av\d+)"#,
      options: .regularExpression
    ) else { return nil }
    let segment = String(url.path[match]).split(separator: "/").last.map(String.init)
    return segment
  }

  /// 允许的 CDN：`*.bilivideo.com`（含常见 upos 镜像）。
  /// 故意不放行 `mcdn.bilivideo.cn:8082` 一类非常规端口镜像——实测易 404，
  /// 选流时改走 backup 里的 bilivideo.com。
  public static func isAllowedCDNURL(_ raw: String) -> Bool {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return false }
    if host == "bilivideo.com" || host.hasSuffix(".bilivideo.com") {
      // 排除嵌在 hostname 里的 mcdn 误匹配（当前 bilivideo.com 后缀下不会命中）。
      return !host.contains("mcdn")
    }
    return false
  }

  /// AVFoundation 可播性评分。`nil` = 直接排除（如 Dolby Vision）。
  /// 数值越大越优先；在同等可播档内再比清晰度。
  public static func codecPlayabilityScore(_ codecs: String?) -> Int? {
    let c = (codecs ?? "").lowercased()
    if c.isEmpty { return 50 }
    // Dolby Vision / 杜比视界：AVPlayer 对 B 站 DASH 分片几乎不可播。
    if c.contains("dvh") || c.contains("dvhe") || c.contains("dova")
      || c.contains("dolby") || c.contains("dvav") {
      return nil
    }
    // 音频：优先 AAC。
    if c.contains("mp4a") { return 300 }
    if c.contains("ec-3") || c.contains("eac3") || c.contains("ac-3") { return 40 }
    if c.contains("flac") { return 30 }
    // 视频：avc > hevc > av1。
    if c.contains("avc") { return 300 }
    if c.contains("hev") || c.contains("hvc") { return 200 }
    if c.contains("av01") || c.contains("av1") { return 80 }
    return 100
  }

  public func refresh(
    pageURL: String,
    author: String? = nil,
    quality: BilibiliStreamQualityPreference = .default,
    /// Optional `Cookie` header from the App-owned B 站 WebKit session.
    /// Never log this value. When present, playurl can unlock higher tiers.
    cookieHeader: String? = nil,
    /// 用户在这条视频上手动选了清晰度。此时不再为了起播速度强制 progressive——
    /// 他要的就是画质，慢一点是他知情后接受的代价。
    userChoseQuality: Bool = false
  ) async throws -> MediaDescriptor {
    guard let bvid = Self.videoID(from: pageURL) else { throw RefreshError.unsupportedURL }
    let view = try await fetchViewMetadata(videoID: bvid, cookieHeader: cookieHeader)
    return try await refresh(
      pageURL: pageURL,
      metadata: view,
      author: author,
      quality: quality,
      cookieHeader: cookieHeader,
      userChoseQuality: userChoseQuality
    )
  }

  public func refresh(
    pageURL: String,
    metadata: BilibiliViewMetadata,
    author: String? = nil,
    quality: BilibiliStreamQualityPreference = .default,
    cookieHeader: String? = nil,
    userChoseQuality: Bool = false
  ) async throws -> MediaDescriptor {
    let stream = try await fetchPlayURL(
      bvid: metadata.bvid,
      cid: metadata.cid,
      quality: quality,
      cookieHeader: cookieHeader,
      userChoseQuality: userChoseQuality
    )
    let canonical = "https://www.bilibili.com/video/\(metadata.bvid)"
    return MediaDescriptor(
      kind: .directFile,
      pageURL: pageURL,
      canonicalURL: canonical,
      platform: "bilibili",
      ephemeralPlaybackURL: stream.videoURL,
      companionAudioURL: stream.companionAudioURL,
      mimeType: stream.companionAudioURL == nil ? "video/mp4" : "application/octet-stream",
      posterURL: metadata.coverURL?.absoluteString,
      durationSeconds: stream.durationSeconds ?? metadata.durationSeconds,
      author: author ?? metadata.author,
      expiresAt: stream.expiresAt,
      transcriptionCapability: .supported,
      selectionReason: .singleCandidate,
      playbackState: .unknown
    )
  }

  /// 转写专用取音轨。**不要复用 `refresh()`**：那条路服务的是播放，长片会被
  /// 「优先 progressive」规则导向整段 mp4，而整段 mp4 没有独立音轨——拿它去转写
  /// 等于为了声音下载整个视频（实测 13 分钟 720P 是 61.6MB，音轨只要 2~3MB）。
  ///
  /// 这里强制走 `fnval=16` 只解析 DASH 音轨，并且**挑最低码率**的那条：ASR 最终
  /// 只吃 16kHz 单声道，64kbps 与 192kbps 在识别结果上没有差别，流量却差 3 倍。
  /// 播放要音质，转写要省——两者的最优解不同，所以分开。
  public func audioOnlyTrackURL(
    pageURL: String,
    cookieHeader: String? = nil
  ) async throws -> String {
    guard let bvid = Self.videoID(from: pageURL) else { throw RefreshError.unsupportedURL }
    let view = try await fetchViewMetadata(videoID: bvid, cookieHeader: cookieHeader)
    let data = try await requestPlayURLJSON(
      bvid: view.bvid,
      cid: view.cid,
      quality: .highest,
      cookieHeader: cookieHeader,
      html5Progressive: false
    )
    guard let dash = data["dash"] as? [String: Any],
          let url = cheapestDASHAudioURL(in: dash["audio"] as? [[String: Any]])
    else { throw RefreshError.noPlayableStream }
    diagnostics?.record("转写取音轨：DASH audio 最低码率候选已选中")
    return url
  }

  /// 最低码率的可播音轨。Dolby / DTS 之类 `codecPlayabilityScore` 判不出的一律跳过，
  /// 避免选到 AVFoundation 打不开的轨——那会退化成「提取不到音频」。
  private func cheapestDASHAudioURL(in items: [[String: Any]]?) -> String? {
    guard let items else { return nil }
    let candidates: [(bandwidth: Int, url: String)] = items.compactMap { item in
      guard let url = firstAllowedURL(in: item),
            let playability = Self.codecPlayabilityScore(item["codecs"] as? String),
            playability >= 100
      else { return nil }
      // 缺 bandwidth 字段的排到最后，不让它伪装成「最便宜」。
      return (intValue(item["bandwidth"]) ?? Int.max, url)
    }
    return candidates.min(by: { $0.bandwidth < $1.bandwidth })?.url
  }

  private struct StreamURLs {
    let videoURL: String
    let companionAudioURL: String?
    let durationSeconds: Double?
    let expiresAt: String?
    /// Estimated picture height (0 if unknown, e.g. some progressive mp4).
    let height: Int
    /// Higher is better for cross-response comparison.
    let rankScore: Int
  }

  /// 超过该时长时优先 progressive mp4：AVPlayer 对超长 DASH 双轨 loadTracks 极易卡死，
  /// 而 html5 整段 mp4 可边下边播。
  private static let longFormPreferProgressiveSeconds: Double = 10 * 60

  private struct RankedStream {
    let qualityID: Int
    let height: Int
    let bandwidth: Int
    let playability: Int
    let url: String
    let isVideo: Bool

    /// 视频轨：**清晰度优先**，可播性只作同档内的取舍。
    ///
    /// 原来的公式把 `playability` 放在最高位（avc 300 / hevc 200，量级 1e8），
    /// 结果 480p 的 avc（300,032,000）能压过 1080p 的 hevc（200,080,000）——
    /// 而 B 站 1080P60 / 4K 这些高档常常只有 hevc/av1 编码，avc 通常封顶更低。
    /// 于是登录拿到高档也会被系统性地踢回低分辨率，表现就是「开了会员还是糊」。
    ///
    /// 音频轨没有分辨率概念，仍按可播性优先（AAC 最稳）。
    var score: Int {
      guard isVideo else {
        return playability * 1_000_000 + qualityID * 1_000 + min(bandwidth / 10_000, 99_999)
      }
      // 先比档位，再比实际高度，最后才用可播性和码率决同档内的胜负。
      // av1（playability 80）在这里仍会输给同档的 avc/hevc。
      return min(qualityID, 200) * 10_000_000
        + min(height, 8_000) * 1_000
        + playability
        + min(bandwidth / 100_000, 900)
    }
  }

  public func fetchViewMetadata(
    videoID: String,
    cookieHeader: String? = nil
  ) async throws -> BilibiliViewMetadata {
    guard var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view") else {
      throw RefreshError.unsupportedURL
    }
    if videoID.lowercased().hasPrefix("av"),
       let aid = Int64(videoID.dropFirst(2)) {
      components.queryItems = [.init(name: "aid", value: String(aid))]
    } else {
      components.queryItems = [.init(name: "bvid", value: videoID)]
    }
    guard let endpoint = components.url else { throw RefreshError.unsupportedURL }
    let body = try await getJSON(url: endpoint, cookieHeader: cookieHeader)
    guard let root = body as? [String: Any], let code = intValue(root["code"])
    else { throw RefreshError.networkOrHTTP }
    guard code == 0 else {
      if [-101, -403, -412, 62002].contains(code) { throw RefreshError.accessRestricted }
      if [-404, 10003, 62004].contains(code) { throw RefreshError.videoUnavailable }
      throw RefreshError.networkOrHTTP
    }
    guard let data = root["data"] as? [String: Any],
          let bvid = nonEmptyString(data["bvid"]),
          bvid.range(of: #"^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil,
          let title = nonEmptyString(data["title"])
    else { throw RefreshError.invalidResponse }
    guard let cid = int64(data["cid"]) else { throw RefreshError.missingCID }
    let duration: Double? = {
      if let d = data["duration"] as? Double, d > 0 { return d }
      if let d = data["duration"] as? Int, d > 0 { return Double(d) }
      return nil
    }()
    let author = nonEmptyString((data["owner"] as? [String: Any])?["name"])
    let coverURL = allowedCoverURL(nonEmptyString(data["pic"]))
    let publishedAt = int64(data["pubdate"]).map {
      ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
    }
    let stats = data["stat"] as? [String: Any]
    return BilibiliViewMetadata(
      bvid: bvid,
      cid: cid,
      title: title,
      description: nonEmptyString(data["desc"]),
      author: author,
      coverURL: coverURL,
      durationSeconds: duration,
      publishedAt: publishedAt,
      views: countString(stats?["view"]),
      comments: countString(stats?["reply"]),
      shares: countString(stats?["share"]),
      collects: countString(stats?["favorite"]),
      likes: countString(stats?["like"])
    )
  }

  /// 长片（≥10 分钟）优先 progressive mp4，避免双轨合成卡死。
  public static func prefersProgressiveForDuration(_ seconds: Double?) -> Bool {
    (seconds ?? 0) >= longFormPreferProgressiveSeconds
  }

  private func fetchPlayURL(
    bvid: String,
    cid: Int64,
    quality: BilibiliStreamQualityPreference,
    cookieHeader: String?,
    userChoseQuality: Bool = false
  ) async throws -> StreamURLs {
    // 拉 DASH + html5 progressive，再按「能播 / 画质 / 片长」择优。
    let dashBody = try? await requestPlayURLJSON(
      bvid: bvid,
      cid: cid,
      quality: quality,
      cookieHeader: cookieHeader,
      html5Progressive: false
    )
    let html5Body = try? await requestPlayURLJSON(
      bvid: bvid,
      cid: cid,
      quality: quality,
      cookieHeader: cookieHeader,
      html5Progressive: true
    )

    let dual = dashBody.flatMap { extractPlayableDualTrack(from: $0, quality: quality) }
      ?? html5Body.flatMap { extractPlayableDualTrack(from: $0, quality: quality) }
    var muxed = html5Body.flatMap { extractMuxedDurl(from: $0) }
      ?? dashBody.flatMap { extractMuxedDurl(from: $0) }

    let duration = dual?.durationSeconds
      ?? muxed?.durationSeconds
      ?? dashBody.flatMap(timelengthSeconds)
      ?? html5Body.flatMap(timelengthSeconds)

    // 长片没拿到整段 mp4 时，退一步用公开档再要一次。
    //
    // 带会员 Cookie 请求 `platform=html5` 时 B 站可能不给 progressive，
    // 于是长片只剩 DASH 双轨——而双轨要下两份 moov 再内存合成，
    // 时长越长越慢，一小时的片子基本必挂。
    // 实测未登录 `fnval=1` 能拿到整段 720P mp4（moov 在文件头，
    // AVFoundation 0.7 秒即 playable），画质降一档换成能播，这笔买卖划算。
    if muxed == nil, !userChoseQuality,
       Self.prefersProgressiveForDuration(duration), cookieHeader != nil {
      let publicBody = try? await requestPlayURLJSON(
        bvid: bvid,
        cid: cid,
        quality: quality,
        cookieHeader: nil,
        html5Progressive: true
      )
      muxed = publicBody.flatMap { extractMuxedDurl(from: $0) }
    }

    recordDiagnostics(
      dashBody: dashBody,
      dual: dual,
      muxed: muxed,
      duration: duration,
      userChoseQuality: userChoseQuality,
      hadCookie: cookieHeader != nil
    )

    if let chosen = pickBestStream(
      dual: dual,
      muxed: muxed,
      durationSeconds: duration,
      userChoseQuality: userChoseQuality
    ) {
      return chosen
    }

    // 放宽可播门槛再试 dual。
    if let loose = dashBody.flatMap({
      extractPlayableDualTrack(from: $0, quality: quality, allowLowPlayability: true)
    }) {
      return loose
    }

    throw RefreshError.noPlayableStream
  }

  /// 把「API 给了什么、我们选了什么」写成一行可见文字。
  /// 这是回答「登录了为什么还是 720P」的唯一可靠依据。
  private func recordDiagnostics(
    dashBody: [String: Any]?,
    dual: StreamURLs?,
    muxed: StreamURLs?,
    duration: Double?,
    userChoseQuality: Bool,
    hadCookie: Bool
  ) {
    guard let diagnostics else { return }
    var parts: [String] = []
    parts.append(hadCookie ? "带 Cookie" : "无 Cookie")

    if let dashBody {
      let videos = (dashBody["dash"] as? [String: Any])?["video"] as? [[String: Any]]
      if let videos, !videos.isEmpty {
        let heights = Set(videos.compactMap { intValue($0["height"]) }).sorted(by: >)
        parts.append("API 返回画质 \(heights.map { "\($0)p" }.joined(separator: "/"))")
        // 被编码规则挡掉的（杜比视界 → nil，av1 → 低分）也要说清楚。
        let rejected = videos.filter { Self.codecPlayabilityScore($0["codecs"] as? String) == nil }
        if !rejected.isEmpty { parts.append("排除杜比视界 \(rejected.count) 条") }
      } else {
        parts.append("API 未返回 dash")
      }
      if let accept = dashBody["accept_quality"] as? [Int] {
        parts.append("账号可用档 \(accept.map(String.init).joined(separator: ","))")
      }
    } else {
      parts.append("DASH 请求失败")
    }

    // 「无双轨候选」本身不够——还得说清每个档位死在哪一道关卡上。
    // 实测出现过：API 返回 2160p，但双轨为空，只剩 720p 整段。不写明原因
    // 就无法区分是 CDN 白名单拒了、编码被排除了，还是音轨没了。
    if dual == nil, let dashBody,
       let videos = (dashBody["dash"] as? [String: Any])?["video"] as? [[String: Any]],
       !videos.isEmpty {
      let cdnRejected = videos.filter { firstAllowedURL(in: $0) == nil }
      if !cdnRejected.isEmpty {
        let heights = Set(cdnRejected.compactMap { intValue($0["height"]) }).sorted(by: >)
        parts.append("CDN 白名单拒 \(heights.map { "\($0)p" }.joined(separator: "/"))")
      }
      let audios = (dashBody["dash"] as? [String: Any])?["audio"] as? [[String: Any]] ?? []
      if audios.isEmpty {
        parts.append("响应无音轨")
      } else if audios.allSatisfy({ firstAllowedURL(in: $0) == nil }) {
        parts.append("音轨全被 CDN 白名单拒")
      }
    }
    parts.append(dual.map { "双轨候选 \($0.height)p" } ?? "无双轨候选")
    parts.append(muxed.map { "整段候选 \($0.height)p" } ?? "无整段候选")
    if let duration { parts.append(String(format: "片长 %.0f 分", duration / 60)) }
    parts.append(userChoseQuality ? "用户手选清晰度" : "自动策略")
    diagnostics.record(parts.joined(separator: " · "))
  }

  /// 在 dual DASH 与 progressive mp4 之间选「现在就能播、且尽量高清」的一路。
  private func pickBestStream(
    dual: StreamURLs?,
    muxed: StreamURLs?,
    durationSeconds: Double?,
    userChoseQuality: Bool = false
  ) -> StreamURLs? {
    // 用户手动选了清晰度：按画质择优，长片也不再强行降到 progressive。
    // progressive 整段 mp4 上限只有 720P/1080P，会员的 4K/HDR 只存在于 DASH 双轨里，
    // 想要高画质就必须允许走双轨。
    if userChoseQuality {
      if let dual, let muxed { return dual.rankScore >= muxed.rankScore ? dual : muxed }
      return dual ?? muxed
    }

    // 长片：progressive 优先（可边下边播）；无 progressive 再 dual。
    if Self.prefersProgressiveForDuration(durationSeconds) {
      if let muxed { return muxed }
      if let dual { return dual }
      return nil
    }

    // 短片：dual 画质够用（≥720p）则 dual；低清 dual 让位给 progressive。
    if let dual, dual.height >= 720 {
      return dual
    }
    if let muxed, let dual {
      if dual.height > 0, dual.height < 720 { return muxed }
      return dual.rankScore >= muxed.rankScore ? dual : muxed
    }
    return dual ?? muxed
  }

  private func requestPlayURLJSON(
    bvid: String,
    cid: Int64,
    quality: BilibiliStreamQualityPreference,
    cookieHeader: String?,
    html5Progressive: Bool
  ) async throws -> [String: Any] {
    guard var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl") else {
      throw RefreshError.unsupportedURL
    }
    // qn = requested ceiling. With session cookies the API may return higher
    // tiers; without cookies it still clamps to the public ceiling.
    // fnval=16 → DASH; fourk=1 解锁 4K 候选（账号允许时）。
    // fnval 决定返回哪种封装，这一个参数就决定了 `durl` 有没有：
    // 实测同一条 63 分钟视频，`fnval=16`（DASH）返回 `durl` 0 段、只有拆轨 dash；
    // `fnval=1`（传统整段 mp4）返回 1 段 718MB 的 mp4720。
    // 之前两次请求都写死 16，所以 `extractMuxedDurl` 恒为 nil，
    // 「长片优先 progressive」那条规则从来没真正生效过。
    var items: [URLQueryItem] = [
      .init(name: "bvid", value: bvid),
      .init(name: "cid", value: String(cid)),
      .init(name: "qn", value: String(quality.requestedQN)),
      .init(name: "fnval", value: html5Progressive ? "1" : "16"),
      .init(name: "fourk", value: "1"),
      .init(name: "fnver", value: "0"),
      .init(name: "high_quality", value: "1"),
    ]
    if html5Progressive {
      // 贴近移动/html5 端，更容易拿到 progressive mp4。
      items.append(.init(name: "platform", value: "html5"))
    }
    components.queryItems = items
    guard let endpoint = components.url else { throw RefreshError.unsupportedURL }
    let body = try await getJSON(url: endpoint, cookieHeader: cookieHeader)
    guard let root = body as? [String: Any],
          let code = root["code"] as? Int, code == 0,
          let data = root["data"] as? [String: Any]
    else { throw RefreshError.noPlayableStream }
    return data
  }

  private func extractPlayableDualTrack(
    from data: [String: Any],
    quality: BilibiliStreamQualityPreference,
    allowLowPlayability: Bool = false
  ) -> StreamURLs? {
    guard let dash = data["dash"] as? [String: Any] else { return nil }
    let minPlay: Int = allowLowPlayability ? 1 : 150
    guard let video = bestDASHStream(
      in: dash["video"] as? [[String: Any]],
      quality: quality,
      role: .video,
      minimumPlayability: minPlay
    ),
      let audio = bestDASHStream(
        in: dash["audio"] as? [[String: Any]],
        quality: .highest,
        role: .audio,
        minimumPlayability: allowLowPlayability ? 1 : 100
      )
    else { return nil }

    let duration = timelengthSeconds(data)
    return StreamURLs(
      videoURL: video.url,
      companionAudioURL: audio.url,
      durationSeconds: duration,
      expiresAt: expiry(from: video.url),
      height: video.height,
      // 只用画面轨的分。原来把音轨分也加进来，导致 dual 恒大于 progressive，
      // 两条路根本没法比——480p 双轨也能压过 720p 整段。
      rankScore: video.score
    )
  }

  private func extractMuxedDurl(from data: [String: Any]) -> StreamURLs? {
    guard let durl = data["durl"] as? [[String: Any]] else { return nil }
    for item in durl {
      if let url = stringURL(item["url"]), Self.isAllowedCDNURL(url) {
        // Progressive mp4：按 quality 估高度（64→720, 80→1080, 112+→1440/4K 近似）。
        let qn = intValue(data["quality"]) ?? 64
        let height: Int = {
          switch qn {
          case 16: return 360
          case 32: return 480
          case 48, 64: return 720
          case 74, 80: return 1080
          case 112, 116: return 1080
          case 120, 125, 126, 127: return 2160
          default: return qn >= 80 ? 1080 : 720
          }
        }()
        return StreamURLs(
          videoURL: url,
          companionAudioURL: nil,
          durationSeconds: timelengthSeconds(data),
          expiresAt: expiry(from: url),
          height: height,
          // 与画面轨同一量纲（档位优先），这样 720p 整段和 480p 双轨才能真比出高下。
          rankScore: min(qn, 200) * 10_000_000 + min(height, 8_000) * 1_000
        )
      }
    }
    return nil
  }

  private enum StreamRole {
    case video
    case audio
  }

  private func bestDASHStream(
    in items: [[String: Any]]?,
    quality: BilibiliStreamQualityPreference,
    role: StreamRole,
    minimumPlayability: Int
  ) -> RankedStream? {
    guard let items else { return nil }
    let ranked: [RankedStream] = items.compactMap { item in
      guard let url = firstAllowedURL(in: item) else { return nil }
      let qualityID = intValue(item["id"]) ?? 0
      let height = intValue(item["height"]) ?? 0
      let bandwidth = intValue(item["bandwidth"]) ?? 0
      let codecs = item["codecs"] as? String
      guard let playability = Self.codecPlayabilityScore(codecs),
            playability >= minimumPlayability
      else { return nil }

      // Soft ceiling for data-saver / balanced（仅视频 qn；音频 id 是 30xxx 不套 cap）。
      if role == .video, quality != .highest, qualityID > 0, qualityID > quality.requestedQN {
        return nil
      }
      return RankedStream(
        qualityID: qualityID,
        height: height,
        bandwidth: bandwidth,
        playability: playability,
        url: url,
        isVideo: role == .video
      )
    }
    return ranked.max(by: { $0.score < $1.score })
  }

  /// 优先 `*.bilivideo.com` backup，跳过 mcdn 非常规端口主链。
  private func firstAllowedURL(in item: [String: Any]) -> String? {
    var candidates: [String] = []
    if let url = stringURL(item["baseUrl"]) ?? stringURL(item["base_url"]) {
      candidates.append(url)
    }
    let backups = (item["backupUrl"] as? [String])
      ?? (item["backup_url"] as? [String])
      ?? []
    candidates.append(contentsOf: backups.compactMap(stringURL))

    let allowed = candidates.filter { Self.isAllowedCDNURL($0) }
    if allowed.isEmpty { return nil }
    // 稳定源优先：upos / bilivideo.com 且非 mcdn。
    if let preferred = allowed.first(where: { url in
      let host = URL(string: url)?.host?.lowercased() ?? ""
      return host.contains("bilivideo.com") && !host.contains("mcdn")
    }) {
      return preferred
    }
    return allowed.first
  }

  private func timelengthSeconds(_ data: [String: Any]) -> Double? {
    if let ms = data["timelength"] as? Double, ms > 0 { return ms / 1_000 }
    if let ms = data["timelength"] as? Int, ms > 0 { return Double(ms) / 1_000 }
    return nil
  }

  private func getJSON(url: URL, cookieHeader: String?) async throws -> Any {
    var headers: [String: String] = [
      "Accept": "application/json",
      "User-Agent": Self.browserUserAgent,
      "Referer": "https://www.bilibili.com/",
    ]
    if let cookieHeader, !cookieHeader.isEmpty {
      headers["Cookie"] = cookieHeader
    }
    let response: SafeResourceResponse
    do {
      response = try await resources.fetchResource(
        .init(
          url: url,
          headers: headers,
          byteLimit: Self.maximumBodyBytes,
          allowsRedirectTarget: { target in
            let host = target.host?.lowercased() ?? ""
            return host == "api.bilibili.com" || host.hasSuffix(".bilibili.com")
          }
        )
      )
    } catch {
      throw RefreshError.networkOrHTTP
    }
    guard (200...299).contains(response.statusCode) else { throw RefreshError.networkOrHTTP }
    guard let object = try? JSONSerialization.jsonObject(with: response.body) else {
      throw RefreshError.networkOrHTTP
    }
    return object
  }

  private func stringURL(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func nonEmptyString(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func allowedCoverURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw),
          url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased(),
          host == "hdslb.com" || host.hasSuffix(".hdslb.com")
    else { return nil }
    return url
  }

  private func countString(_ raw: Any?) -> String? {
    guard let value = int64(raw), value >= 0 else { return nil }
    return String(value)
  }

  private func int64(_ raw: Any?) -> Int64? {
    if let value = raw as? Int64 { return value }
    if let value = raw as? Int { return Int64(value) }
    if let value = raw as? Double { return Int64(value) }
    if let value = raw as? String { return Int64(value) }
    return nil
  }

  private func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? Int64 { return Int(value) }
    if let value = raw as? Double { return Int(value) }
    if let value = raw as? String { return Int(value) }
    return nil
  }

  private func expiry(from url: String) -> String? {
    guard let deadline = URL(string: url)?.queryParameters["deadline"],
          deadline.range(of: #"^\d{9,11}$"#, options: .regularExpression) != nil,
          let seconds = TimeInterval(deadline)
    else { return nil }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
  }
}

private extension URL {
  var queryParameters: [String: String] {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?
      .queryItems?
      .reduce(into: [String: String]()) { result, item in
        if let value = item.value { result[item.name] = value }
      } ?? [:]
  }
}
