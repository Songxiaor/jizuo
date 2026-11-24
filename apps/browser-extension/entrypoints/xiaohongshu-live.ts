import {
  parseXiaohongshuPullConfig,
  xiaohongshuAnchorInfo,
  xiaohongshuRoomID,
} from "../src/content/xiaohongshu-live";

/**
 * 注入小红书直播间读取运行时状态。首屏 HTML 里 `pullConfig` 还是空骨架，
 * 页面 JS 拉完数据（约 6 秒）才有值；后台会隔一会儿重试。
 */
export default defineUnlistedScript(() => {
  const state = (window as unknown as {
    __INITIAL_STATE__?: {
      liveStream?: {
        roomData?: {
          _rawValue?: {
            roomInfo?: {
              pullConfig?: unknown;
              host?: unknown;
              host_name?: unknown;
              deeplink?: { flvUrl?: unknown };
            };
            hostInfo?: unknown;
          };
        };
      };
    };
  }).__INITIAL_STATE__;
  const room = state?.liveStream?.roomData?._rawValue?.roomInfo;
  const hostInfo = state?.liveStream?.roomData?._rawValue?.hostInfo;
  const pull = typeof room?.pullConfig === "string" ? room.pullConfig : "";
  const deeplink = typeof room?.deeplink?.flvUrl === "string" ? room.deeplink.flvUrl : undefined;
  const variants = parseXiaohongshuPullConfig(pull, deeplink);
  const roomID = xiaohongshuRoomID(location.href);
  if (!roomID || variants.length === 0) return null;
  // 线上版本把主播放在 roomData.hostInfo（nickName / userId / avatar），
  // roomInfo.host 只在部分版本里出现，两个都读。
  const anchor = xiaohongshuAnchorInfo(hostInfo ?? room?.host, room?.host_name);
  return {
    pageURL: location.href,
    roomID,
    ...anchor,
    ...(document.title ? { title: document.title } : {}),
    variants,
  };
});
