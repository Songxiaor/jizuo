import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Ajv2020, type ErrorObject } from "ajv/dist/2020.js";
import * as addFormatsModule from "ajv-formats";
const addFormats = addFormatsModule.default as unknown as (ajv: InstanceType<typeof Ajv2020>) => void;

export type CaptureEnvelopeV1Contract = {
  version: number;
  requestId: string;
  createdAt: string;
  idempotencyKey?: string;
  source: { kind: string; url: string; title: string | null; platform: string };
  capture: { method: string; text: string; characterCount: number; completeness: string; capturedAt: string };
  evidence: { sourceLabel: string; usedCookie: false };
  media?: {
    platform: "douyin";
    videoURL: string;
    coverURL?: string | null;
    durationSeconds?: number | null;
    author?: string | null;
  };
  [key: string]: unknown;
};

export type CaptureEnvelopeV2Contract = Omit<CaptureEnvelopeV1Contract, "version" | "media" | "evidence"> & {
  version: 2;
  evidence: { sourceLabel: string; usedCookie: boolean };
  media: {
    kind: "directFile" | "hls" | "embed" | "browserSessionOnly" | "unsupported";
    pageURL: string;
    canonicalURL: string;
    platform: string;
    ephemeralPlaybackURL?: string;
    mimeType?: string | null;
    posterURL?: string | null;
    durationSeconds?: number | null;
    author?: string | null;
    expiresAt?: string | null;
    transcriptionCapability: "supported" | "conditional" | "unavailable";
    failureReason?: "blob_or_mse" | "multiple_candidates" | "video_not_loaded" | "no_transferable_source" | "drm_or_encrypted" | "browser_session_required" | "unsupported_media_type" | "unknown";
    candidateCount?: number;
    selectionReason?: "singleCandidate" | "playing" | "recentInteraction" | "largestVisibleArea" | "nearestViewportCenter" | "ambiguous";
    playbackState?: "playing" | "paused" | "ended" | "notLoaded" | "unknown";
  };
};
export type CaptureEnvelopeContract = CaptureEnvelopeV1Contract | CaptureEnvelopeV2Contract;

export type ContractErrorCode = "PROTOCOL_VERSION_UNSUPPORTED" | "CAPTURE_URL_UNSUPPORTED" | "CAPTURE_COUNT_MISMATCH" | "CAPTURE_CONTENT_EMPTY" | "CAPTURE_PAYLOAD_TOO_LARGE" | "CAPTURE_SCHEMA_INVALID";

function locateContractsRoot(): string {
  let current = process.cwd();
  for (let i = 0; i < 5; i += 1) {
    const candidate = resolve(current, "contracts/capture-envelope-v1.schema.json");
    try { readFileSync(candidate); return resolve(current, "contracts"); } catch { current = resolve(current, ".."); }
  }
  throw new Error("contracts directory not found");
}
const contractsRoot = locateContractsRoot();
const schemaPath = resolve(contractsRoot, "capture-envelope-v1.schema.json");
const schemaV2Path = resolve(contractsRoot, "capture-envelope-v2.schema.json");
export const captureContractSchema = JSON.parse(readFileSync(schemaPath, "utf8")) as Record<string, unknown>;
export const captureContractV2Schema = JSON.parse(readFileSync(schemaV2Path, "utf8")) as Record<string, unknown>;
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validateSchemaV1 = ajv.compile(captureContractSchema);
const validateSchemaV2 = ajv.compile(captureContractV2Schema);

export const MAX_CAPTURE_TEXT_SCALARS = 2_000_000;
export const MAX_NATIVE_FRAME_BYTES = 4 * 1024 * 1024;

export function unicodeScalarCount(value: string): number {
  return [...value].length;
}

export function validateCaptureEnvelope(
  value: unknown,
  declaredSchema?: string,
): { ok: true; value: CaptureEnvelopeContract } | { ok: false; code: ContractErrorCode; errors?: ErrorObject[] } {
  if (!value || typeof value !== "object") return { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  const candidate = value as {
    version?: unknown;
    source?: { url?: unknown };
    capture?: { text?: unknown; characterCount?: unknown };
    media?: unknown;
  };
  if (candidate.version !== 1 && candidate.version !== 2) return { ok: false, code: "PROTOCOL_VERSION_UNSUPPORTED" };
  if (candidate.version === 2 && candidate.media === undefined) return { ok: false, code: "PROTOCOL_VERSION_UNSUPPORTED" };
  if (declaredSchema) {
    const declaredVersion = declaredSchema.endsWith("capture-envelope-v1.schema.json")
      ? 1
      : declaredSchema.endsWith("capture-envelope-v2.schema.json")
        ? 2
        : undefined;
    if (declaredVersion === undefined || candidate.version !== declaredVersion) {
      return { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
    }
  }
  const capture = candidate.capture;
  if (!capture || typeof capture.text !== "string") return { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  if (unicodeScalarCount(capture.text) === 0) return { ok: false, code: "CAPTURE_CONTENT_EMPTY" };
  if (unicodeScalarCount(capture.text) > MAX_CAPTURE_TEXT_SCALARS) return { ok: false, code: "CAPTURE_PAYLOAD_TOO_LARGE" };
  if (capture.characterCount !== unicodeScalarCount(capture.text)) return { ok: false, code: "CAPTURE_COUNT_MISMATCH" };
  const url = candidate.source?.url;
  if (typeof url !== "string" || !/^https?:\/\//.test(url)) return { ok: false, code: "CAPTURE_URL_UNSUPPORTED" };
  const validateSchema = candidate.version === 1 ? validateSchemaV1 : validateSchemaV2;
  if (!validateSchema(value)) {
    const errors = validateSchema.errors;
    return errors ? { ok: false, code: "CAPTURE_SCHEMA_INVALID", errors } : { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  }
  return { ok: true, value: candidate as CaptureEnvelopeContract };
}

export function fixturePath(file: string): string { return resolve(contractsRoot, "fixtures", file); }
