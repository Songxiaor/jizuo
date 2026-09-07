import Foundation
import WebKit

/// Projected Douyin interaction counts taken from a page-owned list/detail
/// response. Full payloads are never retained.
struct DouyinProfileMetricsProjection: Codable, Equatable {
  let workID: String
  let authorID: String
  var likes: String?
  var comments: String?
  var collects: String?
  var observedAt: String
  var source: String

  var isComplete: Bool {
    likes != nil && comments != nil && collects != nil
  }
}

enum DouyinProfileMetricsSource {
  static let homepageList = "homepage_list"
  static let homepageDOM = "homepage_dom"
  static let detailList = "detail_list"
  static let detailStructured = "detail_structured"
  static let detailDOM = "detail_dom"
}

enum DouyinProfileMetricsCapture {
  static let storageKey = "__linkdigestAwemeStats"
  static let cacheTTL: TimeInterval = 10 * 60
  static let detailDeadlineSeconds: TimeInterval = 8
  static let partialMessage = "仍有未读取项"

  static func pausesAutomaticReading(_ status: String?) -> Bool {
    status == "login" || status == "verification" || status == "rate_limit"
  }

  static func allows(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
          url.user == nil, url.password == nil,
          url.port == nil || url.port == 443,
          let host = url.host?.lowercased()
    else { return false }
    guard host == "www.douyin.com" || host == "douyin.com" else { return false }
    var path = url.path
    if path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path == "/aweme/v1/web/aweme/post" || path == "/aweme/v1/web/aweme/detail"
  }

  static func count(_ value: Any?) -> String? {
    if value is NSNull { return nil }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
      let doubleValue = number.doubleValue
      guard doubleValue.isFinite, doubleValue >= 0, doubleValue <= 1e15,
            doubleValue == doubleValue.rounded(.towardZero)
      else { return nil }
      return String(Int64(doubleValue))
    }
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
      guard let integer = Int64(trimmed), integer <= 1_000_000_000_000_000 else { return nil }
      return String(integer)
    }
    return nil
  }

  /// Prefer a newly observed field; keep a previous real value when the
  /// incoming field is missing. Zero is a legal count and must be kept.
  /// A different author on the same work ID must not inherit prior counts.
  static func merging(_ current: DouyinProfileMetricsProjection?, with incoming: DouyinProfileMetricsProjection) -> DouyinProfileMetricsProjection {
    guard let current else { return incoming }
    if !incoming.authorID.isEmpty, current.authorID != incoming.authorID {
      return incoming
    }
    return DouyinProfileMetricsProjection(
      workID: incoming.workID,
      authorID: incoming.authorID.isEmpty ? current.authorID : incoming.authorID,
      likes: incoming.likes ?? current.likes,
      comments: incoming.comments ?? current.comments,
      collects: incoming.collects ?? current.collects,
      observedAt: incoming.observedAt,
      source: incoming.source
    )
  }

  static func project(
    jsonObject: Any,
    observedAt: String,
    source: String
  ) -> [DouyinProfileMetricsProjection] {
    guard let root = jsonObject as? [String: Any] else { return [] }
    let items = awemeItems(in: root)
    var seen = Set<String>()
    var projections: [DouyinProfileMetricsProjection] = []
    for item in items {
      guard let projection = projectItem(item, observedAt: observedAt, source: source),
            seen.insert(projection.workID).inserted
      else { continue }
      projections.append(projection)
    }
    return projections
  }

  /// Restrict a captured map to works already discovered on this homepage
  /// for this author. Neighbor/recommend rows stay out of the candidate list.
  static func matching(
    _ projections: [DouyinProfileMetricsProjection],
    authorID: String,
    discoveredWorkIDs: Set<String>
  ) -> [String: DouyinProfileMetricsProjection] {
    Dictionary(uniqueKeysWithValues: projections.compactMap { item in
      guard item.authorID == authorID, discoveredWorkIDs.contains(item.workID) else { return nil }
      return (item.workID, item)
    })
  }

  static func documentStartUserScript() -> WKUserScript {
    WKUserScript(
      source: documentStartJavaScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
  }

  static let documentStartJavaScript = #"""
  (() => {
    const STORE = '__linkdigestAwemeStats';
    if (!window[STORE]) window[STORE] = Object.create(null);
    const allowedHost = (host) => {
      const value = String(host || '').toLowerCase();
      return value === 'www.douyin.com' || value === 'douyin.com';
    };
    const allowedPath = (path) => {
      let value = String(path || '');
      if (value.length > 1 && value.endsWith('/')) value = value.slice(0, -1);
      return value === '/aweme/v1/web/aweme/post' || value === '/aweme/v1/web/aweme/detail';
    };
    const allowedURL = (raw) => {
      try {
        const url = new URL(String(raw || ''), location.href);
        return url.protocol === 'https:' && allowedHost(url.hostname) && allowedPath(url.pathname);
      } catch (_) { return false; }
    };
    const count = (value) => {
      if (typeof value === 'boolean') return null;
      if (typeof value === 'number') {
        if (!Number.isInteger(value) || value < 0 || value > 1e15) return null;
        return String(value);
      }
      if (typeof value === 'string') {
        const trimmed = value.trim();
        if (!/^\d+$/.test(trimmed)) return null;
        return trimmed;
      }
      return null;
    };
    const projectItem = (item, source) => {
      if (!item || typeof item !== 'object') return;
      const workID = String(item.aweme_id || item.awemeId || '');
      if (!/^\d{10,25}$/.test(workID)) return;
      const author = item.author && typeof item.author === 'object' ? item.author : {};
      const authorID = String(author.sec_uid || author.secUid || '');
      if (!authorID) return;
      const stats = item.statistics && typeof item.statistics === 'object' ? item.statistics : {};
      const next = {
        workID,
        authorID,
        likes: count(stats.digg_count != null ? stats.digg_count : stats.diggCount),
        comments: count(stats.comment_count != null ? stats.comment_count : stats.commentCount),
        collects: count(stats.collect_count != null ? stats.collect_count : stats.collectCount),
        observedAt: new Date().toISOString(),
        source
      };
      const current = window[STORE][workID];
      if (current && current.authorID && current.authorID !== authorID) {
        window[STORE][workID] = next;
        return;
      }
      window[STORE][workID] = {
        workID,
        authorID,
        likes: next.likes ?? (current && current.likes) ?? null,
        comments: next.comments ?? (current && current.comments) ?? null,
        collects: next.collects ?? (current && current.collects) ?? null,
        observedAt: next.observedAt,
        source
      };
    };
    const projectPayload = (data, source) => {
      if (!data || typeof data !== 'object') return;
      const nest = data.data && typeof data.data === 'object' ? data.data : data;
      const list = Array.isArray(nest.aweme_list) ? nest.aweme_list
        : (nest.aweme_detail ? [nest.aweme_detail] : (data.aweme_detail ? [data.aweme_detail] : []));
      for (const item of list) projectItem(item, source);
    };
    const ingest = (data, url) => {
      let source = 'detail_list';
      try {
        const path = new URL(String(url || ''), location.href).pathname;
        if (path.indexOf('/aweme/v1/web/aweme/post/') !== -1) source = 'homepage_list';
      } catch (_) {}
      projectPayload(data, source);
    };
    const origFetch = window.fetch;
    if (typeof origFetch === 'function') {
      window.fetch = function() {
        const input = arguments[0];
        const url = typeof input === 'string' ? input : (input && input.url);
        const pending = origFetch.apply(this, arguments);
        if (allowedURL(url)) {
          pending.then((response) => {
            try { response.clone().json().then((data) => ingest(data, url)).catch(() => {}); } catch (_) {}
          }).catch(() => {});
        }
        return pending;
      };
    }
    const proto = XMLHttpRequest.prototype;
    const origOpen = proto.open;
    const origSend = proto.send;
    proto.open = function(method, url) {
      this.__linkdigestAwemeURL = url;
      return origOpen.apply(this, arguments);
    };
    proto.send = function() {
      this.addEventListener('load', function() {
        if (!allowedURL(this.__linkdigestAwemeURL)) return;
        try {
          if (this.responseType === 'json') {
            if (this.response && typeof this.response === 'object') ingest(this.response, this.__linkdigestAwemeURL);
            return;
          }
          if (this.responseJSON && typeof this.responseJSON === 'object') {
            ingest(this.responseJSON, this.__linkdigestAwemeURL);
            return;
          }
          if (this.responseText) ingest(JSON.parse(this.responseText), this.__linkdigestAwemeURL);
        } catch (_) {}
      });
      return origSend.apply(this, arguments);
    };
  })();
  """#

  static func detailExtractionJavaScript(workID: String, authorID: String) -> String {
    guard workID.count >= 10, workID.allSatisfy(\.isNumber),
          authorID.range(of: #"[\\'"]"#, options: .regularExpression) == nil
    else { return "null" }
    return #"""
    (() => {
      const expectedID = "__WORK_ID__";
      const expectedAuthor = "__AUTHOR_ID__";
      const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
      const visible = node => {
        for (let n = node; n; n = n.parentElement) {
          const style = getComputedStyle(n);
          if (n.hidden || n.getAttribute('aria-hidden') === 'true' || style.display === 'none'
              || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
        }
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const reply = (status, counts = {}, extra = {}) => JSON.stringify({
        status, workID: expectedID, likes: null, comments: null, collects: null, source: null, readAt: null, authorID: expectedAuthor, ...counts, ...extra
      });
      const body = clean(document.body && document.body.innerText);
      if (/访问过于频繁|操作频繁|请求太多|rate.?limit/i.test(body)) {
        return reply('rate_limit');
      }
      if (/完成验证|安全验证|环境异常|人机验证/.test(body)
          || Array.from(document.querySelectorAll('[class*="captcha"], [id*="captcha"]')).some(visible)) {
        return reply('verification');
      }
      const path = location.pathname.match(/^\/(?:video|note)\/(\d{10,})/);
      if (!path || path[1] !== expectedID) return reply('wrong_work');
      const isNote = location.pathname.indexOf('/note/') === 0;
      const captured = (window.__linkdigestAwemeStats || {})[expectedID];
      const fromCapture = captured && (!expectedAuthor || captured.authorID === expectedAuthor) ? {
        likes: captured.likes ?? null,
        comments: captured.comments ?? null,
        collects: captured.collects ?? null,
        source: captured.source || 'detail_list',
        readAt: captured.observedAt || null
      } : null;
      const number = value => /^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:万|亿|[kKmMwW])?\+?$/.test(value) ? value : null;
      const info = Array.from(document.querySelectorAll('[data-e2e="detail-video-info"][data-e2e-aweme-id]')).filter(visible);
      const players = Array.from(document.querySelectorAll('[data-e2e="player-container"]')).filter(visible);
      const player = players.find(n => n.classList.contains('video_' + expectedID));
      const matchingInfo = info.find(n => n.getAttribute('data-e2e-aweme-id') === expectedID);
      const noteDetail = isNote ? document.querySelector('[data-e2e="note-detail"]') : null;
      const noteAuthors = noteDetail ? Array.from(noteDetail.querySelectorAll('[data-e2e="user-info"] a[href*="/user/"]')).map(node => {
        try {
          const match = new URL(node.getAttribute('href') || '', location.href).pathname.match(/^\/user\/([^/?#]+)/);
          return match ? decodeURIComponent(match[1]) : '';
        } catch (_) { return ''; }
      }).filter(Boolean) : [];
      const noteAuthorOK = noteAuthors.length > 0 && (!expectedAuthor || noteAuthors.every(id => id === expectedAuthor));
      const noteAuthorMismatch = Boolean(expectedAuthor) && noteAuthors.some(id => id !== expectedAuthor);
      const videoAuthors = matchingInfo ? Array.from(matchingInfo.querySelectorAll('a[href*="/user/"]')).map(node => {
        try { return new URL(node.getAttribute('href') || '', location.href).pathname.match(/^\/user\/([^/?#]+)/)?.[1] || ''; }
        catch (_) { return ''; }
      }).filter(Boolean) : [];
      const videoAuthorOK = !expectedAuthor || !!fromCapture || (videoAuthors.length > 0 && videoAuthors.every(id => id === expectedAuthor));
      const identityOK = (matchingInfo && player && videoAuthorOK) || (isNote && noteDetail && noteAuthorOK);
      if (!identityOK) {
        if (fromCapture && [fromCapture.likes, fromCapture.comments, fromCapture.collects].some(value => value !== null)) {
          return reply('ready', fromCapture);
        }
        if (/登录后查看|登录即可查看|扫码登录/.test(body)) return reply('login');
        return reply(info.length || noteAuthorMismatch ? 'wrong_work' : 'pending');
      }
      let likes = null, comments = null, collects = null, source = null;
      if (fromCapture) {
        likes = fromCapture.likes;
        comments = fromCapture.comments;
        collects = fromCapture.collects;
        source = fromCapture.source;
      }
      if (player) {
        const selectors = ['[data-e2e="video-player-digg"]', '[data-e2e="feed-comment-icon"]', '[data-e2e="video-player-collect"]'];
        const nodes = selectors.map(selector => {
          const matches = Array.from(player.querySelectorAll(selector));
          return matches.length === 1 ? matches[0] : null;
        });
        const semantic = nodes.map(node => node ? number(clean(node.textContent)) : null);
        const share = matchingInfo && matchingInfo.querySelector('[data-e2e="video-share-icon-container"]');
        const toolbar = share && share.parentElement;
        const cells = toolbar ? Array.from(toolbar.children) : [];
        const mirrors = cells.length === 4 && cells[3] === share ? cells.slice(0, 3).map(cell => {
          const spans = Array.from(cell.children).filter(node => node.tagName === 'SPAN' && visible(node));
          return spans.length === 1 ? number(clean(spans[0].innerText)) : null;
        }) : [];
        const mirrored = mirrors.length === 3 && semantic.every((value, index) => value !== null && value === mirrors[index]);
        const values = nodes.map((node, index) => node && (visible(node) || mirrored) ? semantic[index] : null);
        if (likes == null) likes = values[0];
        if (comments == null) comments = values[1];
        if (collects == null) collects = values[2];
        if (source == null && [values[0], values[1], values[2]].some(value => value !== null)) source = 'detail_dom';
      } else if (noteDetail && noteAuthorOK) {
        const inComment = node => !!(node.closest('[data-e2e="comment-list"], [data-e2e="comment-item"], [class*="comment-list"], [class*="comment-item"], [id*="comment-list"]'));
        const labeled = (keyword) => {
          const nodes = Array.from(noteDetail.querySelectorAll('[aria-label], [data-e2e]')).filter(visible);
          for (const node of nodes) {
            if (inComment(node)) continue;
            const label = clean(node.getAttribute('aria-label') || node.getAttribute('data-e2e') || '');
            if (!keyword.test(label) && !keyword.test(clean(node.textContent))) continue;
            const value = number(clean(node.textContent));
            if (value) return value;
          }
          return null;
        };
        if (likes == null) likes = labeled(/点赞|digg|like/i);
        if (comments == null) comments = labeled(/评论|comment/i);
        if (collects == null) collects = labeled(/收藏|collect|favorite/i);
        if (source == null && [likes, comments, collects].some(value => value !== null)) source = 'detail_dom';
      }
      const counts = {likes, comments, collects, source, readAt: new Date().toISOString()};
      if ([likes, comments, collects].some(value => value !== null)) return reply('ready', counts);
      return reply('pending', counts);
    })()
    """#
      .replacingOccurrences(of: "__WORK_ID__", with: workID)
      .replacingOccurrences(of: "__AUTHOR_ID__", with: authorID)
  }

  private static func awemeItems(in root: [String: Any]) -> [[String: Any]] {
    let nest = (root["data"] as? [String: Any]) ?? root
    if let list = nest["aweme_list"] as? [[String: Any]] { return list }
    if let detail = nest["aweme_detail"] as? [String: Any] { return [detail] }
    if let detail = root["aweme_detail"] as? [String: Any] { return [detail] }
    return []
  }

  private static func projectItem(
    _ item: [String: Any],
    observedAt: String,
    source: String
  ) -> DouyinProfileMetricsProjection? {
    let workID = (item["aweme_id"] as? String) ?? (item["awemeId"] as? String) ?? ""
    guard workID.range(of: #"^\d{10,25}$"#, options: .regularExpression) != nil else { return nil }
    let author = item["author"] as? [String: Any] ?? [:]
    let authorID = (author["sec_uid"] as? String) ?? (author["secUid"] as? String) ?? ""
    guard !authorID.isEmpty else { return nil }
    let stats = item["statistics"] as? [String: Any] ?? [:]
    return DouyinProfileMetricsProjection(
      workID: workID,
      authorID: authorID,
      likes: count(stats["digg_count"] ?? stats["diggCount"]),
      comments: count(stats["comment_count"] ?? stats["commentCount"]),
      collects: count(stats["collect_count"] ?? stats["collectCount"]),
      observedAt: observedAt,
      source: source
    )
  }
}

struct DouyinProfileMetricsCache {
  private var items: [String: (projection: DouyinProfileMetricsProjection, storedAt: Date)] = [:]
  var ttl: TimeInterval = DouyinProfileMetricsCapture.cacheTTL

  mutating func store(_ projection: DouyinProfileMetricsProjection, now: Date = Date()) {
    let merged = DouyinProfileMetricsCapture.merging(items[projection.workID]?.projection, with: projection)
    items[projection.workID] = (merged, now)
  }

  func lookup(workID: String, authorID: String, now: Date = Date()) -> DouyinProfileMetricsProjection? {
    guard let entry = items[workID], now.timeIntervalSince(entry.storedAt) <= ttl,
          entry.projection.authorID == authorID
    else { return nil }
    return entry.projection
  }
}
