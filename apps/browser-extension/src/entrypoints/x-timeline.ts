import { tweetIDFromArticle } from "../content/x-bookmarks";

/**
 * 时间线就地同步：在 X 每条帖子的操作栏（收藏键左边）注入一个「→App」按钮，
 * 点一下把这条推文直接同步到桌面 App——不必再点开帖子。
 *
 * 这是扩展的第一个常驻 content script，仅在 x.com / twitter.com 运行；只读 DOM
 * 和注入按钮，不碰 cookie、不发额外请求。真正的抓取由 background 走 native
 * message 交给 App（复用单条同步能力）。
 */

const BUTTON_CLASS = "linkdigest-sync-button";

function buildButton(): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = BUTTON_CLASS;
  button.setAttribute("aria-label", "同步到 LinkDigest");
  button.title = "同步到 LinkDigest";
  // 与 X 原生操作图标同尺寸的圆形按钮；配色跟随扩展品牌绿。
  button.innerHTML =
    "<span class='ld-ico' aria-hidden='true'>L</span><span class='ld-tip' aria-hidden='true'></span>";
  return button;
}

function injectStyles(): void {
  if (document.getElementById("linkdigest-timeline-style")) return;
  const style = document.createElement("style");
  style.id = "linkdigest-timeline-style";
  style.textContent = `
    .${BUTTON_CLASS}{
      display:inline-flex;align-items:center;justify-content:center;
      width:34.75px;height:34.75px;border:0;border-radius:9999px;
      background:transparent;cursor:pointer;position:relative;padding:0;margin:0;
      color:rgb(113,118,123);transition:background .15s,color .15s;
    }
    .${BUTTON_CLASS} .ld-ico{
      font-weight:800;font-size:14px;line-height:1;font-family:-apple-system,system-ui,sans-serif;
    }
    .${BUTTON_CLASS}:hover{background:rgba(29,155,240,.1);color:rgb(29,155,240);}
    .${BUTTON_CLASS}[data-state='done']{color:rgb(0,186,124);}
    .${BUTTON_CLASS}[data-state='busy']{opacity:.6;cursor:default;}
    .${BUTTON_CLASS}[data-state='error']{color:rgb(244,33,46);}
    .${BUTTON_CLASS} .ld-tip{
      position:absolute;bottom:calc(100% + 6px);left:50%;transform:translateX(-50%);
      white-space:nowrap;font-size:11px;line-height:1;padding:3px 7px;border-radius:5px;
      background:rgba(0,0,0,.85);color:#fff;opacity:0;pointer-events:none;transition:opacity .12s;
      z-index:9999;box-shadow:0 1px 4px rgba(0,0,0,.3);
    }
    .${BUTTON_CLASS}[data-tip]:not([data-tip=''])  .ld-tip{opacity:1;}
  `;
  document.documentElement.appendChild(style);
}

function setTip(button: HTMLButtonElement, state: string, text: string): void {
  button.setAttribute("data-state", state);
  button.setAttribute("data-tip", text);
  const tip = button.querySelector<HTMLElement>(".ld-tip");
  if (tip) tip.textContent = text; // 气泡文字必须写进节点，只设属性看不见。
}

/**
 * 扩展上下文是否还活着。
 *
 * 扩展被重新加载或更新后，早已注入页面的 content script 会继续运行，但它手上的
 * `browser.runtime` 句柄已经作废——`runtime.id` 变成 undefined，`sendMessage`
 * 直接抛 "Extension context invalidated"。访问 `browser.runtime` 本身也可能抛，
 * 所以整体包在 try 里。
 */
function isExtensionContextAlive(): boolean {
  try {
    return Boolean(browser.runtime?.id);
  } catch {
    return false;
  }
}

export type SyncTip = { state: "done" | "error"; text: string };

/**
 * 把一次同步的结果翻译成气泡文字。
 *
 * 单独抽出来是因为「没拿到响应」下面藏着两种解法**相反**的故障：
 * service worker 冷启动重点一次就好；扩展上下文失效则再点多少次都不会成功，
 * 必须刷新页面。原来两者共用一句「请重点一次」，后者会让人一直点下去。
 */
export function syncResultTip(result: unknown, contextAlive: boolean): SyncTip {
  const parsed = result as
    | { ok: true; outcome: { queued: number; skipped: number } }
    | { ok: false; code: string }
    | undefined;
  if (parsed?.ok) {
    return {
      state: "done",
      text: parsed.outcome.queued > 0 ? "已发送到 App" : "已在库",
    };
  }
  if (parsed === undefined || parsed === null) {
    return contextAlive
      ? { state: "error", text: "扩展未响应，请重点一次" }
      : { state: "error", text: "扩展已更新，请刷新页面" };
  }
  if (parsed.code === "native_error") return { state: "error", text: "App 未连接" };
  if (parsed.code === "invalid_id") return { state: "error", text: "读不到帖子ID" };
  return { state: "error", text: `失败：${parsed.code}` };
}

async function onClick(button: HTMLButtonElement): Promise<void> {
  if (button.getAttribute("data-state") === "busy") return;
  // 实时读 id：X 时间线是虚拟滚动，会把 DOM 节点回收给不同的推文。点击时从按钮
  // 往上找当前所在的 article，读它此刻的 id，避免同步到一条早已被换掉的旧推文。
  const article = button.closest("article[data-testid='tweet']");
  const tweetID = article ? tweetIDFromArticle(article) : null;
  if (!tweetID) {
    setTip(button, "error", "读不到帖子ID");
    window.setTimeout(() => button.setAttribute("data-tip", ""), 2_000);
    return;
  }
  setTip(button, "busy", "同步中…");
  // MV3 service worker 冷启动时，来自内容脚本的首个消息可能返回 undefined，也
  // 可能直接以「message channel closed」拒绝。两种都当成“唤醒中，需重试一次”，
  // 而不是把拒绝吞成一个无信息的「同步失败」。
  let result: unknown = undefined;
  let contextAlive = true;
  for (let attempt = 0; attempt < 2; attempt++) {
    // 上下文已经作废时重试没有意义：句柄不会自己复活，只会白等 300ms。
    contextAlive = isExtensionContextAlive();
    if (!contextAlive) break;
    try {
      result = await browser.runtime.sendMessage({ type: "sync-single-tweet", tweetID });
    } catch {
      result = undefined;
    }
    if (result !== undefined && result !== null) break;
    // 抛异常也可能是「发消息的瞬间扩展被重载」，重试前再确认一次上下文。
    contextAlive = isExtensionContextAlive();
    if (!contextAlive) break;
    if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, 300));
  }
  const tip = syncResultTip(result, contextAlive);
  setTip(button, tip.state, tip.text);
  // 两秒后收起气泡；done/error 的颜色保留，让用户看到结果。
  window.setTimeout(() => button.setAttribute("data-tip", ""), 2_000);
}

function injectInto(article: Element): void {
  const actionBar = article.querySelector("[role='group']");
  if (!actionBar) return;
  // 判据用「操作栏里有没有我的按钮」而非标记 article：X 回收节点复用给别的推文
  // 时会重渲染操作栏、把注入的按钮删掉；靠标记会漏掉重注入。按钮点击时才实时读
  // 当前推文 id，所以这里不需要在注入时锁定 id。
  if (actionBar.querySelector(`.${BUTTON_CLASS}`)) return;
  const bookmark = actionBar.querySelector(
    "[data-testid='bookmark'],[data-testid='removeBookmark']",
  );
  // 没有收藏键的行（例如某些推广位）不注入，避免把按钮塞到错误的地方。
  if (!bookmark) return;
  // 注入时只要求这条能读出 id；点击时会再实时读一次。
  if (!tweetIDFromArticle(article)) return;

  const host = document.createElement("div");
  host.style.display = "flex";
  host.style.alignItems = "center";
  const button = buildButton();
  // 用捕获阶段 + stopImmediatePropagation 抢在 X 的文档级导航监听之前，否则点击
  // 会被 X 当成「打开这条帖子」而先跳走。pointerdown 也拦一道，X 有些交互绑在
  // pointerdown 上。
  const intercept = (event: Event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
  };
  button.addEventListener("pointerdown", intercept, true);
  button.addEventListener("click", (event) => {
    intercept(event);
    void onClick(button);
  }, true);
  host.appendChild(button);
  // 收藏键左边：插到 bookmark 所在的操作单元之前。
  const bookmarkCell = bookmark.closest("[role='group'] > div") ?? bookmark;
  bookmarkCell.parentElement?.insertBefore(host, bookmarkCell);
}

function scanAll(): void {
  for (const article of document.querySelectorAll("article[data-testid='tweet']")) {
    injectInto(article);
  }
}

export function startXTimelineSync(): void {
  injectStyles();
  scanAll();
  // 时间线是虚拟滚动 + 动态加载：持续给新出现的帖子补按钮。节流到一帧一次，
  // 避免每个 DOM 变动都全量扫描。
  let scheduled = false;
  const observer = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      scanAll();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });
}
