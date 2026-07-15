import type { NativeResponse } from "./contract";

const storageMessages: Readonly<Record<string, string>> = {
  STORAGE_UNAVAILABLE: "本地存储暂时不可用，请打开 LinkDigest 后重试。",
  STORAGE_WRITE_FAILED: "本地历史保存失败，请稍后重试。",
  STORAGE_FUTURE_SCHEMA: "本地历史由更新版本创建，请升级 LinkDigest。",
  STORAGE_MIGRATION_FAILED: "本地历史升级未完成，请重新打开 LinkDigest。",
  STORAGE_READ_ONLY: "本地历史当前只读，无法保存新内容。",
  STORAGE_INTEGRITY_FAILED: "本地历史完整性检查失败，请停止写入。",
  STORAGE_STATE_CONFLICT: "本地历史状态已变化，请重新发送。",
  CAPTURE_IDEMPOTENCY_CONFLICT: "本次页面传输与原请求不一致，请重新发送。",
  RUN_IDEMPOTENCY_CONFLICT: "本次运行与原请求不一致，请重新操作。",
};

export function popupMessageForResponse(response: NativeResponse): string | null {
  if (response.kind !== "error") return null;
  return storageMessages[response.error.code] ?? "操作未完成，请重试。";
}
