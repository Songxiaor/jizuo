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
  evidence: { sourceLabel: string; usedCookie: boolean };
  [key: string]: unknown;
};

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
export const captureContractSchema = JSON.parse(readFileSync(schemaPath, "utf8")) as Record<string, unknown>;
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validateSchema = ajv.compile(captureContractSchema);

export const MAX_CAPTURE_TEXT_SCALARS = 2_000_000;
export const MAX_NATIVE_FRAME_BYTES = 4 * 1024 * 1024;

export function unicodeScalarCount(value: string): number {
  return [...value].length;
}

export function validateCaptureEnvelope(value: unknown): { ok: true; value: CaptureEnvelopeV1Contract } | { ok: false; code: ContractErrorCode; errors?: ErrorObject[] } {
  if (!value || typeof value !== "object") return { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  const candidate = value as Partial<CaptureEnvelopeV1Contract>;
  if (candidate.version !== 1) return { ok: false, code: "PROTOCOL_VERSION_UNSUPPORTED" };
  const capture = candidate.capture;
  if (!capture || typeof capture.text !== "string") return { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  if (unicodeScalarCount(capture.text) === 0) return { ok: false, code: "CAPTURE_CONTENT_EMPTY" };
  if (unicodeScalarCount(capture.text) > MAX_CAPTURE_TEXT_SCALARS) return { ok: false, code: "CAPTURE_PAYLOAD_TOO_LARGE" };
  if (capture.characterCount !== unicodeScalarCount(capture.text)) return { ok: false, code: "CAPTURE_COUNT_MISMATCH" };
  const url = candidate.source?.url;
  if (typeof url !== "string" || !/^https?:\/\//.test(url)) return { ok: false, code: "CAPTURE_URL_UNSUPPORTED" };
  if (!validateSchema(value)) {
    const errors = validateSchema.errors;
    return errors ? { ok: false, code: "CAPTURE_SCHEMA_INVALID", errors } : { ok: false, code: "CAPTURE_SCHEMA_INVALID" };
  }
  return { ok: true, value: candidate as CaptureEnvelopeV1Contract };
}

export function fixturePath(file: string): string { return resolve(contractsRoot, "fixtures", file); }
