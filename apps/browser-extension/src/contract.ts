import validateWireSchema, { type SchemaValidationError } from "./generated/capture-validator.mjs";

export const MAX_CAPTURE_TEXT_SCALARS = 2_000_000;
export type CaptureRequestedAction = "save" | "summarize" | "translate";
export type CapturePlatform = "generic" | "x" | "youtube" | "wechat" | "xiaohongshu" | "douyin" | "bilibili" | "github" | "zhihu" | "medium" | "substack" | "toutiao";
export type CaptureMedia = {
  platform: "douyin";
  videoURL: string;
  coverURL?: string | null;
  durationSeconds?: number | null;
  author?: string | null;
};

export type MediaKind = "directFile" | "hls" | "embed" | "browserSessionOnly" | "unsupported";
export type TranscriptionCapability = "supported" | "conditional" | "unavailable";
export type MediaFailureReason =
  | "blob_or_mse"
  | "multiple_candidates"
  | "video_not_loaded"
  | "no_transferable_source"
  | "drm_or_encrypted"
  | "browser_session_required"
  | "unsupported_media_type"
  | "unknown";
export type MediaDescriptor = {
  kind: MediaKind;
  pageURL: string;
  canonicalURL: string;
  platform: CapturePlatform;
  ephemeralPlaybackURL?: string;
  /**
   * 画面与声音分成两条流的来源（B 站 DASH）：`ephemeralPlaybackURL` 是画面，
   * 这里是配套音轨，由 App 下载后在本机合成一个带声音的文件。两条都是限时签名，
   * 与主地址同一有效期。
   */
  companionAudioURL?: string;
  mimeType?: string | null;
  posterURL?: string | null;
  durationSeconds?: number | null;
  author?: string | null;
  expiresAt?: string | null;
  transcriptionCapability: TranscriptionCapability;
  failureReason?: MediaFailureReason;
  candidateCount?: number;
  selectionReason?: "singleCandidate" | "playing" | "recentInteraction" | "largestVisibleArea" | "nearestViewportCenter" | "ambiguous";
  playbackState?: "playing" | "paused" | "ended" | "notLoaded" | "unknown";
};

export type CaptureEnvelopeV1 = {
  version: 1; requestId: string; createdAt: string; idempotencyKey?: string;
  requestedAction?: CaptureRequestedAction;
  source: { kind: "browser_capture"; url: string; title: string | null; platform: CapturePlatform };
  capture: { method: "rendered_dom" | "selection"; text: string; characterCount: number; completeness: "full_article" | "visible_only" | "selection_only" | "unknown"; capturedAt: string };
  evidence: { sourceLabel: string; usedCookie: false };
  /** Optional Loop V media block. Pure-text captures omit this field entirely. */
  media?: CaptureMedia;
};
export type CaptureEnvelopeV2 = {
  version: 2; requestId: string; createdAt: string; idempotencyKey?: string;
  requestedAction?: CaptureRequestedAction;
  source: CaptureEnvelopeV1["source"];
  capture: CaptureEnvelopeV1["capture"];
  evidence: { sourceLabel: string; usedCookie: boolean };
  media: MediaDescriptor;
};
export type CaptureEnvelope = CaptureEnvelopeV1 | CaptureEnvelopeV2;
export type AppError = {
  version: 1;
  requestId: string;
  createdAt: string;
  category: "protocol" | "permission" | "network" | "extraction" | "storage" | "unknown";
  code: string;
  retryable: boolean;
  action: "retry" | "open_app" | "open_install_guide" | "open_in_browser" | "grant_permission" | "upgrade_app" | "none";
  safeDetail?: string;
};
export type NativeResponse =
  | { kind: "taskAccepted"; version: 1; requestId: string; characterCount: number }
  | { kind: "error"; error: AppError };

const categories = new Set<AppError["category"]>(["protocol", "permission", "network", "extraction", "storage", "unknown"]);
const actions = new Set<AppError["action"]>(["retry", "open_app", "open_install_guide", "open_in_browser", "grant_permission", "upgrade_app", "none"]);

export function makeAppError(
  requestId: string,
  category: AppError["category"],
  code: string,
  retryable: boolean,
  action: AppError["action"],
): AppError {
  return { version: 1, requestId, createdAt: new Date().toISOString(), category, code, retryable, action };
}

export function isWireNativeResponse(value: unknown): value is NativeResponse {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  if (candidate.kind === "taskAccepted") {
    return candidate.version === 1
      && typeof candidate.requestId === "string"
      && candidate.requestId.length > 0
      && typeof candidate.characterCount === "number"
      && Number.isInteger(candidate.characterCount);
  }
  if (candidate.kind !== "error" || !candidate.error || typeof candidate.error !== "object") return false;
  const error = candidate.error as Record<string, unknown>;
  return error.version === 1
    && typeof error.requestId === "string" && error.requestId.length > 0
    && typeof error.createdAt === "string" && !Number.isNaN(Date.parse(error.createdAt))
    && typeof error.category === "string" && categories.has(error.category as AppError["category"])
    && typeof error.code === "string" && /^[A-Z][A-Z0-9_]{2,63}$/u.test(error.code)
    && typeof error.retryable === "boolean"
    && typeof error.action === "string" && actions.has(error.action as AppError["action"])
    && (error.safeDetail === undefined || typeof error.safeDetail === "string");
}

export function normalizeNativeResponse(value: unknown, expectedRequestId: string): NativeResponse {
  if (!isWireNativeResponse(value)) {
    return { kind: "error", error: makeAppError(expectedRequestId, "protocol", "NATIVE_RESPONSE_INVALID", false, "retry") };
  }
  if (value.kind === "taskAccepted" && value.requestId !== expectedRequestId) {
    return { kind: "error", error: makeAppError(expectedRequestId, "protocol", "NATIVE_RESPONSE_INVALID", false, "retry") };
  }
  return value;
}

export function validateCapture(value: unknown, declaredSchema?: string): string | null {
  if (!value || typeof value !== "object") return "CAPTURE_SCHEMA_INVALID";
  const candidate = value as Partial<CaptureEnvelope>;
  if (candidate.version !== 1 && candidate.version !== 2) return "PROTOCOL_VERSION_UNSUPPORTED";
  // Preserve the frozen pre-V2 fixture/error behavior: the historical
  // `version: 2` probe had no media discriminator and remains unsupported.
  if (candidate.version === 2 && !("media" in candidate)) return "PROTOCOL_VERSION_UNSUPPORTED";
  if (declaredSchema) {
    const declaredVersion = declaredSchema.endsWith("capture-envelope-v1.schema.json")
      ? 1
      : declaredSchema.endsWith("capture-envelope-v2.schema.json")
        ? 2
        : undefined;
    if (declaredVersion === undefined || candidate.version !== declaredVersion) return "CAPTURE_SCHEMA_INVALID";
  }
  if (!candidate.source || typeof candidate.source.url !== "string" || !/^https?:\/\//.test(candidate.source.url)) return "CAPTURE_URL_UNSUPPORTED";
  if (!candidate.capture || typeof candidate.capture.text !== "string") return "CAPTURE_SCHEMA_INVALID";
  if ([...candidate.capture.text].length === 0) return "CAPTURE_CONTENT_EMPTY";
  if ([...candidate.capture.text].length > MAX_CAPTURE_TEXT_SCALARS) return "CAPTURE_PAYLOAD_TOO_LARGE";
  if ([...candidate.capture.text].length !== candidate.capture.characterCount) return "CAPTURE_COUNT_MISMATCH";
  // Forward-compatible wire validation accepts unknown optional fields. Strict
  // persisted invariants belong to migration/Repository checks, not this API.
  if (!validateWireSchema(value)) return mapSchemaError(validateWireSchema.errors);
  return null;
}

function mapSchemaError(errors: SchemaValidationError[] | null | undefined): string {
  const pattern = errors?.find((error) => error.instancePath === "/source/url" && error.keyword === "pattern");
  return pattern ? "CAPTURE_URL_UNSUPPORTED" : "CAPTURE_SCHEMA_INVALID";
}
