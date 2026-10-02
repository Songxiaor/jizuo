import { captureYouTubeVideoInPage } from "../src/content/youtube-capture";

/**
 * YouTube 单条视频抓取的注入入口（MAIN world）。扩展和 App「添加链接」共用这一份打包产物，
 * 理由同 `extract-page.ts`：一份实现，不再维护第二份拷贝。
 */
export default defineUnlistedScript(() => captureYouTubeVideoInPage());
