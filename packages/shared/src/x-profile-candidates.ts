import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Ajv2020, type ErrorObject } from "ajv/dist/2020.js";
import * as addFormatsModule from "ajv-formats";

const addFormats = addFormatsModule.default as unknown as (ajv: InstanceType<typeof Ajv2020>) => void;

export const MAX_X_PROFILE_CANDIDATES = 100;
export const X_PROFILE_CANDIDATES_KIND = "xProfileCandidates";
export const X_PROFILE_CANDIDATES_PRESENTED_KIND = "profileCandidatesPresented";

export type XProfileCandidateItem = {
  id: string;
  url: string;
  previewText?: string;
  publishedText?: string;
};

export type XProfileCandidatesRequest = {
  kind: "xProfileCandidates";
  version: 1;
  requestId: string;
  profileURL: string;
  authorID: string;
  profileName?: string;
  profileAvatarURL?: string;
  items: XProfileCandidateItem[];
};

export type XProfileCandidatesPresented = {
  kind: "profileCandidatesPresented";
  version: 1;
  requestId: string;
  acceptedCount: number;
};

function locateContractsRoot(): string {
  let current = process.cwd();
  for (let i = 0; i < 5; i += 1) {
    const candidate = resolve(current, "contracts/x-profile-candidates-v1.schema.json");
    try {
      readFileSync(candidate);
      return resolve(current, "contracts");
    } catch {
      current = resolve(current, "..");
    }
  }
  throw new Error("contracts directory not found");
}

const schemaPath = resolve(locateContractsRoot(), "x-profile-candidates-v1.schema.json");
export const xProfileCandidatesSchema = JSON.parse(readFileSync(schemaPath, "utf8")) as Record<string, unknown>;
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validateSchema = ajv.compile(xProfileCandidatesSchema);

export function validateXProfileCandidatesMessage(
  value: unknown,
): { ok: true; value: XProfileCandidatesRequest | XProfileCandidatesPresented } | { ok: false; errors?: ErrorObject[] } {
  if (!validateSchema(value)) {
    return validateSchema.errors ? { ok: false, errors: validateSchema.errors } : { ok: false };
  }
  return { ok: true, value: value as XProfileCandidatesRequest | XProfileCandidatesPresented };
}
