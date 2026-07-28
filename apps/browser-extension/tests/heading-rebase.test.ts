import { describe, expect, it } from "vitest";
import { rebaseHeadingLevels } from "../src/content/extract";

/**
 * 出口归一化：来源页面怎么写标题，都不该影响产出的层级结构。
 *
 * 起因是 support.claude.com 一篇 852 字的帮助页，正文里有 4 个 h1——阅读区把
 * 条目标题按 h1 显示，正文再出现 h1 就是第二个「文档标题」，四段全渲染成 23pt。
 * 这不是那个站点的问题，是出口没有归一化；换任何用 h1 分节的站都一样。
 */
describe("rebaseHeadingLevels", () => {
  it("把 h1 起的文档整体下移到 h2，相对层级差保持不变", () => {
    const input = [
      "# 如何兑换您的礼品",
      "",
      "正文",
      "",
      "# 故障排除",
      "",
      "## 我看不到兑换电子邮件",
      "",
      "### 更细的一级",
    ].join("\n");

    expect(rebaseHeadingLevels(input)).toBe(
      [
        "## 如何兑换您的礼品",
        "",
        "正文",
        "",
        "## 故障排除",
        "",
        "### 我看不到兑换电子邮件",
        "",
        "#### 更细的一级",
      ].join("\n"),
    );
  });

  it("已经从 h2 起的文档一个字都不动", () => {
    const input = "## 小节\n\n正文\n\n### 更深";
    expect(rebaseHeadingLevels(input)).toBe(input);
  });

  it("没有标题时原样返回", () => {
    const input = "只有正文，没有任何标题。\n\n第二段。";
    expect(rebaseHeadingLevels(input)).toBe(input);
  });

  // 这条是整个函数最重要的约束：改错了是**破坏内容**，比排版难看严重得多。
  it("不碰围栏代码块里的井号——那是代码注释不是标题", () => {
    const input = [
      "# 安装",
      "",
      "```bash",
      "# 这是 shell 注释，必须原样保留",
      "brew install foo",
      "```",
      "",
      "# 使用",
    ].join("\n");

    const output = rebaseHeadingLevels(input);
    expect(output).toContain("# 这是 shell 注释，必须原样保留");
    expect(output).not.toContain("## 这是 shell 注释");
    expect(output).toContain("## 安装");
    expect(output).toContain("## 使用");
  });

  it("代码块里的井号不参与「最浅层级」的计算", () => {
    // 正文本身从 h2 起；代码块里有个 `#`，若被算进去会导致整篇被误下移一级。
    const input = ["## 小节", "", "```py", "# comment", "```"].join("\n");
    expect(rebaseHeadingLevels(input)).toBe(input);
  });

  it("下移后不产生超过 h6 的非法标题", () => {
    const input = "# 一\n\n###### 六";
    const output = rebaseHeadingLevels(input);
    expect(output).toContain("## 一");
    expect(output).toContain("###### 六");
    expect(output).not.toMatch(/#{7,}/);
  });

  it("`#` 后面没有内容的行不算标题", () => {
    const input = "#\n\n## 真标题";
    expect(rebaseHeadingLevels(input)).toBe(input);
  });
});
