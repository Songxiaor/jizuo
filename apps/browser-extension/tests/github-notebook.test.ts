import { describe, expect, it, vi } from "vitest";
import { gitHubNotebookRawURL, notebookToMarkdown } from "../src/content/github-notebook";

describe("GitHub notebook capture (2026-10-02)", () => {
  it("maps a blob .ipynb page to its public raw file and ignores everything else", () => {
    expect(gitHubNotebookRawURL("https://github.com/anthropics/claude-cookbooks/blob/main/claude_agent_sdk/08_Dynamic_workflows.ipynb"))
      .toBe("https://raw.githubusercontent.com/anthropics/claude-cookbooks/main/claude_agent_sdk/08_Dynamic_workflows.ipynb");
    expect(gitHubNotebookRawURL("https://github.com/a/b/blob/main/README.md")).toBeUndefined();
    expect(gitHubNotebookRawURL("https://gitlab.com/a/b/blob/main/x.ipynb")).toBeUndefined();
  });

  it("turns cells into readable markdown: prose as-is, code fenced, text output after its code", () => {
    const markdown = notebookToMarkdown({
      metadata: { kernelspec: { language: "python" } },
      cells: [
        { cell_type: "markdown", source: ["# 标题\n", "\n", "一段说明。"] },
        { cell_type: "code", source: ["print('hi')"], outputs: [{ output_type: "stream", text: ["hi\n"] }] },
        { cell_type: "code", source: [""], outputs: [] },
      ],
    });
    expect(markdown).toBe("# 标题\n\n一段说明。\n\n```python\nprint('hi')\n```\n\n```text\nhi\n```");
    expect(notebookToMarkdown({ nbformat: 4 })).toBeUndefined();
  });
});

describe("GitHub blob files (2026-10-02)", () => {
  it("maps any blob page to its raw file", async () => {
    const { gitHubBlobRawURL } = await import("../src/content/github-notebook");
    expect(gitHubBlobRawURL("https://github.com/anthropics/anthropic-sdk-python/blob/main/examples/messages.py"))
      .toBe("https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/examples/messages.py");
    expect(gitHubBlobRawURL("https://github.com/anthropics/anthropic-sdk-python")).toBeUndefined();
  });

  it("fences code files with their language and titles them by file name", async () => {
    const { extractGitHubBlobPage } = await import("../src/content/github-notebook");
    vi.stubGlobal("fetch", async () => ({ ok: true, text: async () => "# 发一条消息\nprint('hi')\n", json: async () => ({}) }));
    try {
      const page = await extractGitHubBlobPage({ location: { href: "https://github.com/a/b/blob/main/examples/messages.py" } } as unknown as Document);
      expect(page?.title).toBe("messages.py");
      expect(page?.text).toBe("```python\n# 发一条消息\nprint('hi')\n```");
      const image = await extractGitHubBlobPage({ location: { href: "https://github.com/a/b/blob/main/logo.png" } } as unknown as Document);
      expect(image).toBeUndefined();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
