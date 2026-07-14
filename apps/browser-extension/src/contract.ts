import validateSchema, { type SchemaValidationError } from "./generated/capture-validator.mjs";

export const MAX_CAPTURE_TEXT_SCALARS = 2_000_000;
export type CaptureEnvelopeV1 = {
  version: 1; requestId: string; createdAt: string; idempotencyKey?: string;
  source: { kind: "browser_capture"; url: string; title: string | null; platform: "generic" };
  capture: { method: "rendered_dom" | "selection"; text: string; characterCount: number; completeness: "full_article" | "visible_only" | "selection_only" | "unknown"; capturedAt: string };
  evidence: { sourceLabel: string; usedCookie: false };
};
export type NativeResponse = { kind: "taskAccepted"; version: 1; requestId: string; characterCount: number } | { kind: "error"; error: { code: string; safeDetail?: string; action?: string } };
export function validateCapture(value: unknown): string | null {
  if (!value || typeof value !== "object") return "CAPTURE_SCHEMA_INVALID";
  const candidate = value as Partial<CaptureEnvelopeV1>;
  if (candidate.version !== 1) return "PROTOCOL_VERSION_UNSUPPORTED";
  if (!candidate.source || typeof candidate.source.url !== "string" || !/^https?:\/\//.test(candidate.source.url)) return "CAPTURE_URL_UNSUPPORTED";
  if (!candidate.capture || typeof candidate.capture.text !== "string") return "CAPTURE_SCHEMA_INVALID";
  if ([...candidate.capture.text].length === 0) return "CAPTURE_CONTENT_EMPTY";
  if ([...candidate.capture.text].length > MAX_CAPTURE_TEXT_SCALARS) return "CAPTURE_PAYLOAD_TOO_LARGE";
  if ([...candidate.capture.text].length !== candidate.capture.characterCount) return "CAPTURE_COUNT_MISMATCH";
  if (!validateSchema(value)) return mapSchemaError(validateSchema.errors);
  return null;
}

function mapSchemaError(errors: SchemaValidationError[] | null | undefined): string {
  const pattern = errors?.find((error) => error.instancePath === "/source/url" && error.keyword === "pattern");
  return pattern ? "CAPTURE_URL_UNSUPPORTED" : "CAPTURE_SCHEMA_INVALID";
}
