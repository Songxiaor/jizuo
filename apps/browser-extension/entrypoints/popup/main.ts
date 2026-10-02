export {};
import {
  popupAvailability,
  popupActionPresentation,
  popupBuildLabel,
  popupRecoveryForSendResult,
  popupMetadataDiagnostic,
  popupPreviewFailure,
  popupBrowserPageFailure,
  popupCaughtFailure,
  popupSourceLine,
  popupStats,
  popupDuration,
  popupBylineText,
  popupStepChain,
  popupXProfileHeading,
  popupChainSummary,
  popupStepProgress,
  popupSavedAtLabel,
  popupTranslationNote,
  commentLoginWallNote,
  type ChainKey,
  type CommentPlan,
  type StepProgressRow,
  type SafeExtensionSendResult,
  type SafeMediaPreview,
  type PopupCaptureAction,
} from "../../src/popup-presentation";
import { stampedSealMarkup } from "../../src/collector-seal";
import {
  connectionCopy,
  isNativeCodeConnectionFailure,
  nativeCodeRetryVerdict,
  openAppThenRetry,
  sendRetryVerdict,
  withConnectionRetry,
  type OpenAppResult,
} from "../../src/popup-connection";
import type { DouyinSessionDiagnostic } from "../../src/content/douyin-session-detail";
import type { DouyinMetadataDiagnostic } from "../../src/content/douyin-metadata-diagnostic";
import { bookmarksSyncMessage, isXBookmarksURL, type BookmarkPreviewItem, type BookmarksSyncOutcome } from "../../src/content/x-bookmarks";
import type { CommentCollectResult, CommentSendMode } from "../../src/entrypoints/background";
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
  | { ok: false; code: "not_bookmarks" | "empty" | "native_error" | "injection_failed" | "upgrade_app"; transient?: true };

type ProfilePresentResult =
  | { ok: true; acceptedCount: number }
  | { ok: false; code: string; transient?: true };

const bookmarksErrorCopy: Readonly<Record<string, string>> = {
  not_bookmarks: "请在 X 的「历史」页打开，并切到「书签/收藏」分页后再读取列表（地址栏是 x.com/i/history）。",
  empty: "没有找到可保存的收藏。请确认已切到「书签/收藏」分页，并向下滚动加载列表。",
  native_error: connectionCopy.needsApp,
  injection_failed: "读取列表失败，请刷新页面后重试。",
  upgrade_app: connectionCopy.upgrade,
};

type CapturePlatform =
  | "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github"
  | "zhihu" | "medium" | "substack" | "toutiao";
type Completeness = "full_article" | "visible_only" | "selection_only" | "unknown";

type SafeCapturePreview = {
  title: string;
  characterCount: number;
  wordCount?: number;
  version: 1 | 2;
  platform: CapturePlatform;
  completeness: Completeness;
  media?: SafeMediaPreview;
  mediaDiagnostic?: DouyinSessionDiagnostic;
  metadataDiagnostic?: DouyinMetadataDiagnostic;
  imageCount?: number;
  excerpt?: string;
  host?: string;
  usedCookie?: boolean;
  pageTranslatedBy?: string;
  mediaDurationSeconds?: number;
  mediaAuthor?: string;
  sourceAuthor?: string;
  published?: string;
  engagement?: Partial<Record<"likes" | "comments" | "shares" | "collects" | "views", string>>;
  pageURL?: string;
};

type PageStatus =
  | { kind: "found"; taskID: string; savedAt?: number; steps: { step: string; state: "done" | "running" | "failed"; detail?: string }[] }
  | { kind: "notFound" }
  | { kind: "unavailable" };

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
const commentsPicker = document.querySelector<HTMLElement>("#comments-picker")!;
const commentsCount = document.querySelector<HTMLSpanElement>("#comments-count")!;
const commentsList = document.querySelector<HTMLDivElement>("#comments-list")!;
const commentsNote = document.querySelector<HTMLParagraphElement>("#comments-note")!;
const commentsSelectAll = document.querySelector<HTMLButtonElement>("#comments-select-all")!;
const commentsSelectNone = document.querySelector<HTMLButtonElement>("#comments-select-none")!;
const commentsMode = document.querySelector<HTMLButtonElement>("#comments-mode")!;
const commentsMore = document.querySelector<HTMLParagraphElement>("#comments-more")!;
const sourceCard = document.querySelector<HTMLElement>("#source-card")!;
const videoThumb = document.querySelector<HTMLElement>("#video-thumb")!;
const videoDuration = document.querySelector<HTMLSpanElement>("#video-duration")!;
const author = document.querySelector<HTMLDivElement>("#author")!;
const excerpt = document.querySelector<HTMLParagraphElement>("#excerpt")!;
const stats = document.querySelector<HTMLDivElement>("#stats")!;
const sourceNote = document.querySelector<HTMLParagraphElement>("#source-note")!;
const translationNote = document.querySelector<HTMLParagraphElement>("#translation-note")!;
const savedView = document.querySelector<HTMLElement>("#saved-view")!;
const savedSeal = document.querySelector<HTMLSpanElement>("#saved-seal")!;
const savedTitle = document.querySelector<HTMLHeadingElement>("#saved-title")!;
const savedDetail = document.querySelector<HTMLParagraphElement>("#saved-detail")!;
const failureView = document.querySelector<HTMLElement>("#failure-view")!;
const failureTitle = document.querySelector<HTMLHeadingElement>("#failure-title")!;
const failureMessage = document.querySelector<HTMLParagraphElement>("#failure-message")!;
const failureSteps = document.querySelector<HTMLOListElement>("#failure-steps")!;
const resultActions = document.querySelector<HTMLDivElement>("#result-actions")!;
const stepChain = document.querySelector<HTMLDivElement>("#step-chain")!;
const dupView = document.querySelector<HTMLElement>("#dup-view")!;
const dupDate = document.querySelector<HTMLSpanElement>("#dup-date")!;
const dupSteps = document.querySelector<HTMLDivElement>("#dup-steps")!;
const savedSteps = document.querySelector<HTMLDivElement>("#saved-steps")!;
const saveAgain = document.querySelector<HTMLButtonElement>("#save-again")!;
const closePopup = document.querySelector<HTMLButtonElement>("#close-popup")!;
closePopup.addEventListener("click", () => window.close());

let selectedAction: PopupCaptureAction = "save";
let recoveryMode: "retry" | "reload" | "open_app_retry" | null = null;

/** 工序链的输入：App 的自动设置、这页有没有视频、评论怎么存。齐了就重画。 */
let autoSteps: readonly string[] | undefined;
let pageHasVideo = false;
let previewLoaded = false;
let pagePlatform: CapturePlatform | undefined;
let commentPlan: CommentPlan = "unknown";
/** 这条在汲作里的 id：查重找到或保存后轮询到，「在汲作里打开」直接跳过去。 */
let knownTaskID: string | undefined;

function applySelectedAction(action: PopupCaptureAction): void {
  selectedAction = action;
  const presentation = popupActionPresentation(action);
  if (!send.disabled && !send.classList.contains("done")) send.textContent = presentation.button;
  renderStepChain();
}

/** 一枚印的图：App 导出的 PNG，深浅色各一张。 */
function sealPicture(key: ChainKey, stamped: boolean): HTMLElement {
  const holder = document.createElement("span");
  holder.className = "seal-img";
  const picture = document.createElement("picture");
  const style = stamped ? "stamped" : "pending";
  const name = key === "ji" ? "ji" : key;
  const dark = document.createElement("source");
  dark.media = "(prefers-color-scheme: dark)";
  dark.srcset = `/seals/${name}-${style}-dark.png`;
  const img = document.createElement("img");
  img.src = `/seals/${name}-${style}-light.png`;
  img.alt = "";
  picture.append(dark, img);
  holder.append(picture);
  return holder;
}

function renderStepChain(): void {
  const chain = popupStepChain({ autoSteps, hasVideo: previewLoaded ? pageHasVideo : undefined, usesCaptions: pagePlatform === "youtube", comments: commentPlan, selectedAction });
  stepChain.replaceChildren();
  for (const seal of chain) {
    const item = document.createElement(seal.toggles ? "button" : "div") as HTMLElement;
    item.className = `chain-seal ${seal.style}`;
    if (seal.toggles) {
      (item as HTMLButtonElement).type = "button";
      const target = seal.toggles;
      item.title = selectedAction === target ? "点一下取消" : "这次也做";
      item.addEventListener("click", () => applySelectedAction(selectedAction === target ? "save" : target));
    }
    const label = document.createElement("span");
    label.textContent = seal.label;
    item.append(sealPicture(seal.key, seal.style === "stamped"), label);
    stepChain.append(item);
  }
  actionDetail.textContent = popupChainSummary(chain, autoSteps !== undefined);
}

function renderStepRows(target: HTMLElement, rows: StepProgressRow[]): void {
  target.replaceChildren();
  for (const row of rows) {
    const line = document.createElement("div");
    line.className = `step-row ${row.state}`;
    const name = document.createElement("span");
    name.textContent = row.title;
    const state = document.createElement("span");
    state.className = "state";
    state.textContent = row.text;
    line.append(sealPicture(row.key, row.state === "done"), name, state);
    target.append(line);
  }
}

/** 这次保存会做的工序：自动开着的 + 这次点了的 + 自动存的评论。 */
function expectedSteps(): Set<string> {
  const expected = new Set(autoSteps ?? []);
  // 自动的「译」只翻标题，App 不单独记这一步：不算「等着做」，否则会一直等下去。
  expected.delete("translation");
  if (!pageHasVideo) { expected.delete("record"); expected.delete("proof"); }
  if (commentPlan === "auto" || commentPlan === "picker") expected.add("comments");
  else expected.delete("comments");
  if (selectedAction === "summarize") expected.add("summary");
  if (selectedAction === "translate") expected.add("translation");
  return expected;
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

function renderStats(cells: { value: string; label: string }[]): void {
  stats.replaceChildren();
  stats.dataset.count = String(cells.length);
  for (const cell of cells) {
    const box = document.createElement("div");
    box.className = "stat";
    const value = document.createElement("b");
    value.textContent = cell.value;
    const label = document.createElement("span");
    label.textContent = cell.label;
    box.append(value, label);
    stats.append(box);
  }
}

/** 结果行：左「关闭」，右边放这一刻的主操作（在汲作里打开 / 重新读取）。 */
function showResultActions(primary: HTMLElement | null): void {
  resultActions.replaceChildren(closePopup);
  if (primary) {
    primary.hidden = false;
    resultActions.append(primary);
  }
  resultActions.hidden = false;
}

function renderMetadataDiagnostic(diagnostic: DouyinMetadataDiagnostic | undefined): void {
  const rendered = popupMetadataDiagnostic(diagnostic);
  metadataDiagnostic.textContent = rendered ?? "";
  // 诊断区只在有内容时才出现；平时收起，不占用户视线。
  diag.hidden = rendered === null;
}

/** 让 Host 把汲作拉到前台（不带 taskID：这里只为接上通道）。 */
function requestOpenApp(): Promise<OpenAppResult | undefined> {
  return browser.runtime.sendMessage({ type: "open-app" }) as Promise<OpenAppResult | undefined>;
}

/**
 * 收藏页、主页两种流程连不上汲作时的「打开汲作并重试」（2026-10-01）。
 * 单页保存走 recoveryMode，因为那里的 recoveryAction 还兼管「重试保存 / 重新读取」。
 */
function offerOpenAndRetry(run: () => Promise<void>): void {
  recoveryAction.textContent = connectionCopy.openRetryLabel;
  recoveryAction.disabled = false;
  recoveryAction.hidden = false;
  recoveryAction.onclick = async () => {
    recoveryAction.disabled = true;
    recoveryAction.textContent = connectionCopy.opening;
    error.textContent = "";
    try {
      await run();
    } finally {
      recoveryAction.disabled = false;
      recoveryAction.textContent = connectionCopy.openRetryLabel;
    }
  };
}

const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
const tabId = tab?.id;
if (tabId === undefined) {
  status.textContent = "无法读取当前标签页";
  send.disabled = true;
  actionCard.hidden = true;
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
  status.textContent = "勾选后保存到汲作";
  renderMeta([{ text: "请停在「书签/收藏」分页" }, { text: "先读取列表，再挑要保存的" }]);

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
          { text: "已在库的不会重复保存" },
        ]);
      } else {
        renderMeta([
          { text: `未在库 ${fresh} 条 · 已在库 ${inLibrary} 条` },
          { text: "勾选后点「保存所选」；已在库的默认不勾" },
        ]);
      }
    } else {
      renderMeta([
        { text: `未保存约 ${fresh} 条（没连上汲作，按本机记录估计）` },
        { text: "勾选后点「保存所选」" },
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
    syncSelected.textContent = selected > 0 ? `保存所选 ${selected} 条` : "批量保存";
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
    syncBookmarks.textContent = "正在读取列表…";
    status.textContent = "正在读取列表";
    renderMeta([{ text: "请保持页面打开，不要切换标签" }]);
    try {
      const result = await browser.runtime.sendMessage({
        type: "collect-x-bookmarks",
        tabId,
      }) as BookmarksCollectResult;
      if (!result.ok) {
        error.textContent = bookmarksErrorCopy[result.code] ?? "读取未完成，请重试。";
        syncBookmarks.textContent = "读取列表";
        syncBookmarks.disabled = false;
        status.textContent = "勾选后保存到汲作";
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
    } catch (cause) {
      error.textContent = popupCaughtFailure(cause, "读取失败，请重试。");
      syncBookmarks.textContent = "读取列表";
      syncBookmarks.disabled = false;
      pickerCount.textContent = pickerItems.length > 0
        ? `已选 ${selectedIDs().length} / ${pickerItems.length}`
        : "尚未读取列表";
    }
  };

  const enqueueSelected = (ids: string[]): Promise<BookmarksSyncResult> =>
    browser.runtime.sendMessage({ type: "enqueue-x-bookmarks", tweetIDs: ids }) as Promise<BookmarksSyncResult>;

  /** 一次保存的结果落到界面上；afterOpen = 已经点过「打开汲作并重试」，再失败就给最后的说明。 */
  const applySyncResult = (ids: string[], result: BookmarksSyncResult, afterOpen: boolean): void => {
    if (result.ok) {
      recoveryAction.hidden = true;
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
      return;
    }
    if (isNativeCodeConnectionFailure(result)) {
      error.textContent = afterOpen ? connectionCopy.gaveUp : connectionCopy.needsApp;
      offerOpenAndRetry(async () => {
        syncSelected.disabled = true;
        syncBookmarks.disabled = true;
        syncSelected.textContent = `正在保存 ${ids.length} 条…`;
        try {
          const outcome = await openAppThenRetry(requestOpenApp, () => enqueueSelected(ids));
          if (outcome.kind === "retried") {
            applySyncResult(ids, outcome.result, true);
            return;
          }
          error.textContent = outcome.kind === "upgrade" ? connectionCopy.upgrade : connectionCopy.gaveUp;
        } catch (cause) {
          error.textContent = popupCaughtFailure(cause, "保存失败，请重试。");
        }
        refreshPickerChrome();
        syncBookmarks.disabled = false;
      });
    } else {
      recoveryAction.hidden = true;
      error.textContent = bookmarksErrorCopy[result.code] ?? "保存未完成，请重试。";
    }
    refreshPickerChrome();
    syncBookmarks.disabled = false;
  };

  syncSelected.onclick = async () => {
    const ids = selectedIDs();
    if (pickerItems.length === 0) {
      error.textContent = "请先点上方「读取列表」。";
      return;
    }
    if (ids.length === 0) {
      error.textContent = "请先勾选要保存的收藏。已在库的默认不勾，可点「全选」或「选未保存」。";
      return;
    }
    if (
      lastLibraryLookup === "ok"
      && ids.every((id) => pickerItems.find((item) => item.id === id)?.alreadySynced === true)
    ) {
      const message = `${ids.length} 条已在库，不会重复保存`;
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
    recoveryAction.hidden = true;
    syncSelected.textContent = `正在保存 ${ids.length} 条…`;
    try {
      const result = await withConnectionRetry(() => enqueueSelected(ids), nativeCodeRetryVerdict, {
        onRetry: () => { syncSelected.textContent = connectionCopy.connecting; },
      });
      applySyncResult(ids, result, false);
    } catch (cause) {
      error.textContent = popupCaughtFailure(cause, "保存失败，请重试。");
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
  // 标题说这是谁的主页，说明放进正文位置（只在「帖子」分页上才会走到这里，不用再提示分页）。
  const profile = popupXProfileHeading(tab?.title, tab?.url);
  status.textContent = `${profile.name}的主页`;
  author.textContent = profile.handle !== profile.name ? profile.handle : "";
  author.hidden = author.textContent.length === 0;
  excerpt.textContent = "往下翻读出本人发的帖子，把列表交给汲作，你在汲作里勾选要保存哪些。不会自动保存或总结。";
  excerpt.hidden = false;
  renderMeta([]);
  // 这里只是「读取列表」：真正保存要到汲作里勾选，按钮不能写成「保存」（2026-10-01 统一用词）。
  const readLabel = "读取列表，到汲作勾选";
  readXProfile.textContent = readLabel;
  const presentCandidates = (): Promise<ProfilePresentResult> =>
    browser.runtime.sendMessage({ type: "present-x-profile-candidates", tabId }) as Promise<ProfilePresentResult>;

  const applyProfileResult = (result: ProfilePresentResult, afterOpen: boolean): void => {
    if (result.ok) {
      recoveryAction.hidden = true;
      const message = profilePresentedMessage(result.acceptedCount);
      readXProfile.textContent = "✓ 列表已交给汲作";
      readXProfile.classList.add("done");
      resultNotice.textContent = "✓ " + message;
      resultNotice.hidden = false;
      status.textContent = "请到汲作勾选要保存的作品";
      renderMeta([{ text: `候选 ${result.acceptedCount} 条` }, { text: "尚未保存" }]);
      openApp.textContent = "打开汲作勾选";
      openApp.hidden = false;
      return;
    }
    readXProfile.textContent = readLabel;
    readXProfile.disabled = false;
    if (isNativeCodeConnectionFailure(result)) {
      openApp.hidden = true;
      error.textContent = afterOpen ? connectionCopy.gaveUp : connectionCopy.needsApp;
      offerOpenAndRetry(async () => {
        readXProfile.disabled = true;
        readXProfile.textContent = "正在读取列表…";
        try {
          const outcome = await openAppThenRetry(requestOpenApp, presentCandidates);
          if (outcome.kind === "retried") {
            applyProfileResult(outcome.result, true);
            return;
          }
          error.textContent = outcome.kind === "upgrade" ? connectionCopy.upgrade : connectionCopy.gaveUp;
        } catch (cause) {
          error.textContent = popupCaughtFailure(cause, connectionCopy.gaveUp);
        }
        readXProfile.textContent = readLabel;
        readXProfile.disabled = false;
      });
      return;
    }
    recoveryAction.hidden = true;
    error.textContent = profileCollectFailureCopy(result.code);
    if (result.code === "upgrade_app") {
      openApp.textContent = "打开汲作检查更新";
      openApp.hidden = false;
    }
  };

  readXProfile.onclick = async () => {
    readXProfile.disabled = true;
    readXProfile.classList.remove("done");
    error.textContent = "";
    resultNotice.hidden = true;
    recoveryAction.hidden = true;
    readXProfile.textContent = "正在读取列表…";
    status.textContent = "正在读取主页作品列表";
    renderMeta([{ text: "请保持页面打开，不要切换标签" }]);
    try {
      // 每次重试都会重新往下翻一遍主页，所以只在 background 标了 transient（很快断开）时自动再试，
      // 不再按耗时判断：翻页本身就要好几秒。
      const result = await withConnectionRetry(presentCandidates, nativeCodeRetryVerdict, {
        fastFailureMs: Number.POSITIVE_INFINITY,
        onRetry: () => { readXProfile.textContent = connectionCopy.connecting; },
      });
      applyProfileResult(result, false);
    } catch (cause) {
      error.textContent = popupCaughtFailure(cause, connectionCopy.needsApp);
      readXProfile.textContent = readLabel;
      readXProfile.disabled = false;
    }
  };
  openApp.addEventListener("click", (event) => {
    event.preventDefault();
    void browser.runtime.sendMessage({ type: "open-app" });
  });
} else {
  let previewTitle = "";
  let previewPageURL: string | undefined;
  // App 的自动设置：和预览并行读，读到就重画工序链。旧版 App/Host 没有这项时按「不知道」显示。
  void (async () => {
    try {
      const prefs = await browser.runtime.sendMessage({ type: "pipeline-preferences" }) as { autoSteps?: string[] } | undefined;
      if (prefs && Array.isArray(prefs.autoSteps)) {
        autoSteps = prefs.autoSteps;
        renderStepChain();
      }
    } catch {
      // 保持「不知道」。
    }
  })();
  /** 自动保存评论时弹窗已读到的条数；没读到时按设置条数说。 */
  let autoCommentCount: number | undefined;
  /** 保存成功卡上的评论一句话：勾了几条 / 自动存前几条 / 不存。 */
  const savedCommentsLine = (): string => {
    if (commentMode?.kind === "disabled") return "";
    if (commentMode?.kind === "auto") {
      return autoCommentCount !== undefined ? `评论存了 ${autoCommentCount} 条` : `评论按设置存前 ${commentMode.limit} 条`;
    }
    const picked = selectedCommentIDs();
    if (picked === undefined) return "";
    return picked.length > 0 ? `评论存了 ${picked.length} 条` : "没有存评论";
  };
  /** undefined = 没有勾选结果（未支持、没读到或失败），由 background 按设置条数处理。 */
  let selectedCommentIDs: () => string[] | undefined = () => undefined;
  let commentsLoading: Promise<void> | null = null;
  /** 汲作设置里「不抓」或「自动保存前 N 条」时由 background 告知；undefined = 勾选流程。 */
  let commentMode: CommentSendMode | undefined;

  const renderCommentPicker = (result: CommentCollectResult): void => {
    commentsList.replaceChildren();
    commentsMore.textContent = "";
    if (!result.ok) {
      if (result.code === "unsupported") {
        commentsPicker.hidden = true;
        commentPlan = "unsupported";
        renderStepChain();
        return;
      }
      if (result.code === "disabled") {
        commentMode = { kind: "disabled" };
        commentPlan = "disabled";
        renderStepChain();
        commentsCount.textContent = "评论";
        commentsNote.textContent = "这个平台设为不存评论（可在汲作「设置 → 收集 · 汲 → 评论」里改）";
        commentsSelectAll.hidden = true;
        commentsSelectNone.hidden = true;
        return;
      }
      if (result.code === "auto") {
        commentMode = { kind: "auto", limit: result.limit };
        commentPlan = "auto";
        renderStepChain();
        commentsSelectAll.hidden = true;
        commentsSelectNone.hidden = true;
        const items = result.items ?? [];
        if (items.length === 0) {
          commentsCount.textContent = `评论 · 将存前 ${result.limit} 条`;
          commentsNote.textContent = "保存时读取评论区。";
          return;
        }
        // 自动保存：只读预览前三条，要挑的话切到勾选列表（用同一份已读好的评论）。
        commentsCount.textContent = `评论 · 将存前 ${Math.min(result.limit, items.length)} 条`;
        autoCommentCount = Math.min(result.limit, items.length);
        const previewed = items.filter((row) => row.depth === 0).slice(0, 2);
        for (const item of previewed) {
          const row = document.createElement("div");
          row.className = "comment-preview";
          const who = document.createElement("div");
          who.className = "who";
          const name = document.createElement("span");
          name.textContent = item.author;
          who.append(name);
          if (item.likes) {
            const likes = document.createElement("span");
            likes.textContent = `赞 ${item.likes}`;
            who.append(likes);
          }
          const what = document.createElement("div");
          what.className = "what";
          what.textContent = item.excerpt || "（无文字）";
          row.append(who, what);
          commentsList.append(row);
        }
        const rest = items.length - previewed.length;
        const pageTotal = result.expectedCount && result.expectedCount > items.length
          ? `页面共约 ${result.expectedCount} 条`
          : "";
        commentsMore.textContent = [rest > 0 ? `还有 ${rest} 条` : "", pageTotal].filter(Boolean).join(" · ");
        // 自动保存也要说清「只读到未登录可见的部分」，不然会悄悄少存（小红书登录被挤掉时）。
        commentsNote.textContent = result.loginRequired
          ? commentLoginWallNote(result.platform, items.length, result.limit)
          : "";
        commentsMode.hidden = false;
        commentsMode.onclick = () => {
          commentsMode.hidden = true;
          commentsMore.textContent = "";
          commentMode = undefined;
          renderCommentPicker({
            ok: true, platform: result.platform, limit: result.limit, items,
            ...(result.loginRequired ? { loginRequired: true } : {}),
          });
        };
        return;
      }
      commentsCount.textContent = result.code === "empty" ? "没有读到评论" : "评论读取失败";
      commentsNote.textContent = result.code === "empty"
        ? "这条内容暂时没有可见评论，这次只保存正文。"
        : "这次只保存正文。可以刷新页面后重新打开扩展再试。";
      commentsSelectAll.hidden = true;
      commentsSelectNone.hidden = true;
      return;
    }
    commentPlan = "picker";
    renderStepChain();
    const refresh = (): void => {
      const boxes = Array.from(commentsList.querySelectorAll<HTMLInputElement>("input[type='checkbox']"));
      const checked = boxes.filter((box) => box.checked).length;
      commentsCount.textContent = `评论 · 已选 ${checked}/${boxes.length}`;
      for (const box of boxes) box.closest(".bookmark-card")?.classList.toggle("is-checked", box.checked);
    };
    for (const item of result.items) {
      const label = document.createElement("label");
      label.className = "bookmark-card" + (item.depth > 0 ? " is-reply" : "");
      const box = document.createElement("input");
      box.type = "checkbox";
      box.value = item.id;
      box.checked = true;
      box.addEventListener("change", refresh);
      const body = document.createElement("div");
      const author = document.createElement("div");
      author.className = "author";
      author.textContent = item.author;
      if (item.likes) {
        const likes = document.createElement("span");
        likes.className = "likes";
        likes.textContent = `赞 ${item.likes}`;
        author.append(likes);
      }
      const snippet = document.createElement("p");
      snippet.className = "snippet";
      snippet.textContent = item.excerpt || "（无文字）";
      body.append(author, snippet);
      label.append(box, body);
      commentsList.append(label);
    }
    const setAll = (checked: boolean): void => {
      commentsList.querySelectorAll<HTMLInputElement>("input[type='checkbox']").forEach((box) => { box.checked = checked; });
      refresh();
    };
    commentsSelectAll.hidden = false;
    commentsSelectNone.hidden = false;
    commentsSelectAll.onclick = () => setAll(true);
    commentsSelectNone.onclick = () => setAll(false);
    const expected = result.expectedCount && result.expectedCount > result.items.length
      ? `页面共约 ${result.expectedCount} 条，`
      : "";
    commentsNote.textContent = result.loginRequired
      ? `${expected}${commentLoginWallNote(result.platform, result.items.length, result.limit)}`
      : `${expected}只保存勾选的评论；条数可在汲作设置里改。`;
    selectedCommentIDs = () => Array.from(commentsList.querySelectorAll<HTMLInputElement>("input[type='checkbox']:checked"))
      .map((box) => box.value);
    refresh();
  };

  const fetchPageStatus = async (): Promise<PageStatus> => {
    if (!previewPageURL) return { kind: "unavailable" };
    try {
      return (await browser.runtime.sendMessage({ type: "page-status", url: previewPageURL }) as PageStatus | undefined)
        ?? { kind: "unavailable" };
    } catch {
      return { kind: "unavailable" };
    }
  };

  /** 打开弹窗时查重：存过就先给「做到哪了」，保存区收起来，要再存一份点按钮。 */
  const checkDuplicate = async (): Promise<void> => {
    const status = await fetchPageStatus();
    if (status.kind !== "found" || !savedView.hidden) return;
    knownTaskID = status.taskID;
    setAvailability("ready", "已存过");
    dupDate.textContent = popupSavedAtLabel(status.savedAt);
    renderStepRows(dupSteps, popupStepProgress({ steps: status.steps, expected: new Set(), hasVideo: pageHasVideo }));
    dupView.hidden = false;
    actionCard.hidden = true;
    commentsPicker.hidden = true;
    send.hidden = true;
    openApp.textContent = "在汲作里打开";
    saveAgain.hidden = false;
    saveAgain.onclick = () => {
      dupView.hidden = true;
      actionCard.hidden = false;
      commentsPicker.hidden = commentPlan === "unsupported";
      send.hidden = false;
      resultActions.hidden = true;
      setAvailability("ready", "再存一份");
    };
    resultActions.replaceChildren(closePopup, saveAgain, openApp);
    openApp.hidden = false;
    resultActions.hidden = false;
  };

  /** 保存后看进度：每 1.5 秒问一次，都做完（没有等着做 / 进行中）或 2 分钟后停。 */
  const followProgress = (): void => {
    const expected = expectedSteps();
    let rounds = 0;
    const tick = async (): Promise<void> => {
      rounds += 1;
      const status = await fetchPageStatus();
      if (status.kind === "found") {
        knownTaskID = status.taskID;
        const rows = popupStepProgress({ steps: status.steps, expected, hasVideo: pageHasVideo })
          .filter((row) => row.state !== "manual" || row.key === "summary" || row.key === "mindMap");
        renderStepRows(savedSteps, rows);
        savedSteps.hidden = rows.length === 0;
        // 评论条数以 App 记下的为准，上面那句不再单独说。
        if (rows.length > 0) savedDetail.textContent = popupActionPresentation(selectedAction).success;
        if (!rows.some((row) => row.state === "waiting" || row.state === "running")) return;
      } else if (status.kind === "unavailable" && rounds > 2) {
        return;
      }
      if (rounds < 80) setTimeout(() => { void tick(); }, 1_500);
    };
    void tick();
  };

  const startCommentPicker = (): void => {
    commentsPicker.hidden = false;
    commentsCount.textContent = "正在读取评论…";
    commentsNote.textContent = "会自动往下翻评论区加载评论，读完后页面回到原位置。";
    commentsSelectAll.hidden = true;
    commentsSelectNone.hidden = true;
    commentsLoading = (async () => {
      let result: CommentCollectResult;
      try {
        result = await browser.runtime.sendMessage({ type: "collect-comments", tabId }) as CommentCollectResult;
      } catch {
        result = { ok: false, code: "failed" };
      }
      renderCommentPicker(result ?? { ok: false, code: "failed" });
      commentsLoading = null;
    })();
  };

  try {
    const preview = await browser.runtime.sendMessage({
      type: "preview-current-page",
      tabId,
    }) as SafeCapturePreview;
    const avail = popupAvailability(preview);
    setAvailability(avail.tone, avail.label);
    previewTitle = preview.title;
    renderPlatform(popupSourceLine(preview.platform, preview.version, preview.imageCount, preview.host));
    status.textContent = preview.title;
    renderMeta([]);
    const isVideo = preview.version === 2 && !(preview.imageCount && preview.imageCount > 0);
    videoThumb.hidden = !isVideo;
    videoDuration.textContent = isVideo && preview.mediaDurationSeconds ? popupDuration(preview.mediaDurationSeconds) : "";
    const byline = popupBylineText(preview.mediaAuthor ?? preview.sourceAuthor, preview.published);
    author.textContent = byline;
    author.hidden = byline.length === 0;
    excerpt.textContent = preview.excerpt ?? "";
    excerpt.hidden = !preview.excerpt;
    renderStats(popupStats(preview));
    sourceNote.hidden = preview.usedCookie !== true;
    translationNote.textContent = preview.pageTranslatedBy ? popupTranslationNote(preview.pageTranslatedBy) : "";
    translationNote.hidden = !preview.pageTranslatedBy;
    pageHasVideo = isVideo;
    previewLoaded = true;
    pagePlatform = preview.platform;
    previewPageURL = preview.pageURL;
    renderStepChain();
    void checkDuplicate();
    renderMetadataDiagnostic(preview.metadataDiagnostic);
    if (avail.tone === "blocked") {
      send.disabled = true;
      send.textContent = "暂不支持此平台";
    } else {
      // 预览成功才启用。按钮初始 disabled（见 index.html 注释）：onclick 在这段
      // 顶层 await 之后才挂上，提前可点等于点了没反应。
      send.textContent = popupActionPresentation(selectedAction).button;
      send.disabled = false;
      startCommentPicker();
    }
  } catch (cause) {
    status.textContent = tab?.title || "当前页面";
    try {
      if (tab?.url) renderPlatform(new URL(tab.url).hostname.replace(/^www\./u, ""));
    } catch {
      // 没有可读地址时不显示来源行。
    }
    setAvailability("blocked", "读不到正文");
    // 这里原本把原因整个吞掉，界面上只剩一句没有信息量的提示，排查时等于没有线索。
    // 把真实 message 亮出来：CAPTURE_CONTENT_EMPTY 是抓到了页面但没有正文，
    // "Cannot access contents of url…" 是注入被拒，两者的修法完全不同。
    const message = cause instanceof Error ? cause.message : String(cause);
    const browserPage = popupBrowserPageFailure(tab?.url);
    const failure = browserPage ?? popupPreviewFailure(message);
    if (browserPage) renderPlatform("浏览器页面");
    actionCard.hidden = true;
    failureTitle.textContent = failure.title;
    failureMessage.textContent = failure.message;
    failureSteps.replaceChildren();
    for (const step of failure.steps) {
      const li = document.createElement("li");
      li.textContent = step;
      failureSteps.append(li);
    }
    failureView.hidden = false;
    send.hidden = true;
    if (failure.canReload) {
      recoveryMode = "reload";
      recoveryAction.textContent = "重新读取";
      showResultActions(recoveryAction);
    } else {
      recoveryMode = null;
      recoveryAction.hidden = true;
      openApp.textContent = "打开汲作";
      showResultActions(message.includes("CAPTURE_LOGIN_WALL") ? openApp : null);
    }
  }

  const sendOnce = (): Promise<SafeExtensionSendResult> => browser.runtime.sendMessage({
    type: "send-current-page",
    tabId,
    requestedAction: selectedAction,
    selectedCommentIDs: selectedCommentIDs(),
    ...(commentMode ? { commentMode } : {}),
  }) as Promise<SafeExtensionSendResult>;

  /** 一次保存的结果落到界面上；afterOpen = 已经点过「打开汲作并重试」，再连不上就给最后的说明。 */
  const applySendResult = (result: SafeExtensionSendResult, afterOpen: boolean): void => {
    commentsPicker.hidden = true;
    renderMetadataDiagnostic(result.metadataDiagnostic);
    const recovery = popupRecoveryForSendResult(result);
    if (recovery) {
      error.textContent = afterOpen && recovery.action === "open_app_retry" ? connectionCopy.gaveUp : recovery.message;
      send.hidden = true;
      if (recovery.action === "open_app" || recovery.action === "open_settings") {
        openApp.textContent = recovery.label;
        openApp.hidden = false;
      } else if (recovery.action === "retry" || recovery.action === "reload" || recovery.action === "open_app_retry") {
        recoveryMode = recovery.action;
        recoveryAction.textContent = recovery.label;
        recoveryAction.hidden = false;
      }
    } else {
      // 保存成功：来源卡换成一张结果卡，盖一枚「汲」印（2026-09-29 弹窗重构）。
      recoveryAction.hidden = true;
      actionCard.hidden = true;
      sourceCard.hidden = true;
      send.hidden = true;
      savedSeal.innerHTML = stampedSealMarkup(56);
      savedTitle.textContent = previewTitle || "已保存";
      savedDetail.textContent = [
        popupActionPresentation(selectedAction).success,
        savedCommentsLine(),
      ].filter(Boolean).join("\n");
      savedView.hidden = false;
      setAvailability("ready", "已保存");
      openApp.textContent = "在汲作里打开";
      showResultActions(openApp);
      followProgress();
    }
  };

  const showSendCaught = (cause: unknown): void => {
    renderMetadataDiagnostic(undefined);
    error.textContent = popupCaughtFailure(cause, "保存失败，请重试。");
    send.hidden = true;
    recoveryMode = "retry";
    recoveryAction.textContent = "重试保存";
    recoveryAction.hidden = false;
  };

  const submit = async () => {
    send.disabled = true;
    send.classList.remove("done");
    error.textContent = "";
    resultNotice.hidden = true;
    recoveryAction.hidden = true;
    openApp.hidden = true;
    renderMetadataDiagnostic(undefined);
    try {
      if (commentsLoading) {
        send.textContent = "等评论读取完…";
        await commentsLoading;
      }
      send.textContent = commentMode?.kind === "auto" ? "正在读取评论并保存…" : "正在保存…";
      // 只有确定没送到汲作的快速失败才自动再试（见 popup-connection.ts），超时不重发，免得存两份。
      const result = await withConnectionRetry(sendOnce, sendRetryVerdict, {
        onRetry: () => { send.textContent = connectionCopy.connecting; },
      });
      applySendResult(result, false);
    } catch (cause) {
      showSendCaught(cause);
    }
  };

  /** 「打开汲作并重试」：让 Host 拉起汲作，稍等再保存一次。 */
  const openAppAndResend = async (): Promise<void> => {
    recoveryAction.disabled = true;
    recoveryAction.textContent = connectionCopy.opening;
    error.textContent = "";
    try {
      const outcome = await openAppThenRetry(requestOpenApp, sendOnce);
      if (outcome.kind === "retried") {
        applySendResult(outcome.result, true);
      } else {
        error.textContent = outcome.kind === "upgrade" ? connectionCopy.upgrade : connectionCopy.gaveUp;
        recoveryAction.textContent = connectionCopy.openRetryLabel;
      }
    } catch (cause) {
      showSendCaught(cause);
    } finally {
      recoveryAction.disabled = false;
    }
  };
  send.onclick = submit;
  recoveryAction.onclick = () => {
    if (recoveryMode === "reload") window.location.reload();
    else if (recoveryMode === "open_app_retry") void openAppAndResend();
    else {
      send.hidden = false;
      void submit();
    }
  };
  openApp.addEventListener("click", (event) => {
    // 不能靠 <a href="linkdigest://open">：Launch Services 的默认 scheme 绑定
    // 在本机上会打到过期声明，正在跑的汲作不会到前台。走 Host 用同包路径 open；
    // 知道是哪一条时带上 id，汲作直接打开它。
    event.preventDefault();
    void browser.runtime.sendMessage({ type: "open-app", ...(knownTaskID ? { taskID: knownTaskID } : {}) });
  });
}
