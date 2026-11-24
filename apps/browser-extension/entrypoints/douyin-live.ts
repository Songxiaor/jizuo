import { parseDouyinLiveRoom } from "../src/content/douyin-live";

/**
 * 注入直播间页面读取房间数据。和 extract-page 一样走打包文件，解析逻辑只有
 * `src/content/douyin-live.ts` 一份，单测和生产跑的是同一段代码。
 *
 * 房间数据在页面已经渲染出来的 HTML 里，不需要登录、不调用隐藏接口，也不读
 * Cookie。播放器实际请求过的流地址只作为兜底：它只能告诉我们在播的那一档。
 */
export default defineUnlistedScript(() => {
  const resourceURLs = (() => {
    try {
      return performance
        .getEntriesByType("resource")
        .map((entry) => entry.name)
        .filter((name) => /\.(?:flv|m3u8)(?:[?#]|$)/u.test(name));
    } catch {
      return [];
    }
  })();
  return parseDouyinLiveRoom(document.documentElement.innerHTML, {
    pageURL: location.href,
    title: document.title,
    resourceURLs,
  });
});
