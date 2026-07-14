export type ExtractedPage = { title: string; url: string; text: string; characterCount: number; method: "selection" | "rendered_dom" };

export function extractCurrentPage(documentLike: Document = document): ExtractedPage {
  const selection = documentLike.defaultView?.getSelection()?.toString() ?? "";
  let rawText = selection;
  if (!selection.trim()) {
    const source = documentLike.querySelector("article, main") ?? documentLike.body;
    const clone = source && "cloneNode" in source ? source.cloneNode(true) as Element : null;
    clone?.querySelectorAll("script, style, noscript").forEach((node) => node.remove());
    rawText = clone?.textContent ?? source?.textContent ?? "";
  }
  const text = rawText.replace(/\s+/gu, " ").trim();
  return { title: documentLike.title, url: documentLike.location.href, text, characterCount: [...text].length, method: selection.trim() ? "selection" : "rendered_dom" };
}

// Chrome serializes this function before injecting it. Keep it self-contained:
// references to module-level helpers do not exist in the page execution world.
export function extractPageInIsolatedWorld(): ExtractedPage {
  const selection = document.defaultView?.getSelection()?.toString() ?? "";
  let rawText = selection;
  if (!selection.trim()) {
    const source = document.querySelector("article, main") ?? document.body;
    const clone = source?.cloneNode(true) as Element | null;
    clone?.querySelectorAll("script, style, noscript").forEach((node) => node.remove());
    rawText = clone?.textContent ?? source?.textContent ?? "";
  }
  const text = rawText.replace(/\s+/gu, " ").trim();
  return { title: document.title, url: document.location.href, text, characterCount: [...text].length, method: selection.trim() ? "selection" : "rendered_dom" };
}
