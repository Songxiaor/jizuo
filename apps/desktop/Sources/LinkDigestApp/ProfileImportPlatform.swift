import Foundation
import WebKit

/// Profile discovery uses only the current platform's rendered page and isolated session.
enum ProfileImportPlatform: String, CaseIterable, Identifiable {
  case douyin, xiaohongshu, x, bilibili
  var id: String { rawValue }

  var displayName: String {
    switch self { case .douyin: "抖音"; case .xiaohongshu: "小红书"; case .x: "X"; case .bilibili: "B 站" }
  }
  var host: String {
    switch self { case .douyin: "douyin.com"; case .xiaohongshu: "xiaohongshu.com"; case .x: "x.com"; case .bilibili: "bilibili.com" }
  }

  private static let sessionAccessQueryNames: Set<String> = ["xsec_token", "xsec_source"]
  private static let reservedXHandles: Set<String> = [
    "home", "explore", "search", "i", "settings", "login", "logout", "intent", "signup",
    "notifications", "messages", "compose", "tos", "privacy",
  ]

  static func safe(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
  }

  static func registeredHost(_ url: URL) -> String? {
    guard safe(url), var host = url.host?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    return host
  }

  static func fromShortLink(_ url: URL) -> Self? {
    guard let host = registeredHost(url) else { return nil }
    if host == "v.douyin.com" { return .douyin }
    if host == "xhslink.com" || host == "xhslink.cn" { return .xiaohongshu }
    if host == "b23.tv" { return .bilibili }
    return nil
  }

  static func fromProfileURL(_ url: URL) -> Self? {
    guard safe(url), let host = url.host?.lowercased() else { return nil }
    let path = pathParts(url)
    if Self.host(host, ["douyin.com", "m.douyin.com", "iesdouyin.com", "www.iesdouyin.com"]) {
      if isDouyinAuthorPath(path) { return .douyin }
    }
    if Self.host(host, ["xiaohongshu.com", "m.xiaohongshu.com"]), isXiaohongshuProfilePath(path) {
      return .xiaohongshu
    }
    if Self.host(host, ["x.com", "twitter.com", "mobile.twitter.com", "m.twitter.com"]), isXProfilePath(path) {
      return .x
    }
    if host == "space.bilibili.com", isBilibiliSpacePath(path) { return .bilibili }
    if host == "m.bilibili.com", isBilibiliMobileSpacePath(path) { return .bilibili }
    return nil
  }

  static func parse(_ input: String) -> DouyinProfileInputRoute? {
    guard var url = ExplicitWebLinkInput.singleURL(from: input) else { return nil }
    // Mobile share text may use HTTP for a known short-link host; never send it over HTTP.
    if url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
       url.port == nil || url.port == 80,
       ["v.douyin.com", "xhslink.com", "xhslink.cn", "b23.tv"].contains(url.host?.lowercased() ?? "") {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.scheme = "https"; components.port = nil
      guard let upgraded = components.url else { return nil }
      url = upgraded
    }
    guard safe(url) else { return nil }
    if let platform = fromShortLink(url) {
      return .shortLink(platform: platform, sourceURL: url)
    }
    guard let platform = fromProfileURL(url), let author = platform.authorID(url) else { return nil }
    return .profile(
      platform: platform,
      sourceURL: platform.navigationProfileURL(authorID: author, retaining: url),
      authorID: author
    )
  }

  func authorID(_ url: URL) -> String? {
    guard Self.fromProfileURL(url) == self else { return nil }
    let path = Self.pathParts(url)
    switch self {
    case .douyin:
      return path[0].lowercased() == "share" ? path[2] : path[1]
    case .xiaohongshu:
      return path[2]
    case .x:
      return path[0].lowercased()
    case .bilibili:
      return path[0].lowercased() == "space" ? path[1] : path[0]
    }
  }

  func canonicalProfileURL(authorID: String) -> URL {
    switch self {
    case .douyin: URL(string: "https://www.douyin.com/user/\(authorID)")!
    case .xiaohongshu: URL(string: "https://www.xiaohongshu.com/user/profile/\(authorID)")!
    case .x: URL(string: "https://x.com/\(authorID)")!
    case .bilibili: URL(string: "https://space.bilibili.com/\(authorID)/upload/video")!
    }
  }

  func navigationProfileURL(authorID: String, retaining original: URL) -> URL {
    var components = URLComponents(url: canonicalProfileURL(authorID: authorID), resolvingAgainstBaseURL: false)!
    let kept = URLComponents(url: original, resolvingAgainstBaseURL: false)?
      .queryItems?
      .filter { Self.sessionAccessQueryNames.contains($0.name) && !($0.value ?? "").isEmpty }
      ?? []
    if !kept.isEmpty { components.queryItems = kept }
    return components.url!
  }

  static func fromWorkURL(_ url: URL) -> Self? {
    guard safe(url), let host = url.host?.lowercased() else { return nil }
    let path = pathParts(url)
    if Self.host(host, ["douyin.com", "m.douyin.com", "iesdouyin.com", "www.iesdouyin.com"]),
       douyinWork(path) != nil {
      return .douyin
    }
    if Self.host(host, ["xiaohongshu.com", "m.xiaohongshu.com"]), xiaohongshuWorkID(path) != nil {
      return .xiaohongshu
    }
    if Self.host(host, ["x.com", "twitter.com", "mobile.twitter.com", "m.twitter.com"]),
       path.count == 3, isXHandle(path[0]), path[1].lowercased() == "status", isDigits(path[2]) {
      return .x
    }
    if Self.host(host, ["bilibili.com", "m.bilibili.com"]),
       path.count == 2, path[0].lowercased() == "video", isBilibiliBV(path[1]) {
      return .bilibili
    }
    return nil
  }

  static func canonicalWork(_ url: URL) -> String? {
    guard let platform = fromWorkURL(url) else { return nil }
    let path = pathParts(url)
    switch platform {
    case .douyin:
      return DouyinProfileWorkURL.canonical(url)
    case .xiaohongshu:
      guard let id = xiaohongshuWorkID(path) else { return nil }
      return "https://www.xiaohongshu.com/explore/" + id
    case .x:
      return "https://x.com/" + path[0].lowercased() + "/status/" + path[2]
    case .bilibili:
      return "https://www.bilibili.com/video/" + path[1]
    }
  }

  @MainActor var session: SiteSessionController {
    switch self {
    case .douyin: .douyin
    case .xiaohongshu: .xiaohongshu
    case .bilibili: .bilibili
    case .x: .x
    }
  }

  @MainActor func allowsNavigation(_ url: URL?) -> Bool {
    guard let url, Self.safe(url) else { return false }
    if Self.fromShortLink(url) == self { return true }
    return session.profile.isAllowedHost(url.host)
  }

  private static func pathParts(_ url: URL) -> [String] {
    url.pathComponents.filter { $0 != "/" }
  }

  private static func host(_ host: String, _ names: [String]) -> Bool {
    let registered = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return names.contains(host) || names.contains(registered)
  }

  private static func isDouyinAuthorPath(_ path: [String]) -> Bool {
    if path.count == 2, path[0].lowercased() == "user" { return isDouyinAuthor(path[1]) }
    if path.count == 3, path[0].lowercased() == "share", path[1].lowercased() == "user" {
      return isDouyinAuthor(path[2])
    }
    return false
  }

  private static func isXiaohongshuProfilePath(_ path: [String]) -> Bool {
    path.count == 3 && path[0].lowercased() == "user" && path[1].lowercased() == "profile" && isXiaohongshuUser(path[2])
  }

  private static func isXProfilePath(_ path: [String]) -> Bool {
    path.count == 1 && isXHandle(path[0])
  }

  private static func isBilibiliSpacePath(_ path: [String]) -> Bool {
    guard let uid = path.first, isBilibiliUID(uid) else { return false }
    if path.count == 1 { return true }
    if path.count == 2 { return path[1].lowercased() == "upload" }
    if path.count == 3 { return path[1].lowercased() == "upload" && path[2].lowercased() == "video" }
    return false
  }

  private static func isBilibiliMobileSpacePath(_ path: [String]) -> Bool {
    path.count == 2 && path[0].lowercased() == "space" && isBilibiliUID(path[1])
  }

  private static func douyinWork(_ path: [String]) -> (kind: String, id: String)? {
    if path.count >= 2, ["video", "note"].contains(path[0].lowercased()), isDouyinWorkID(path[1]) {
      return (path[0].lowercased(), path[1])
    }
    if path.count >= 3, path[0].lowercased() == "share",
       ["video", "note"].contains(path[1].lowercased()), isDouyinWorkID(path[2]) {
      return (path[1].lowercased(), path[2])
    }
    return nil
  }

  private static func xiaohongshuWorkID(_ path: [String]) -> String? {
    if path.count == 2, path[0].lowercased() == "explore", isXiaohongshuUser(path[1]) { return path[1] }
    if path.count == 3, path[0].lowercased() == "discovery", path[1].lowercased() == "item", isXiaohongshuUser(path[2]) {
      return path[2]
    }
    if path.count == 4, path[0].lowercased() == "user", path[1].lowercased() == "profile",
       isXiaohongshuUser(path[2]), isXiaohongshuUser(path[3]) {
      return path[3]
    }
    return nil
  }

  private static func isDouyinAuthor(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
  }

  private static func isDouyinWorkID(_ value: String) -> Bool {
    value.count >= 10 && value.allSatisfy(\.isNumber)
  }

  private static func isXiaohongshuUser(_ value: String) -> Bool {
    value.range(of: #"^[a-fA-F0-9]{24}$"#, options: .regularExpression) != nil
  }

  private static func isXHandle(_ value: String) -> Bool {
    let handle = value.lowercased()
    return handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil
      && !reservedXHandles.contains(handle)
  }

  private static func isBilibiliUID(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy(\.isNumber)
  }

  private static func isBilibiliBV(_ value: String) -> Bool {
    value.range(of: #"^BV[A-Za-z0-9]{10}$"#, options: .regularExpression) != nil
  }

  private static func isDigits(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy(\.isNumber)
  }

  var discoveryScript: String {
    Self.commonScript.replacingOccurrences(of: "__PLATFORM__", with: rawValue)
  }
  var advanceScript: String {
    if self == .bilibili {
      return #"""
      (() => {
        const next = Array.from(document.querySelectorAll('button')).find(n => /下一页|next/i.test(n.textContent || '') && n.closest('.vui_pagenation, .vui_pagination, .be-pager, [class*="pagination"], [class*="pagenation"]'));
        if (next && !next.disabled && next.getAttribute('aria-disabled') !== 'true' && !/disabled/.test(next.className)) { next.click(); return 'next'; }
        window.scrollBy(0, Math.max(400, innerHeight * .8)); return 'scroll';
      })()
      """#
    }
    return "window.scrollBy(0, Math.max(400, innerHeight * .8))"
  }

  // DOM scopes are deliberately platform-specific. Missing roots fail closed.
  private static let commonScript = #"""
  (() => {
    const platform = '__PLATFORM__';
    const clean = v => String(v || '').replace(/\s+/g,' ').trim();
    const visible = n => !!n && !n.closest('[hidden], [aria-hidden="true"]') && getComputedStyle(n).display !== 'none' && getComputedStyle(n).visibility !== 'hidden' && n.getBoundingClientRect().width > 0 && n.getBoundingClientRect().height > 0;
    const resolvedName = (raw, authorID) => {
      const name = clean(raw);
      if (!name) return null;
      const stripped = name.replace(/^@/, '');
      if (authorID && stripped.toLowerCase() === String(authorID).toLowerCase()) return null;
      return name.slice(0, 80);
    };
    const resolveSrc = node => {
      if (!node) return null;
      const raw = node.currentSrc || node.getAttribute('src') || node.getAttribute('data-src');
      if (!raw) return null;
      try { return new URL(raw, location.href).href; } catch { return null; }
    };
    const headerOwned = n => n && visible(n) && !n.closest('article, section.note-item, .upload-video-card, li.small-item, aside, nav, [data-testid="tweet"], .bili-header, #internationalHeader');
    const headerAvatar = (candidates) => resolveSrc(candidates.find(headerOwned));
    const parseCount = raw => {
      const s = String(raw || '');
      if (/查看|浏览|views?|analy/i.test(s) && !/喜欢|like|回复|repl|书签|bookmark/i.test(s)) return null;
      const m = s.match(/^\s*(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)(?:\s*(万|亿|千|[kKmMbB](?![A-Za-z])))?/);
      return m ? (m[1] + (m[2] || '')) : null;
    };
    const parseNamedInLabel = (label, want) => {
      const s = String(label || '');
      if (!want.test(s)) return null;
      const num = '(\\d{1,3}(?:,\\d{3})+|\\d+(?:\\.\\d+)?)\\s*(万|亿|千|[kKmMbB](?![A-Za-z]))?';
      const verb = want.source;
      let m = s.match(new RegExp(num + '\\s*(?:次)?\\s*(?:' + verb + ')', 'i'));
      if (m) return parseCount(m[1] + (m[2] || ''));
      m = s.match(new RegExp('(?:' + verb + ')\\s*(?:次)?\\s*' + num, 'i'));
      if (m) return parseCount(m[1] + (m[2] || ''));
      return null;
    };
    const xAria = n => {
      const own = n.getAttribute('aria-label');
      if (own) return own;
      const inner = Array.from(n.querySelectorAll('[aria-label]')).map(el => el.getAttribute('aria-label') || '')
        .find(lab => lab && !/查看|浏览|views?|analy|转帖|repost|retweet/i.test(lab));
      return inner || '';
    };
    const xMetric = (card, ids, kind) => {
      const want = kind === 'reply' ? /回复|repl(?:y|ies)/i : kind === 'like' ? /喜欢|likes?/i : /书签|bookmarks?/i;
      const reject = /查看|浏览|views?|analy|转帖|repost|retweet|分享帖子|share post/i;
      // Same quote scope as owner header / tweetText: quoteTweet or role=link cards.
      const outsideQuote = n => !n.closest('[data-testid="quoteTweet"],[role="link"]');
      let node = Array.from(card.querySelectorAll(ids.map(id => '[data-testid="'+id+'"]').join(','))).find(outsideQuote);
      let lab = node ? xAria(node) : '';
      if (!parseCount(lab)) {
        const alt = Array.from(card.querySelectorAll('button,[role="button"]')).find(n => {
          if (!outsideQuote(n)) return false;
          const a = n.getAttribute('aria-label') || '';
          return a && want.test(a) && !reject.test(a) && parseCount(a) !== null;
        });
        if (alt) { node = alt; lab = alt.getAttribute('aria-label') || ''; }
      }
      const fromButton = (!lab || (reject.test(lab) && !want.test(lab))) ? null : parseCount(lab);
      if (fromButton !== null) return fromButton;
      const group = Array.from(card.querySelectorAll('[role="group"][aria-label]')).find(outsideQuote);
      return group ? parseNamedInLabel(group.getAttribute('aria-label') || '', want) : null;
    };
    const text = clean(document.body?.innerText);
    const path = location.pathname.split('/').filter(Boolean);
    const author = platform === 'xiaohongshu' ? path[2] : (path[0] || '').toLowerCase();
    const result = {status:'missing_root',profileAuthorID:author,profileName:null,profileAvatarURL:null,activeTab:null,candidates:[]};
    if (/完成验证|安全验证|人机验证|异常访问/.test(text) || Array.from(document.querySelectorAll('[class*="captcha"],[id*="captcha"]')).some(visible)) {result.status='verification';return JSON.stringify(result);}
    const login = Array.from(document.querySelectorAll('.login-container,.login-modal')).some(visible)
      || Array.from(document.querySelectorAll('[role="dialog"]')).some(n => visible(n) && /登录|Log in|Sign in/.test(n.innerText));
    // Header first: a visible login wall must not discard a public name/avatar.
    if (platform === 'xiaohongshu') {
      result.profileName = resolvedName(document.querySelector('.user-page .user-name')?.textContent, author);
      const node = document.querySelector('.user-page .user-info .user-image');
      const img = node && node.tagName === 'IMG' ? node : (node && node.querySelector('img'));
      result.profileAvatarURL = headerAvatar([img]);
    } else if (platform === 'bilibili') {
      const nick = Array.from(document.querySelectorAll('.nickname')).find(headerOwned);
      result.profileName = resolvedName(nick && nick.textContent, author);
      result.profileAvatarURL = headerAvatar(Array.from(document.querySelectorAll('.upinfo-avatar img')));
    } else if (platform === 'x') {
      // Comma selectors match document order, so a leading keyboard-shortcut h2
      // must not beat the profile header. Never borrow tweet/quote User-Name.
      const nameRoot = document.querySelector('main [data-testid="UserName"],[role="main"] [data-testid="UserName"]');
      const pageTitle = document.title || '';
      const marker = pageTitle.toLowerCase().indexOf('(@' + author + ')');
      const titleName = marker > 0 ? pageTitle.slice(0, marker).trim() : ('@' + author);
      const token = '@' + author;
      const paren = '(' + token + ')';
      let profileName = clean(nameRoot && nameRoot.textContent) || titleName;
      for (;;) {
        const lower = profileName.toLowerCase();
        if (lower.endsWith(paren)) { profileName = profileName.slice(0, profileName.length - paren.length).trim(); continue; }
        if (lower.endsWith(token)) { profileName = profileName.slice(0, profileName.length - token.length).trim(); continue; }
        break;
      }
      if (!profileName) profileName = titleName;
      result.profileName = resolvedName(profileName, author);
      const photoPath = '/' + author + '/photo';
      let photoImg = document.querySelector('main a[href="' + photoPath + '"] img');
      if (!photoImg) {
        const link = Array.from(document.querySelectorAll('main a[href]')).find(a => {
          try {
            return new URL(a.getAttribute('href') || '', location.href).pathname.replace(/\/$/, '').toLowerCase() === photoPath;
          } catch { return false; }
        });
        photoImg = link && link.querySelector('img');
      }
      const preferred = author ? document.querySelector('main [data-testid="UserAvatar-Container-' + author + '"] img') : null;
      result.profileAvatarURL = headerAvatar([photoImg, preferred]);
    }
    if (login) { result.status = 'login'; return JSON.stringify(result); }
    let root, cards = [];
    if (platform === 'xiaohongshu') {
      root = document.querySelector('.user-page .feeds-container');
      const tab = document.querySelector('.user-page [aria-selected="true"],.user-page .reds-tab-item.active,.user-page .reds-tab-item.is-active');
      if (tab && /收藏|赞过/.test(tab.textContent)) {result.status='wrong_tab';return JSON.stringify(result);}
      cards = root ? Array.from(root.querySelectorAll('section.note-item')) : [];
    } else if (platform === 'bilibili') {
      if (!/\/upload\/video\/?$/.test(location.pathname)) {result.status='wrong_tab';return JSON.stringify(result);}
      root = document.querySelector('main .upload-content .video-list, #submit-video-list');
      cards = root ? Array.from(root.querySelectorAll('.upload-video-card,li.small-item')) : [];
    } else {
      root = document.querySelector('main,[role="main"]');
      cards = root ? Array.from(root.querySelectorAll('article')).filter(n => !n.parentElement.closest('article')) : [];
      const tab = document.querySelector('[role="tab"][aria-selected="true"]');
      if (tab && /Replies|Reposts|回复|转帖|喜欢|Likes/.test(tab.textContent)) {result.status='wrong_tab';return JSON.stringify(result);}
    }
    if (!root) {
      result.status = platform === 'x' ? 'missing_root' : (/登录后|登录即可|Log in to|Sign in to/.test(text) ? 'login' : 'missing_root');
      return JSON.stringify(result);
    }
    const seen = new Set();
    for (const card of cards) {
      if (!visible(card) || card.closest('aside,nav,[class*="recommend"]')) continue;
      let a, url, id, previewText = null, publishedText = null, likes = null, comments = null, collects = null;
      if (platform === 'x') {
        if (card.querySelector('[data-testid="placementTracking"],[data-testid="promotedIndicator"]')) continue;
        if (card.closest('[data-testid="placementTracking"],[data-testid="promotedIndicator"]')) continue;
        const social = card.querySelector('[data-testid="socialContext"]');
        if (social && /repost|转帖|转发/i.test(social.textContent || '')) continue;
        // The main header owns the post. Never search a quoted card for a matching author.
        const header = Array.from(card.querySelectorAll('[data-testid="User-Name"]')).find(n => !n.closest('[role="link"],[data-testid="quoteTweet"]'));
        if (!header) continue;
        const time = header.querySelector('time');
        a = time && time.closest('a[href]');
        if (!a) continue;
        url = new URL(a.href, location.href);
        if (url.protocol !== 'https:' || !['x.com','www.x.com','twitter.com','www.twitter.com'].includes(url.hostname)) continue;
        const m = url.pathname.match(/^\/([A-Za-z0-9_]+)\/status\/(\d{8,25})\/?$/);
        if (!m || m[1].toLowerCase() !== author) continue;
        id = m[2];
        url = new URL('https://x.com/' + author + '/status/' + id);
        const mainText = Array.from(card.querySelectorAll('[data-testid="tweetText"]')).find(n => !n.closest('[role="link"],[data-testid="quoteTweet"]'));
        previewText = clean(mainText && mainText.textContent) || null;
        if (!previewText) {
          const statusOf = href => {
            try {
              const u = new URL(href, location.href);
              const sm = u.pathname.match(/^\/([A-Za-z0-9_]+)\/status\/(\d{8,25})\/?$/);
              return sm ? { handle: sm[1].toLowerCase(), id: sm[2] } : null;
            } catch { return null; }
          };
          const linkIsThisPost = link => {
            const hrefs = [];
            const own = link.getAttribute('href');
            if (own) hrefs.push(own);
            Array.from(link.querySelectorAll('a[href]')).forEach(el => hrefs.push(el.getAttribute('href')));
            let thisPost = false, other = false;
            for (const href of hrefs) {
              const st = statusOf(href);
              if (!st) continue;
              if (st.handle === author && st.id === id) thisPost = true;
              else other = true;
            }
            return thisPost && !other;
          };
          const heading = Array.from(card.querySelectorAll('[data-testid="twitter-article-title"],[data-testid="twitterArticleTitle"],h1,h2,[role="heading"]')).find(n => {
            if (n.closest('[data-testid="quoteTweet"],[data-testid="User-Name"],[data-testid="UserName"]')) return false;
            const t = clean(n.textContent);
            if (t.length < 8 || t.length > 200 || /^(文章|Article|已置顶|Pinned)$/i.test(t)) return false;
            const link = n.closest('[role="link"]');
            if (link && !linkIsThisPost(link)) return false;
            return true;
          });
          previewText = heading ? clean(heading.textContent).slice(0, 200) : null;
        }
        if (!previewText) {
          const cover = Array.from(card.querySelectorAll('[data-testid="article-cover-image"]')).find(n =>
            !n.closest('[data-testid="quoteTweet"],[role="link"],[data-testid="User-Name"],[data-testid="UserName"]')
          );
          const box = cover && cover.nextElementSibling;
          if (box) {
            const dirs = Array.from(box.querySelectorAll('[dir="auto"]'));
            const title = dirs[0] ? clean(dirs[0].textContent) : '';
            if (title.length >= 8 && title.length <= 200 && !/^(文章|Article|已置顶|Pinned)$/i.test(title)) {
              previewText = title.slice(0, 200);
            }
          }
        }
        publishedText = clean(time && time.textContent) || null;
        comments = xMetric(card, ['reply'], 'reply');
        likes = xMetric(card, ['like', 'unlike'], 'like');
        collects = xMetric(card, ['bookmark', 'removeBookmark'], 'bookmark');
      } else if (platform === 'xiaohongshu') {
        const links = Array.from(card.querySelectorAll('a[href]'));
        const workLinks = links.filter(n => /\/(?:explore|discovery\/item)\/[a-fA-F0-9]{24}(?:\/|$)|^\/user\/profile\/[a-fA-F0-9]{24}\/[a-fA-F0-9]{24}\/?$/.test(new URL(n.href,location.href).pathname));
        a = workLinks.find(n => new URL(n.href,location.href).searchParams.get('xsec_token')) || workLinks[0];
        if (!a) continue;
        url = new URL(a.href,location.href);
        const m = url.pathname.match(/\/(?:explore|discovery\/item)\/([a-fA-F0-9]{24})(?:\/|$)/) ||
                  url.pathname.match(/^\/user\/profile\/[a-fA-F0-9]{24}\/([a-fA-F0-9]{24})\/?$/);
        if (!m || !/(^|\.)xiaohongshu\.com$/.test(url.hostname)) continue;
        id=m[1];
        url.pathname='/explore/'+id;
        const owner=card.querySelector('a.author');
        if (owner && new URL(owner.href,location.href).pathname.split('/').filter(Boolean)[2] !== author) continue;
      } else {
        a=card.querySelector('a[href*="/video/BV"]');if(!a)continue;
        url=new URL(a.href,location.href);
        const m=url.pathname.match(/^\/video\/(BV[A-Za-z0-9]{10})\/?$/);
        if(!m || !/(^|\.)bilibili\.com$/.test(url.hostname))continue;
        id=m[1];url=new URL('https://www.bilibili.com/video/'+id);
      }
      if(seen.has(id))continue;seen.add(id);
      const img=Array.from(card.querySelectorAll('img')).find(n => !/avatar|profile_images/.test(n.className+' '+n.src));
      const title=card.querySelector('[data-testid="tweetText"],.title,.bili-video-card__title');
      const preview=previewText || (platform === 'x' ? null : clean(title?.textContent || card.innerText || img?.alt));
      result.candidates.push({url:url.href,authorID:author,previewText:preview||null,coverURL:img?.currentSrc||img?.src||null,publishedText:publishedText || clean(card.querySelector('time')?.textContent)||null,likes,comments,collects});
    }
    if (platform === 'x') {
      result.status = (result.candidates.length || cards.length) ? 'ready' : 'missing_root';
    } else {
      result.status = result.candidates.length===0 && /登录后|登录即可|Log in to|Sign in to/.test(text) ? 'login' : (cards.length || /暂无投稿|还没有发布|还没有笔记|hasn.t posted/.test(text) ? 'ready' : 'missing_root');
    }
    return JSON.stringify(result);
  })()
  """#
}
