#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/apps/desktop" && swift build -c debug >/dev/null)
HOST="$ROOT/apps/desktop/.build/debug/LinkDigestNativeHost"
FIXTURE="$ROOT/contracts/fixtures/valid.json"
SOCKET="/tmp/linkdigest-smoke-unavailable-$$.sock"
LINKDIGEST_SOCKET_PATH="$SOCKET" node - "$HOST" "$FIXTURE" <<'NODE'
const { readFileSync } = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const net = require("node:net");
const host = process.argv[2];
const fixture = readFileSync(process.argv[3]);
const frame = Buffer.allocUnsafe(4 + fixture.length);
frame.writeUInt32LE(fixture.length, 0);
fixture.copy(frame, 4);
const result = spawnSync(host, { input: frame, env: process.env });
if (result.status !== 0 || result.stdout.length < 4) throw new Error("Native host did not return a framed response");
const length = result.stdout.readUInt32LE(0);
const response = JSON.parse(result.stdout.subarray(4, 4 + length).toString("utf8"));
if (response.kind !== "error" || response.error?.code !== "APP_UNAVAILABLE") {
  throw new Error(`Expected APP_UNAVAILABLE, received ${response.kind}/${response.error?.code ?? "unknown"}`);
}
const oversized = Buffer.alloc(4);
oversized.writeUInt32LE(4 * 1024 * 1024 + 1, 0);
const oversizedResult = spawnSync(host, { input: oversized, env: process.env });
const oversizedLength = oversizedResult.stdout.readUInt32LE(0);
const oversizedResponse = JSON.parse(oversizedResult.stdout.subarray(4, 4 + oversizedLength).toString("utf8"));
if (oversizedResponse.error?.code !== "CAPTURE_PAYLOAD_TOO_LARGE") {
  throw new Error(`Expected CAPTURE_PAYLOAD_TOO_LARGE, received ${oversizedResponse.error?.code ?? "unknown"}`);
}

async function verifyResponseTimeout() {
  try { require("node:fs").unlinkSync(process.env.LINKDIGEST_SOCKET_PATH); } catch {}
  const server = net.createServer((socket) => socket.on("data", () => undefined));
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(process.env.LINKDIGEST_SOCKET_PATH, resolve); });
  try {
    const child = spawn(host, { env: { ...process.env, LINKDIGEST_TIMEOUT_SECONDS: "0.05" } });
    const chunks = [];
    child.stdout.on("data", (chunk) => chunks.push(chunk));
    child.stdin.end(frame);
    const status = await new Promise((resolve) => child.once("close", resolve));
    const output = Buffer.concat(chunks);
    if (status !== 0 || output.length < 4) throw new Error("Host timeout probe returned no frame");
    const responseLength = output.readUInt32LE(0);
    const timeoutResponse = JSON.parse(output.subarray(4, 4 + responseLength).toString("utf8"));
    if (timeoutResponse.error?.code !== "NATIVE_MESSAGE_TIMEOUT") {
      throw new Error(`Expected NATIVE_MESSAGE_TIMEOUT, received ${timeoutResponse.error?.code ?? "unknown"}`);
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

verifyResponseTimeout()
  .then(() => console.log("host-smoke: OK (offline, oversized framing, and socket response timeout mapped to stable errors)"))
  .catch((error) => { console.error(error); process.exitCode = 1; });
NODE
