import { describe, expect, it } from "vitest";
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
