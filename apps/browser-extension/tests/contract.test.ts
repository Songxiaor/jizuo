import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { isWireNativeResponse, normalizeNativeResponse, validateCapture } from "../src/contract";

type FixtureEntry = {
  file: string;
  schema?: string;
  expect: "valid" | "invalid";
  errorCode?: string;
  mutation?: { field: "capture.text"; repeat: number; unit: string };
};

const fixtureUrl = (file: string) => new URL(`../../../contracts/fixtures/${file}`, import.meta.url);

describe("browser capture contract", () => {
  it("validates the shared language-neutral fixtures and semantic invariants", () => {
    const manifest = JSON.parse(readFileSync(fixtureUrl("fixture-manifest.json"), "utf8")) as { schema: string; fixtures: FixtureEntry[] };

    for (const fixture of manifest.fixtures) {
      const value = JSON.parse(readFileSync(fixtureUrl(fixture.file), "utf8")) as Record<string, unknown>;
      if (fixture.mutation) {
        (value.capture as Record<string, unknown>).text = fixture.mutation.unit.repeat(fixture.mutation.repeat);
      }

      expect(validateCapture(value, fixture.schema ?? manifest.schema), fixture.file).toBe(fixture.expect === "valid" ? null : fixture.errorCode);
    }
  });

  it("keeps Unicode scalar counting language-neutral, including embedded NUL", () => {
    const fixtures = [
      ["unicode-emoji.json", 1],
      ["unicode-combining.json", 2],
      ["unicode-nul.json", 3],
    ] as const;
    for (const [file, expected] of fixtures) {
      const value = JSON.parse(readFileSync(fixtureUrl(file), "utf8")) as { capture: { text: string; characterCount: number } };
      expect([...value.capture.text].length).toBe(expected);
      expect(value.capture.characterCount).toBe(expected);
      expect(validateCapture(value)).toBeNull();
    }
  });

  it("consumes shared NativeResponse fixtures with strict ACK correlation", () => {
    const fixture = JSON.parse(readFileSync(new URL("../../../contracts/native-response-fixtures.json", import.meta.url), "utf8")) as {
      cases: Array<{ name: string; expected: string; forbidden?: string; value: unknown }>;
    };
    for (const entry of fixture.cases) {
      const wireValid = isWireNativeResponse(entry.value);
      if (entry.expected === "wire_invalid") expect(wireValid, entry.name).toBe(false);
      else expect(wireValid, entry.name).toBe(true);
      const normalized = normalizeNativeResponse(entry.value, "req-1");
      if (entry.expected === "accepted") expect(normalized.kind, entry.name).toBe("taskAccepted");
      if (entry.expected === "correlation_error" || entry.expected === "wire_invalid") {
        expect(normalized).toMatchObject({ kind: "error", error: { code: "NATIVE_RESPONSE_INVALID", requestId: "req-1" } });
      }
    }
  });

  it("keeps the generated MV3 validator free of runtime code generation", () => {
    const generated = readFileSync(new URL("../src/generated/capture-validator.mjs", import.meta.url), "utf8");
    expect(generated).not.toMatch(/(?:^|[^\w])eval\(|new\s+Function|require\(/u);
  });

  it("accepts V1 and V2 independently while rejecting an invalid direct media descriptor", () => {
    const v1 = JSON.parse(readFileSync(fixtureUrl("valid.json"), "utf8"));
    const direct = JSON.parse(readFileSync(fixtureUrl("v2-direct-file.json"), "utf8"));
    const invalid = JSON.parse(readFileSync(fixtureUrl("v2-invalid-direct-without-url.json"), "utf8"));
    expect(validateCapture(v1)).toBeNull();
    expect(validateCapture(direct)).toBeNull();
    expect(validateCapture(invalid)).toBe("CAPTURE_SCHEMA_INVALID");
    expect(validateCapture({
      ...direct,
      media: { ...direct.media, failureReason: "unknown" },
    })).toBe("CAPTURE_SCHEMA_INVALID");
    const blob = JSON.parse(readFileSync(fixtureUrl("v2-blob-mse.json"), "utf8"));
    expect(validateCapture({
      ...blob,
      media: { ...blob.media, ephemeralPlaybackURL: "https://media.example.test/forbidden.mp4" },
    })).toBe("CAPTURE_SCHEMA_INVALID");
    expect(validateCapture({
      ...v1,
      evidence: { ...v1.evidence, usedCookie: true },
    })).toBe("CAPTURE_SCHEMA_INVALID");
    expect(validateCapture({
      ...direct,
      evidence: { sourceLabel: "Current page DOM", usedCookie: false },
    })).toBeNull();
    expect(validateCapture({
      ...direct,
      evidence: { sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true },
    })).toBeNull();
  });
});
