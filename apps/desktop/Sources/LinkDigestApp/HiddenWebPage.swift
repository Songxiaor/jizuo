import WebKit

/// 汲作在屏幕外的隐藏网页里抓正文、读评论。系统把这种网页当成「看不见」：
/// 动画帧（requestAnimationFrame）一次都不触发，「滚到眼前」（IntersectionObserver）也不通知。
/// 靠它们分批渲染的页面就只出来开头几条——YouTube 评论区在 App 里只渲染 2 条，
/// 扩展在可见标签页里是 20 条（2026-10-02 实测）。
///
/// 这里只给汲作自己的隐藏网页换成计时器驱动的版本，不影响用户看到的任何网页。
enum HiddenWebPage {
  static func prepare(_ configuration: WKWebViewConfiguration) {
    // 别让系统再给隐藏网页的计时器降频：下面两个替身都靠计时器跑。
    configuration.preferences.inactiveSchedulingPolicy = .none
    configuration.userContentController.addUserScript(WKUserScript(
      source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
    ))
  }

  static let shimSource = """
    (() => {
      const frames = new Map(); let nextFrame = 1;
      window.requestAnimationFrame = (callback) => {
        const id = nextFrame++;
        frames.set(id, setTimeout(() => { frames.delete(id); callback(performance.now()); }, 16));
        return id;
      };
      window.cancelAnimationFrame = (id) => { clearTimeout(frames.get(id)); frames.delete(id); };
      if (!window.IntersectionObserver) return;
      // 每 120 毫秒量一次位置，进出视口时照原接口回调。rootMargin 只认第一个像素值。
      class PollingIntersectionObserver {
        constructor(callback, options = {}) {
          this.callback = callback; this.root = options.root || null;
          this.margin = parseFloat(options.rootMargin || "0") || 0;
          this.targets = new Map(); this.timer = null;
        }
        observe(target) { if (!this.targets.has(target)) { this.targets.set(target, null); this.schedule(0); } }
        unobserve(target) { this.targets.delete(target); }
        disconnect() { this.targets.clear(); clearTimeout(this.timer); this.timer = null; }
        takeRecords() { return []; }
        schedule(delay) {
          if (this.timer) return;
          this.timer = setTimeout(() => { this.timer = null; this.check(); if (this.targets.size) this.schedule(120); }, delay);
        }
        check() {
          const base = this.root ? this.root.getBoundingClientRect() : { top: 0, left: 0, bottom: innerHeight, right: innerWidth };
          const m = this.margin;
          const rootBounds = { top: base.top - m, left: base.left - m, bottom: base.bottom + m, right: base.right + m };
          const entries = [];
          for (const [target, was] of this.targets) {
            const rect = target.getBoundingClientRect();
            const width = Math.max(0, Math.min(rect.right, rootBounds.right) - Math.max(rect.left, rootBounds.left));
            const height = Math.max(0, Math.min(rect.bottom, rootBounds.bottom) - Math.max(rect.top, rootBounds.top));
            const area = rect.width * rect.height;
            const touches = target.isConnected && rect.bottom >= rootBounds.top && rect.top <= rootBounds.bottom
              && rect.right >= rootBounds.left && rect.left <= rootBounds.right;
            const isIntersecting = touches && (area === 0 || width * height > 0);
            if (was === isIntersecting) continue;
            this.targets.set(target, isIntersecting);
            entries.push({
              target, isIntersecting, time: performance.now(), boundingClientRect: rect, rootBounds,
              intersectionRatio: area > 0 ? (width * height) / area : (isIntersecting ? 1 : 0),
              intersectionRect: { top: Math.max(rect.top, rootBounds.top), left: Math.max(rect.left, rootBounds.left), width, height },
            });
          }
          if (entries.length) this.callback(entries, this);
        }
      }
      window.IntersectionObserver = PollingIntersectionObserver;
    })();
    """
}
