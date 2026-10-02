/**
 * Community post profiles live outside the extractor so platform DOM evidence
 * stays reviewable and cannot leak into the generic article selector list.
 * Selectors describe only already-rendered public DOM; they do not trigger
 * scrolling, cookie access or hidden API requests.
 */
export type CommunityPlatform = "hacker-news" | "v2ex" | "stack-overflow" | "dev-to" | "discourse";

export type CommunityProfile = {
  platform: CommunityPlatform;
  label: string;
  title: readonly string[];
  body: readonly string[];
  author: readonly string[];
  published: readonly string[];
  comments: readonly string[];
  commentBody: readonly string[];
  commentAuthor: readonly string[];
  commentPublished: readonly string[];
};

export const COMMUNITY_PROFILES: Readonly<Record<CommunityPlatform, CommunityProfile>> = {
  "hacker-news": {
    platform: "hacker-news", label: "Hacker News",
    title: [".titleline a", ".titleline"], body: [".toptext"],
    author: [".subtext .hnuser", ".hnuser"], published: [".subtext .age", ".age"],
    comments: ["tr.comtr"], commentBody: [".commtext"],
    commentAuthor: [".hnuser"], commentPublished: [".age"],
  },
  v2ex: {
    platform: "v2ex", label: "V2EX",
    title: ["h1"], body: [".topic_content .markdown_body", ".topic_content"],
    author: [".topic_info a", ".header small a"], published: [".topic_info", ".header small"],
    comments: ["[id^='r_']"], commentBody: [".reply_content"],
    commentAuthor: [".dark"], commentPublished: [".ago"],
  },
  "stack-overflow": {
    platform: "stack-overflow", label: "Stack Overflow",
    title: ["#question-header h1", "h1"], body: ["#question .js-post-body", "#question"],
    // 被编辑过的帖子有两张署名卡：前一张是最后编辑的人，最后一张才是提问者 / 回答者
    // （提问者那张带 owner）。原来取第一张，作者全成了编辑者（2026-10-03）。
    author: ["#question .post-signature.owner .user-details a", "#question .post-signature:last-child .user-details a", "#question .user-details a", "#question [itemprop='name']"],
    published: ["#question .post-signature.owner .relativetime", "#question time", "#question .relativetime"],
    comments: ["#question .comment", ".answer", ".answer .comment"],
    commentBody: [".comment-copy", ".js-post-body"],
    // 回答的署名卡排在它自己的评论前面取：回答里也有评论，先取 .comment-user 会把评论者当成回答者。
    commentAuthor: [".post-signature:last-child .user-details a", ".comment-user", ".user-details a"],
    commentPublished: [".post-signature:last-child .relativetime", "time", ".relativetime"],
  },
  "dev-to": {
    platform: "dev-to", label: "dev.to",
    // `#main-title` is the whole header in the current DEV DOM. Selecting it
    // directly mixes the author, reactions and tags into the saved title.
    title: ["#main-title h1", "h1"], body: ["#article-body", ".crayons-article__body"],
    author: [".crayons-article__header__meta .crayons-link.fw-bold", ".crayons-article__header__meta a"], published: ["time"],
    comments: ["#comments-container .comment"], commentBody: [".comment__body", ".js-comment"],
    commentAuthor: [".comment__header a"], commentPublished: ["time"],
  },
  discourse: {
    platform: "discourse", label: "Discourse",
    title: ["#topic-title h1", "h1"], body: ["#post_1 .cooked", ".topic-post:first-of-type .cooked"],
    author: ["#post_1 [data-user-card]", "#post_1 .username"], published: ["#post_1 time"],
    comments: ["article[id^='post_']", ".topic-post"], commentBody: [".cooked"],
    commentAuthor: ["[data-user-card]", ".username"], commentPublished: ["time"],
  },
};

export function communityPlatformForURL(rawURL: string): CommunityPlatform | undefined {
  try {
    const url = new URL(rawURL);
    const host = url.hostname.toLowerCase().replace(/^www\./u, "");
    if (host === "news.ycombinator.com" && url.pathname === "/item" && /^\d+$/u.test(url.searchParams.get("id") ?? "")) {
      return "hacker-news";
    }
    if (host === "v2ex.com" && /^\/t\/\d+(?:\/|$)/u.test(url.pathname)) return "v2ex";
    if (host === "stackoverflow.com" && /^\/questions\/\d+(?:\/|$)/u.test(url.pathname)) return "stack-overflow";
    if (host === "dev.to" && /^\/[^/]+\/[^/]+/u.test(url.pathname)) return "dev-to";
    if ((host === "linux.do" || host === "uscardforum.com") && /^\/t\/[^/]+\/\d+(?:\/|$)/u.test(url.pathname)) {
      return "discourse";
    }
  } catch {
    // Invalid URLs stay on the generic extractor.
  }
  return undefined;
}
