import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { validateCapture } from "../src/contract";

type FixtureEntry = {
  file: string;
  expect: "valid" | "invalid";
  errorCode?: string;
  mutation?: { field: "capture.text"; repeat: number; unit: string };
};

const fixtureUrl = (file: string) => new URL(`../../../contracts/fixtures/${file}`, import.meta.url);

describe("browser capture contract", () => {
  it("validates the shared language-neutral fixtures and semantic invariants", () => {
    const manifest = JSON.parse(readFileSync(fixtureUrl("fixture-manifest.json"), "utf8")) as { fixtures: FixtureEntry[] };

    for (const fixture of manifest.fixtures) {
      const value = JSON.parse(readFileSync(fixtureUrl(fixture.file), "utf8")) as Record<string, unknown>;
      if (fixture.mutation) {
        (value.capture as Record<string, unknown>).text = fixture.mutation.unit.repeat(fixture.mutation.repeat);
      }

      expect(validateCapture(value), fixture.file).toBe(fixture.expect === "valid" ? null : fixture.errorCode);
    }
  });

  it("keeps the generated MV3 validator free of runtime code generation", () => {
    const generated = readFileSync(new URL("../src/generated/capture-validator.mjs", import.meta.url), "utf8");
    expect(generated).not.toMatch(/(?:^|[^\w])eval\(|new\s+Function|require\(/u);
  });
});
