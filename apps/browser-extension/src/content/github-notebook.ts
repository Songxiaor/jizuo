import type { ExtractedPage } from "./extract";

/**
 * GitHub 上的 Jupyter 笔记本（.ipynb）。
 *
 * GitHub 把笔记本放在跨域 iframe 里渲染，页面 DOM 只剩文件外壳：扩展原来只存下 1599 字；
 * App 走 raw 文件则把整份 JSON 原样存进正文（2026-10-02 抓取完整度测试）。
 * 这里从同一个公开 raw 地址取回笔记本，转成 Markdown：说明单元原样、代码单元进代码块、
 * 文本输出附在代码后面。扩展和 App「添加链接」执行的是同一份打包产物。
 */
/** github.com 上 blob 页面对应的公开 raw 地址；不是 blob 页面返回 undefined。 */
export function gitHubBlobRawURL(href: string): string | undefined {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return undefined;
  }
  if (url.hostname !== "github.com" && url.hostname !== "www.github.com") return undefined;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 5 || parts[2] !== "blob") return undefined;
  const [owner, repo, , ref, ...path] = parts;
  return `https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${path.join("/")}`;
}

export function gitHubNotebookRawURL(href: string): string | undefined {
  const raw = gitHubBlobRawURL(href);
  return raw && raw.toLowerCase().endsWith(".ipynb") ? raw : undefined;
}

/**
 * 代码文件的语言（与 App 的 `GitHubFileLocation.codeLanguage` 同一张表）。GitHub 的代码页是
 * 前端渲染的编辑器外壳，原来抓到的是按钮和报错文字（2026-10-02 抓取完整度测试）。
 */
const CODE_LANGUAGES: Record<string, string> = {
  py: "python", js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "jsx",
  ts: "typescript", tsx: "tsx", swift: "swift", go: "go", rs: "rust", java: "java",
  kt: "kotlin", kts: "kotlin", rb: "ruby", php: "php", c: "c", h: "c", cc: "cpp",
  cpp: "cpp", hpp: "cpp", m: "objectivec", mm: "objectivec", cs: "csharp", scala: "scala",
  sh: "bash", bash: "bash", zsh: "bash", fish: "fish", ps1: "powershell", lua: "lua",
  r: "r", dart: "dart", sql: "sql", json: "json", jsonc: "json", yaml: "yaml",
  yml: "yaml", toml: "toml", xml: "xml", html: "html", css: "css", scss: "scss",
  vue: "vue", svelte: "svelte", zig: "zig", ex: "elixir", exs: "elixir", hs: "haskell",
  ml: "ocaml", clj: "clojure", pl: "perl", proto: "protobuf", graphql: "graphql",
  dockerfile: "dockerfile", makefile: "makefile", gradle: "groovy", tf: "hcl",
};
const PROSE_EXTENSIONS = new Set(["md", "markdown", "mdx", "txt", "rst"]);
/** 再大的文件就不整份搬进正文，交回页面提取。 */
const RAW_TEXT_LIMIT = 400_000;

const joinSource = (value: unknown): string =>
  Array.isArray(value) ? value.map((part) => String(part ?? "")).join("") : String(value ?? "");

function fenced(code: string, language: string): string {
  const longest = Math.max(0, ...(code.match(/`+/gu) ?? []).map((run) => run.length));
  const fence = "`".repeat(Math.max(3, longest + 1));
  return `${fence}${language}\n${code.replace(/\n+$/u, "")}\n${fence}`;
}

/** 每个输出最多留这么多字：训练日志一类的输出动辄几万行，不是正文。 */
const OUTPUT_LIMIT = 4_000;

export function notebookToMarkdown(notebook: unknown): string | undefined {
  if (!notebook || typeof notebook !== "object") return undefined;
  const record = notebook as { cells?: unknown; metadata?: { kernelspec?: { language?: unknown }; language_info?: { name?: unknown } } };
  if (!Array.isArray(record.cells)) return undefined;
  const language = String(record.metadata?.kernelspec?.language ?? record.metadata?.language_info?.name ?? "python");
  const blocks: string[] = [];
  for (const raw of record.cells) {
    const cell = raw as { cell_type?: unknown; source?: unknown; outputs?: unknown };
    const source = joinSource(cell.source).replace(/\s+$/u, "");
    if (!source.trim()) continue;
    if (cell.cell_type === "markdown") {
      blocks.push(source);
    } else if (cell.cell_type === "code") {
      blocks.push(fenced(source, language));
      const outputs = Array.isArray(cell.outputs) ? cell.outputs : [];
      const text = outputs.map((output) => {
        const item = output as { output_type?: unknown; text?: unknown; data?: Record<string, unknown> };
        if (item.output_type === "stream") return joinSource(item.text);
        if (item.data && "text/plain" in item.data) return joinSource(item.data["text/plain"]);
        return "";
      }).join("\n").trim();
      if (text) {
        const clipped = text.length > OUTPUT_LIMIT ? `${text.slice(0, OUTPUT_LIMIT)}\n…（输出过长，已截断）` : text;
        blocks.push(fenced(clipped, "text"));
      }
    } else {
      blocks.push(source);
    }
  }
  const markdown = blocks.join("\n\n").trim();
  return markdown || undefined;
}

/**
 * GitHub 文件页：从公开 raw 地址取原文件。笔记本转 Markdown，代码文件放进对应语言的代码块
 * （标题用文件名，`#` 注释不会被当成标题），Markdown/纯文本原样。图片、PDF 等交回页面提取。
 */
export async function extractGitHubBlobPage(documentLike: Document): Promise<ExtractedPage | undefined> {
  const href = documentLike.location.href;
  const rawURL = gitHubBlobRawURL(href);
  if (!rawURL) return undefined;
  const fileName = decodeURIComponent(rawURL.split("/").pop() ?? "");
  const extension = fileName.includes(".") ? fileName.split(".").pop()!.toLowerCase() : fileName.toLowerCase();
  const language = CODE_LANGUAGES[extension];
  const isNotebook = extension === "ipynb";
  if (!isNotebook && !language && !PROSE_EXTENSIONS.has(extension)) return undefined;
  try {
    const response = await fetch(rawURL, { credentials: "omit" });
    if (!response.ok) return undefined;
    let text: string | undefined;
    let title = fileName;
    if (isNotebook) {
      text = notebookToMarkdown(await response.json());
      title = text?.match(/^#\s+(.+)$/mu)?.[1]?.trim() || fileName;
    } else {
      const raw = await response.text();
      if (!raw.trim() || raw.length > RAW_TEXT_LIMIT) return undefined;
      if (language) {
        text = fenced(raw, language);
      } else {
        text = raw.trim();
        title = text.match(/^#\s+(.+)$/mu)?.[1]?.trim() || fileName;
      }
    }
    if (!text) return undefined;
    return {
      title,
      url: href.split("#")[0]!,
      text,
      characterCount: [...text].length,
      method: "rendered_dom",
      platform: "github",
      completeness: "full_article",
    };
  } catch {
    return undefined;
  }
}
