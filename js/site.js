/*
  汲作官网 · 页面脚本（2026-10-01）

  只做两件事，删掉这个文件页面照样完整可用：
  1. 下载按钮直达安装包。HTML 里所有下载按钮都指向 releases/latest（无 JS 时的退路）；
     这里向 GitHub 公开接口问一次最新版本，按芯片把按钮换成对应的 dmg，并写上版本号。
     之前按钮只跳发布页，dmg 下载数是 0：人到了发布页，不知道该点哪个文件。
  2. 演示动画按时间切换 data-step。HTML 默认停在最后一帧，所以脚本不跑、或系统要求
     减弱动态效果时，看到的就是完整结果。

  不加载任何第三方脚本。唯一的外部请求是 api.github.com，不带 Cookie、不带 Referer，
  隐私政策页写明了这一条。
*/
(function () {
  "use strict";

  var REPO = "Songxiaor/jizuo";
  var LATEST_PAGE = "https://github.com/" + REPO + "/releases/latest";
  var API = "https://api.github.com/repos/" + REPO + "/releases/latest";
  var CACHE_KEY = "jizuo-latest-release";
  // 未登录的 GitHub 接口每个 IP 每小时 60 次；同一次浏览里翻几页不必重复问。
  var CACHE_MS = 30 * 60 * 1000;

  var LABEL = { arm: "Apple 芯片版", intel: "Intel 芯片版", universal: "通用版" };

  /* ---------- 下载 ---------- */

  function isMac() {
    var ua = navigator.userAgent || "";
    // iPad 的 Safari 也自称 Macintosh，靠触点数区分。
    var iPad = navigator.maxTouchPoints > 1 && /Macintosh/.test(ua);
    return /Macintosh|Mac OS X/.test(ua) && !iPad;
  }

  // 返回 {arch: "arm"|"intel", sure: bool}。猜不出来就默认 Apple 芯片，并让按钮下的小字给出另外两种。
  function detectArch() {
    var fallback = { arch: "arm", sure: false };
    var uad = navigator.userAgentData;
    var viaHints = uad && uad.getHighEntropyValues
      ? uad.getHighEntropyValues(["architecture"]).then(function (v) {
          if (v.architecture === "arm") return { arch: "arm", sure: true };
          if (v.architecture === "x86") return { arch: "intel", sure: true };
          return null;
        }, function () { return null; })
      : Promise.resolve(null);

    return viaHints.then(function (r) {
      if (r) return r;
      // Safari、Firefox 没有 userAgentData，UA 一律写着 Intel。退而看显卡名：
      // Apple 芯片会报出「Apple M1」之类；Safari 有时只报「Apple GPU」，那就算不确定。
      try {
        var canvas = document.createElement("canvas");
        var gl = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
        if (!gl) return fallback;
        var ext = gl.getExtension("WEBGL_debug_renderer_info");
        var name = String(gl.getParameter(ext ? ext.UNMASKED_RENDERER_WEBGL : gl.RENDERER) || "");
        var lose = gl.getExtension("WEBGL_lose_context");
        if (lose) lose.loseContext();
        if (/Apple M\d/.test(name)) return { arch: "arm", sure: true };
        if (/Intel|AMD|Radeon|NVIDIA|GeForce/i.test(name)) return { arch: "intel", sure: true };
      } catch (e) { /* 拿不到就按默认 */ }
      return fallback;
    });
  }

  function readCache() {
    try {
      var raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var c = JSON.parse(raw);
      return Date.now() - c.at < CACHE_MS ? c.data : null;
    } catch (e) { return null; }
  }

  function writeCache(data) {
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data: data })); } catch (e) { /* 无痕模式可能禁用存储 */ }
  }

  function fetchRelease() {
    var cached = readCache();
    if (cached) return Promise.resolve(cached);
    if (!window.fetch) return Promise.reject(new Error("no fetch"));
    return fetch(API, { credentials: "omit", referrerPolicy: "no-referrer", cache: "no-cache" })
      .then(function (res) {
        if (!res.ok) throw new Error("GitHub " + res.status);
        return res.json();
      })
      .then(function (json) {
        var files = {};
        (json.assets || []).forEach(function (a) {
          var n = a.name || "";
          if (/Apple-Silicon\.dmg$/i.test(n)) files.arm = a.browser_download_url;
          else if (/Intel\.dmg$/i.test(n)) files.intel = a.browser_download_url;
          else if (/Universal\.(zip|dmg)$/i.test(n)) files.universal = a.browser_download_url;
        });
        var data = { version: json.tag_name || "", files: files };
        if (data.files.arm || data.files.intel || data.files.universal) writeCache(data);
        return data;
      });
  }

  function link(href, text) {
    var a = document.createElement("a");
    a.href = href;
    a.textContent = text;
    return a;
  }

  function applyDownloads(rel, det) {
    var v = rel.version ? " · " + rel.version : "";
    var mac = isMac();
    var arch = rel.files[det.arch] ? det.arch : (rel.files.arm ? "arm" : (rel.files.universal ? "universal" : null));
    if (!arch) return; // 发布里没找到认得的安装包，保持跳发布页

    var main = mac ? rel.files[arch] : LATEST_PAGE;

    document.querySelectorAll("[data-dl]").forEach(function (a) {
      a.href = main;
      if (a.getAttribute("data-dl") === "short") {
        a.textContent = "下载" + (rel.version ? " " + rel.version : "");
      } else {
        a.textContent = mac ? "下载 " + LABEL[arch] + v : "下载 macOS 版" + v;
      }
    });

    // 按钮下的小字：另外两种安装包。猜不准时说明默认给的是哪一种。
    document.querySelectorAll("[data-dl-alt]").forEach(function (p) {
      p.textContent = "";
      if (!mac) {
        p.appendChild(document.createTextNode("汲作目前只有 macOS 版，请在 Mac 上打开本页下载。"));
      } else {
        p.appendChild(document.createTextNode(det.sure ? "芯片不对？换成 " : "默认给 Apple 芯片版，也可以选 "));
        var others = [];
        if (arch !== "arm" && rel.files.arm) others.push(link(rel.files.arm, "Apple 芯片版"));
        if (arch !== "intel" && rel.files.intel) others.push(link(rel.files.intel, "Intel 芯片版"));
        if (rel.files.universal) others.push(link(rel.files.universal, det.sure ? "通用版" : "不确定（通用版）"));
        others.forEach(function (a, i) {
          if (i) p.appendChild(document.createTextNode(" · "));
          p.appendChild(a);
        });
      }
      p.hidden = false;
    });

    // 安装第一步的三行：各自直达对应文件，推荐的那行标出来。
    document.querySelectorAll("[data-pkg]").forEach(function (row) {
      var kind = row.getAttribute("data-pkg");
      if (rel.files[kind]) row.href = rel.files[kind];
      if (mac && kind === arch) {
        row.classList.add("is-rec");
        var b = row.querySelector("b");
        if (b && !b.querySelector(".rec")) {
          var em = document.createElement("em");
          em.className = "rec";
          em.textContent = det.sure ? "适合这台 Mac" : "默认推荐";
          b.appendChild(em);
        }
      }
    });
  }

  Promise.all([fetchRelease(), detectArch()])
    .then(function (r) { applyDownloads(r[0], r[1]); })
    .catch(function () { /* 接口失败：按钮保持指向 releases/latest */ });

  /* ---------- 演示 ---------- */

  var demo = document.querySelector(".demo");
  if (!demo) return;

  // 每一步开始的时刻（毫秒），一轮 24 秒。0–3 浏览器，4 列表出现，5 转写，6 校对，7 总结，8 停留。
  var STEPS = [0, 1300, 2600, 4700, 6600, 8700, 12000, 14800, 17200];
  var LOOP = 24000;
  var TICK = 100;
  var reduce = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var toggle = demo.querySelector(".demo-toggle");
  var t = 0, timer = null, visible = false, paused = false;

  function capFor(step) { return step <= 3 ? 1 : step === 4 ? 2 : step <= 6 ? 3 : 4; }

  function show(step) {
    var s = String(step);
    if (demo.getAttribute("data-step") === s) return;
    demo.setAttribute("data-step", s);
    demo.setAttribute("data-cap", String(capFor(step)));
  }

  function stepAt(ms) {
    var s = 0;
    for (var i = 0; i < STEPS.length; i++) if (ms >= STEPS[i]) s = i;
    return s;
  }

  function tick() {
    t = (t + TICK) % LOOP;
    show(stepAt(t));
  }

  function sync() {
    var still = reduce && reduce.matches;
    if (toggle) toggle.hidden = !!still;
    if (still) {
      // 减弱动态效果：停在最后一帧，不播。
      if (timer) { clearInterval(timer); timer = null; }
      show(8);
      return;
    }
    var run = visible && !paused && !document.hidden;
    if (run && !timer) timer = setInterval(tick, TICK);
    if (!run && timer) { clearInterval(timer); timer = null; }
  }

  if (!(reduce && reduce.matches)) { t = 0; show(0); }

  if (toggle) {
    toggle.addEventListener("click", function () {
      paused = !paused;
      toggle.textContent = paused ? "播放" : "暂停";
      toggle.setAttribute("aria-pressed", paused ? "true" : "false");
      sync();
    });
  }

  // 滚出视野就停，回来接着播，不在看不见的地方空转。
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
      sync();
    }, { threshold: 0.25 }).observe(demo);
  } else {
    visible = true;
  }
  document.addEventListener("visibilitychange", sync);
  if (reduce) {
    if (reduce.addEventListener) reduce.addEventListener("change", sync);
    else if (reduce.addListener) reduce.addListener(sync);
  }
  sync();
})();
