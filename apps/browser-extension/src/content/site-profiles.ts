/**
 * 站点档案：一个站点的抽取差异，全部收敛成这一份数据。
 *
 * 改这套之前，通用路径里的站点特化散在六个地方：`HOST_CONTENT_ROOT` 表、
 * `pickContentRoot` 的选择器清单、`resolveTitle` 的 GitHub 与公众号分支、
 * 知乎的元数据分支、作者与时间的兜底链。加一个站点要在这几处分别下手，
 * 而漏掉其中一处不会报错——只表现为「这个站抓出来少一块」。
 *
 * 这个形状抄自 Swift 侧的 `SiteSessionProfile`，那边的注释把理由写得很清楚：
 *
 * > 加第二个站点只能整份复制。复制出来的副本会各自漂移，而这类漂移不会报错
 * > 也不会崩，只会表现成「登录了但没生效」，最难查。
 *
 * 目标是让「加一个站点」等于「加一条数据」，核心代码不认识任何具体站点。
 *
 * 注意：X / 抖音 / B站 / 小红书**不在这里**。它们不是文章形态，是以媒体为主的
 * 社交内容，各有独立的抽取函数——用文章抽取器去套本来就不对，硬塞进这张表
 * 只会让表结构被少数几个特例撑变形。
 */
export type SiteProfile = {
  /** 档案名，仅用于测试与排错，不参与匹配。 */
  readonly id: string;
  /** 匹配 host（已小写、已去掉末尾点）。 */
  readonly matches: (host: string) => boolean;
  /**
   * 正文根选择器，按优先级。命中后仍要求文本够长，否则退回通用候选——
   * 宁可用通用路径，也不产出一个空壳正文。
   */
  readonly contentRoot?: readonly string[];
  /** 标题选择器，优先于通用的 h1 / og:title。 */
  readonly title?: readonly string[];
  /** 作者选择器。 */
  readonly author?: readonly string[];
  /** 发布时间选择器。 */
  readonly published?: readonly string[];
};

const hostSuffix =
  (...suffixes: string[]) =>
  (host: string) =>
    suffixes.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));

/**
 * 顺序即优先级：第一个 `matches` 命中的档案生效。
 *
 * 每条都应当有现场证据支撑，注释写清「为什么这个站需要特化」——没有证据的
 * 猜测性选择器会长期留在表里，谁也不敢删。
 */
export const SITE_PROFILES: readonly SiteProfile[] = [
  {
    // 头条的 `.article-content` 比 `article` 多出「标题」和「时间·来源」两行。
    // 2026-07-26 真机实测两篇：1321→1278、205→165 字符，差值正是这两行。
    id: "toutiao",
    matches: hostSuffix("toutiao.com"),
    contentRoot: ["article"],
  },
  {
    // 公众号正文在 `#js_content`；`#img-content` 是图文消息的外层。
    // 标题用 `#activity-name`：页面 h1 常是空的或站点名。
    id: "wechat",
    matches: hostSuffix("weixin.qq.com"),
    contentRoot: ["#js_content", "#img-content"],
    title: ["#activity-name"],
    author: ["#js_name", "a.rich_media_meta_link"],
    published: ["#publish_time"],
  },
  {
    id: "zhihu",
    matches: hostSuffix("zhihu.com"),
    contentRoot: [".Post-RichText", ".RichText.ztext"],
  },
  {
    // Substack 及其自定义域名的正文容器。
    id: "substack",
    matches: hostSuffix("substack.com"),
    contentRoot: [".available-content"],
  },
];

export function siteProfile(host: string): SiteProfile | undefined {
  const normalized = host.toLowerCase().replace(/\.+$/, "");
  if (!normalized) return undefined;
  return SITE_PROFILES.find((profile) => profile.matches(normalized));
}

/**
 * 不属于任何站点的通用候选，按优先级。
 *
 * 这里只放**跨站点通用**的语义标记：`article`、`main`、微数据。带站点色彩的
 * 类名一律进 `SITE_PROFILES`——混在这里就等于通用路径认识具体站点，
 * 清单会一直变长而没人敢删。
 */
export const GENERIC_CONTENT_ROOTS: readonly string[] = [
  "[itemprop='articleBody']",
  // `.article-content` 是常见 CMS 约定而不是某个站专有，属于通用候选。
  // 它排在 `article` 之前是有依据的：央视新闻那类页面用它才能拿到完整正文。
  // 头条恰恰相反——那边这个类比 `article` 多出「标题」和「时间·来源」两行，
  // 所以头条档案里显式指定 `article` 把它压下去。
  ".article-content",
  "article",
  "main",
];
