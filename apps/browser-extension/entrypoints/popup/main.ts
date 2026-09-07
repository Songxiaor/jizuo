export {};
import {
  popupAvailability,
  popupActionPresentation,
  popupBuildLabel,
  popupMetaChips,
  popupRecoveryForSendResult,
  popupMetadataDiagnostic,
  popupPlatformLabel,
  popupPreviewFailure,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
  type PopupCaptureAction,
} from "../../src/popup-presentation";
import type { DouyinSessionDiagnostic } from "../../src/content/douyin-session-detail";
import type { DouyinMetadataDiagnostic } from "../../src/content/douyin-metadata-diagnostic";
import { bookmarksSyncMessage, isXBookmarksURL, type BookmarkPreviewItem, type BookmarksSyncOutcome } from "../../src/content/x-bookmarks";
import {
  isXProfileURL,
  profileCollectFailureCopy,
  profilePresentedMessage,
} from "../../src/content/x-profile";

type BookmarksCollectResult =
  | { ok: true; items: BookmarkPreviewItem[]; reachedKnown: boolean; libraryLookup: "ok" | "unavailable" }
  | { ok: false; code: "not_bookmarks" | "empty" | "injection_failed" };

type BookmarksSyncResult =
  | { ok: true; outcome: BookmarksSyncOutcome; collected: number; reachedKnown: boolean }
  | { ok: false; code: "not_bookmarks" | "empty" | "native_error" | "injection_failed" };

const bookmarksErrorCopy: Readonly<Record<string, string>> = {
  not_bookmarks: "请在 X 的「历史」页打开，并切到「书签/收藏」分页后再同步（地址栏是 x.com/i/history）。",
  empty: "没有找到可同步的收藏。请确认已切到「书签/收藏」分页，并向下滚动加载列表。",
  native_error: "无法连接汲作，或本次同步未被受理。如果汲作已经打开，请完全退出后重新打开，再重试。",
  injection_failed: "读取收藏列表失败，请刷新页面后重试。",
};

type CapturePlatform =
  | "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github"
  | "zhihu" | "medium" | "substack" | "toutiao";
type Completeness = "full_article" | "visible_only" | "selection_only" | "unknown";

type SafeCapturePreview = {
  title: string;
  characterCount: number;
  version: 1 | 2;
  platform: CapturePlatform;
  completeness: Completeness;
  media?: SafeMediaPreview;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  imageCount?: number;
};

const availability = document.querySelector<HTMLSpanElement>("#availability")!;
const platform = document.querySelector<HTMLDivElement>("#platform")!;
const status = document.querySelector<HTMLHeadingElement>("#status")!;
const meta = document.querySelector<HTMLDivElement>("#meta")!;
const diag = document.querySelector<HTMLDetailsElement>("#diag")!;
const metadataDiagnostic = document.querySelector<HTMLPreElement>("#metadata-diagnostic")!;
const error = document.querySelector<HTMLPreElement>("#error")!;
const send = document.querySelector<HTMLButtonElement>("#send")!;
const syncBookmarks = document.querySelector<HTMLButtonElement>("#sync-bookmarks")!;
const syncSelected = document.querySelector<HTMLButtonElement>("#sync-selected")!;
const readXProfile = document.querySelector<HTMLButtonElement>("#read-x-profile")!;
const bookmarksPicker = document.querySelector<HTMLElement>("#bookmarks-picker")!;
const pickerList = document.querySelector<HTMLDivElement>("#picker-list")!;
const pickerCount = document.querySelector<HTMLSpanElement>("#picker-count")!;
const pickerSelectAll = document.querySelector<HTMLButtonElement>("#picker-select-all")!;
const pickerSelectNone = document.querySelector<HTMLButtonElement>("#picker-select-none")!;
const pickerSelectNew = document.querySelector<HTMLButtonElement>("#picker-select-new")!;
const actionCard = document.querySelector<HTMLElement>("#action-card")!;
const actionDetail = document.querySelector<HTMLParagraphElement>("#action-detail")!;
const actionInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name="capture-action"]'));
const resultNotice = document.querySelector<HTMLParagraphElement>("#result")!;
const recoveryAction = document.querySelector<HTMLButtonElement>("#recovery-action")!;
const openApp = document.querySelector<HTMLAnchorElement>("#open-app")!;

let selectedAction: PopupCaptureAction = "save";
let recoveryMode: "retry" | "reload" | null = null;

function applySelectedAction(action: PopupCaptureAction): void {
  selectedAction = action;
  const presentation = popupActionPresentation(action);
  actionDetail.textContent = presentation.detail;
  if (!send.disabled && !send.classList.contains("done")) send.textContent = presentation.button;
}

for (const input of actionInputs) {
  input.addEventListener("change", () => {
    if (input.checked) applySelectedAction(input.value as PopupCaptureAction);
  });
}

const manifest = browser.runtime.getManifest();
const extensionName = manifest.name;
document.title = extensionName;
document.querySelector("#extension-name")!.textContent = extensionName;
document.querySelector("#build-label")!.textContent = popupBuildLabel(manifest);

function setAvailability(tone: string, label: string): void {
  availability.hidden = false;
  availability.dataset.tone = tone;
  availability.textContent = label;
}

function renderPlatform(label: string): void {
  platform.textContent = label;
}

function renderMeta(chips: { text: string; tone?: "video" }[]): void {
  meta.replaceChildren();
  for (const chip of chips) {
    const span = document.createElement("span");
    span.className = chip.tone === "video" ? "chip video" : "chip";
    span.textContent = chip.text;
    meta.append(span);
  }
}

function renderMetadataDiagnostic(diagnostic: DouyinMetadataDiagnostic | undefined): void {
  const rendered = popupMetadataDiagnostic(diagnostic);
  metadataDiagnostic.textContent = rendered ?? "";
  // 诊断区只在有内容时才出现；平时收起，不占用户视线。
  diag.hidden = rendered === null;
}

const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
const tabId = tab?.id;
if (tabId === undefined) {
  status.textContent = "无法读取当前标签页";
  send.disabled = true;
} else if (isXBookmarksURL(tab?.url)) {
  // 历史/收藏页：先读列表再勾选同步。普通「发送」在这里只会抓到列表外壳。
  send.hidden = true;
  actionCard.hidden = true;
  syncBookmarks.hidden = false;
  // 弹窗第一次绘制就要 600px 高，否则读完列表后底部按钮会被裁掉。
  document.documentElement.classList.add("bookmarks-popup");
  document.body.classList.add("picker-open");
  bookmarksPicker.hidden = false;
  syncSelected.hidden = false;
  syncSelected.disabled = false;
  pickerCount.textContent = "尚未读取列表";
  setAvailability("ready", "可勾选");
  renderPlatform("X · 历史收藏");
  status.textContent = "勾选后同步到汲作";
  renderMeta([{ text: "请停在「书签/收藏」分页" }, { text: "先读列表，再挑要同步的" }]);

  let pickerItems: BookmarkPreviewItem[] = [];
  let lastLibraryLookup: "ok" | "unavailable" = "unavailable";

  const applyLibrarySummary = (): void => {
    if (pickerItems.length === 0) return;
    const inLibrary = pickerItems.filter((item) => item.alreadySynced).length;
    const fresh = pickerItems.length - inLibrary;
    status.textContent = `找到 ${pickerItems.length} 条收藏`;
    if (lastLibraryLookup === "ok") {
      if (fresh === 0) {
        renderMeta([
          { text: `全部 ${pickerItems.length} 条已在库` },
          { text: "已在库的不会再抓" },
        ]);
      } else {
        renderMeta([
          { text: `未在库 ${fresh} 条 · 已在库 ${inLibrary} 条` },
          { text: "勾选后点下方同步；已在库的默认不勾" },
        ]);
      }
    } else {
      renderMeta([
        { text: `未同步约 ${fresh} 条（App 未连上，粗标）` },
        { text: "勾选后点下方同步" },
      ]);
    }
  };

  const selectedIDs = (): string[] =>
    Array.from(pickerList.querySelectorAll<HTMLInputElement>("input[type='checkbox']:checked"))
      .map((input) => input.value);

  const refreshPickerChrome = (): void => {
    const total = pickerItems.length;
    const selected = selectedIDs().length;
    pickerCount.textContent = `已选 ${selected} / ${total}`;
    // 0 条时仍可点：给出「请先勾选」反馈，避免底部按钮像坏了一样没反应。
    syncSelected.disabled = false;
    syncSelected.textContent = selected > 0 ? `同步所选 ${selected} 条到汲作` : "同步所选到汲作";
    for (const card of pickerList.querySelectorAll<HTMLElement>(".bookmark-card")) {
      const box = card.querySelector<HTMLInputElement>("input[type='checkbox']");
      card.classList.toggle("is-checked", box?.checked === true);
    }
  };

  const setAllChecked = (predicate: (item: BookmarkPreviewItem) => boolean): void => {
    const boxes = pickerList.querySelectorAll<HTMLInputElement>("input[type='checkbox']");
    boxes.forEach((box, index) => {
      const item = pickerItems[index];
      if (!item) return;
      box.checked = predicate(item);
    });
    refreshPickerChrome();
  };

  const renderPicker = (items: BookmarkPreviewItem[], libraryLookup: "ok" | "unavailable"): void => {
    pickerItems = items;
    document.body.classList.add("picker-open");
    bookmarksPicker.hidden = false;
    syncSelected.hidden = false;
    pickerList.replaceChildren();
    for (const item of items) {
      const label = document.createElement("label");
      label.className = "bookmark-card" + (item.alreadySynced ? " is-synced" : "");
      const box = document.createElement("input");
      box.type = "checkbox";
      box.value = item.id;
      // 默认勾选未同步过的；已在库的留给用户按需补同步。
      box.checked = !item.alreadySynced;
      box.addEventListener("change", refreshPickerChrome);

      const body = document.createElement("div");
      const authorRow = document.createElement("div");
      authorRow.className = "author";
      authorRow.textContent = item.author || "未知作者";
      if (item.alreadySynced) {
        const badge = document.createElement("span");
        badge.className = "badge";
        badge.textContent = libraryLookup === "ok" ? "已在库" : "可能已在库";
        authorRow.append(badge);
      }
      const snippet = document.createElement("p");
      snippet.className = "snippet";
      snippet.textContent = item.text || "（无预览）";
      body.append(authorRow, snippet);
      label.append(box, body);
      pickerList.append(label);
    }
    refreshPickerChrome();
  };

  pickerSelectAll.onclick = () => setAllChecked(() => true);
  pickerSelectNone.onclick = () => setAllChecked(() => false);
  pickerSelectNew.onclick = () => setAllChecked((item) => !item.alreadySynced);

  syncBookmarks.onclick = async () => {
    syncBookmarks.disabled = true;
    syncBookmarks.classList.remove("done");
    // 读列表时不要收起 picker：弹窗一缩小，Chromium 就不会再长高。
    error.textContent = "";
    resultNotice.hidden = true;
    pickerCount.textContent = "正在读取…";
    syncBookmarks.textContent = "正在滚动收集收藏…";
    status.textContent = "正在读取收藏列表";
    renderMeta([{ text: "请保持页面打开，不要切换标签" }]);
    try {
      const result = await browser.runtime.sendMessage({
        type: "collect-x-bookmarks",
        tabId,
      }) as BookmarksCollectResult;
      if (!result.ok) {
        error.textContent = bookmarksErrorCopy[result.code] ?? "读取未完成，请重试。";
        syncBookmarks.textContent = "读取收藏列表";
        syncBookmarks.disabled = false;
        status.textContent = "勾选后同步到汲作";
        pickerCount.textContent = pickerItems.length > 0
          ? `已选 ${selectedIDs().length} / ${pickerItems.length}`
          : "尚未读取列表";
        return;
      }
      lastLibraryLookup = result.libraryLookup;
      renderPicker(result.items, result.libraryLookup);
      applyLibrarySummary();
      syncBookmarks.textContent = "重新读取列表";
      syncBookmarks.disabled = false;
    } catch {
      error.textContent = "读取失败，请重试。";
      syncBookmarks.textContent = "读取收藏列表";
      syncBookmarks.disabled = false;
      pickerCount.textContent = pickerItems.length > 0
        ? `已选 ${selectedIDs().length} / ${pickerItems.length}`
        : "尚未读取列表";
    }
  };

  syncSelected.onclick = async () => {
    const ids = selectedIDs();
    if (pickerItems.length === 0) {
      error.textContent = "请先点上方「读取收藏列表」。";
      return;
    }
    if (ids.length === 0) {
      error.textContent = "请先勾选要同步的收藏。已在库的默认不勾，可点「全选」或「选未同步」。";
      return;
    }
    if (
      lastLibraryLookup === "ok"
      && ids.every((id) => pickerItems.find((item) => item.id === id)?.alreadySynced === true)
    ) {
      const message = `${ids.length} 条已在库，不会再抓`;
      syncSelected.textContent = "✓ " + message;
      syncSelected.classList.add("done");
      resultNotice.textContent = "✓ " + message;
      resultNotice.hidden = false;
      return;
    }
    syncSelected.disabled = true;
    syncBookmarks.disabled = true;
    syncSelected.classList.remove("done");
    error.textContent = "";
    syncSelected.textContent = `正在同步 ${ids.length} 条…`;
    try {
      const result = await browser.runtime.sendMessage({
        type: "enqueue-x-bookmarks",
        tweetIDs: ids,
      }) as BookmarksSyncResult;
      if (result.ok) {
        const message = bookmarksSyncMessage(result.outcome, result.collected, result.reachedKnown);
        syncSelected.textContent = "✓ " + message;
        syncSelected.classList.add("done");
        resultNotice.textContent = "✓ " + message;
        resultNotice.hidden = false;
        // 勾掉已提交的，避免重复点。
        for (const box of pickerList.querySelectorAll<HTMLInputElement>("input[type='checkbox']")) {
          if (ids.includes(box.value)) {
            box.checked = false;
            const item = pickerItems.find((row) => row.id === box.value);
            if (item) item.alreadySynced = true;
            const card = box.closest(".bookmark-card");
            card?.classList.add("is-synced");
            const authorRow = card?.querySelector(".author");
            if (authorRow && !authorRow.querySelector(".badge")) {
              const badge = document.createElement("span");
              badge.className = "badge";
              badge.textContent = "已在库";
              authorRow.append(badge);
            }
          }
        }
        lastLibraryLookup = "ok";
        refreshPickerChrome();
        applyLibrarySummary();
        syncBookmarks.disabled = false;
      } else {
        error.textContent = bookmarksErrorCopy[result.code] ?? "同步未完成，请重试。";
        refreshPickerChrome();
        syncBookmarks.disabled = false;
      }
    } catch {
      error.textContent = "同步失败，请重试。";
      refreshPickerChrome();
      syncBookmarks.disabled = false;
    }
  };
} else if (isXProfileURL(tab?.url)) {
  send.hidden = true;
  actionCard.hidden = true;
  readXProfile.hidden = false;
  readXProfile.disabled = false;
  setAvailability("ready", "可读取");
  renderPlatform("X · 主页作品");
  status.textContent = "读取后到汲作勾选";
  renderMeta([{ text: "请停在「帖子」分页" }, { text: "不会自动保存或总结" }]);
  readXProfile.onclick = async () => {
    readXProfile.disabled = true;
    readXProfile.classList.remove("done");
    error.textContent = "";
    resultNotice.hidden = true;
    readXProfile.textContent = "正在读取主页作品…";
    status.textContent = "正在读取主页作品";
    renderMeta([{ text: "请保持页面打开，不要切换标签" }]);
    try {
      const result = await browser.runtime.sendMessage({
        type: "present-x-profile-candidates",
        tabId,
      }) as { ok: true; acceptedCount: number } | { ok: false; code: string };
      if (result.ok) {
        const message = profilePresentedMessage(result.acceptedCount);
        readXProfile.textContent = "✓ 已交给汲作选择";
        readXProfile.classList.add("done");
        resultNotice.textContent = "✓ " + message;
        resultNotice.hidden = false;
        status.textContent = "请到汲作勾选要保存的作品";
        renderMeta([{ text: `候选 ${result.acceptedCount} 条` }, { text: "尚未入库" }]);
        openApp.textContent = "打开汲作勾选";
        openApp.hidden = false;
      } else {
        error.textContent = profileCollectFailureCopy(result.code);
        readXProfile.textContent = "读取主页作品到汲作";
        readXProfile.disabled = false;
        if (result.code === "native_error" || result.code === "upgrade_app") {
          openApp.textContent = "打开汲作";
          openApp.hidden = false;
        }
      }
    } catch {
      error.textContent = profileCollectFailureCopy("native_error");
      readXProfile.textContent = "读取主页作品到汲作";
      readXProfile.disabled = false;
    }
  };
  openApp.addEventListener("click", (event) => {
    event.preventDefault();
    void browser.runtime.sendMessage({ type: "open-app" });
  });
} else {
  try {
    const preview = await browser.runtime.sendMessage({
      type: "preview-current-page",
      tabId,
    }) as SafeCapturePreview;
    const avail = popupAvailability(preview);
    setAvailability(avail.tone, avail.label);
    renderPlatform(popupPlatformLabel(preview.platform, preview.version, preview.imageCount));
    status.textContent = preview.title;
    renderMeta(popupMetaChips(preview));
    renderMetadataDiagnostic(preview.metadataDiagnostic);
    if (avail.tone === "blocked") {
      send.disabled = true;
      send.textContent = "暂不支持此平台";
    } else {
      // 预览成功才启用。按钮初始 disabled（见 index.html 注释）：onclick 在这段
      // 顶层 await 之后才挂上，提前可点等于点了没反应。
      send.textContent = popupActionPresentation(selectedAction).button;
      send.disabled = false;
    }
  } catch (cause) {
    status.textContent = "当前页面不可捕获";
    setAvailability("blocked", "不可捕获");
    // 这里原本把原因整个吞掉，界面上只剩一句没有信息量的提示，排查时等于没有线索。
    // 把真实 message 亮出来：CAPTURE_CONTENT_EMPTY 是抓到了页面但没有正文，
    // "Cannot access contents of url…" 是注入被拒，两者的修法完全不同。
    const message = cause instanceof Error ? cause.message : String(cause);
    const failure = popupPreviewFailure(message);
    error.textContent = failure.message;
    send.hidden = true;
    if (failure.canReload) {
      recoveryMode = "reload";
      recoveryAction.textContent = "重新读取页面";
      recoveryAction.hidden = false;
    } else {
      recoveryMode = null;
      recoveryAction.hidden = true;
    }
  }

  const submit = async () => {
    send.disabled = true;
    send.classList.remove("done");
    error.textContent = "";
    resultNotice.hidden = true;
    recoveryAction.hidden = true;
    openApp.hidden = true;
    renderMetadataDiagnostic(undefined);
    try {
      const result = await browser.runtime.sendMessage({
        type: "send-current-page",
        tabId,
        requestedAction: selectedAction,
      }) as SafeExtensionSendResult;
      renderMetadataDiagnostic(result.metadataDiagnostic);
      const recovery = popupRecoveryForSendResult(result);
      if (recovery) {
        error.textContent = recovery.message;
        send.hidden = true;
        if (recovery.action === "open_app" || recovery.action === "open_settings") {
          openApp.textContent = recovery.label;
          openApp.hidden = false;
        } else if (recovery.action === "retry" || recovery.action === "reload") {
          recoveryMode = recovery.action;
          recoveryAction.textContent = recovery.label;
          recoveryAction.hidden = false;
        }
      } else {
        actionCard.hidden = true;
        send.hidden = true;
        resultNotice.textContent = "✓ " + popupActionPresentation(selectedAction).success;
        resultNotice.hidden = false;
        openApp.textContent = "打开汲作查看";
        openApp.hidden = false;
      }
    } catch {
      renderMetadataDiagnostic(undefined);
      error.textContent = "发送失败，请重试。";
      send.hidden = true;
      recoveryMode = "retry";
      recoveryAction.textContent = "重试发送";
      recoveryAction.hidden = false;
    }
  };
  send.onclick = submit;
  recoveryAction.onclick = () => {
    if (recoveryMode === "reload") window.location.reload();
    else {
      send.hidden = false;
      void submit();
    }
  };
  openApp.addEventListener("click", (event) => {
    // 不能靠 <a href="linkdigest://open">：Launch Services 的默认 scheme 绑定
    // 在本机上会打到过期声明，正在跑的汲作不会到前台。走 Host 用同包路径 open。
    event.preventDefault();
    void browser.runtime.sendMessage({ type: "open-app" });
  });
}
