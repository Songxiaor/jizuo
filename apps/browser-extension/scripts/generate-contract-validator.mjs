/* global console */
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import standaloneCode from "ajv/dist/standalone/index.js";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = resolve(packageRoot, "../../contracts/capture-envelope-v1.schema.json");
const outputPath = resolve(packageRoot, "src/generated/capture-validator.mjs");

const schema = JSON.parse(await readFile(schemaPath, "utf8"));
const ajv = new Ajv2020({
  allErrors: true,
  strict: false,
  code: { source: true, esm: true, lines: true },
});
addFormats(ajv);

let generated = standaloneCode(ajv, ajv.compile(schema));
generated = generated.replace(
  /const (\w+) = require\("ajv\/dist\/runtime\/ucs2length"\)\.default;/g,
  "const $1 = (value) => [...value].length;",
);
generated = generated.replace(
  /const (\w+) = require\("ajv-formats\/dist\/formats"\)\.fullFormats(\[[^\n;]+\]|\.\w+);/g,
  "const $1 = __ajvFormats.fullFormats$2;",
);

if (generated.includes("require(")) {
  throw new Error("Standalone validator contains an unexpected runtime require()");
}

const output = [
  "/* eslint-disable */",
  "// Generated from contracts/capture-envelope-v1.schema.json. Do not edit by hand.",
  'import * as __ajvFormats from "ajv-formats/dist/formats.js";',
  generated,
  "",
].join("\n");

if (process.argv.includes("--check")) {
  const current = await readFile(outputPath, "utf8").catch(() => "");
  if (current !== output) {
    console.error("capture-validator: OUT OF DATE; run pnpm --filter @linkdigest/browser-extension generate:validator");
    process.exit(1);
  }
  console.log("capture-validator: OK");
} else {
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, output);
  console.log("capture-validator: generated");
}
