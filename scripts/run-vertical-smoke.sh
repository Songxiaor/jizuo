#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/desktop/.build/debug/LinkDigestApp"
HOST="$ROOT/apps/desktop/.build/debug/LinkDigestNativeHost"
FIXTURE="$ROOT/contracts/fixtures/valid.json"
SOCKET="/tmp/linkdigest-vertical-smoke-$$.sock"

"$ROOT/scripts/build-dev.sh" >/dev/null

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/linkdigest-vertical-smoke.XXXXXX")"
APPLICATION_SUPPORT_ROOT="$SMOKE_ROOT/Application Support"
APP_LOG="$SMOKE_ROOT/app.log"
APP_PID=""

assert_smoke_database_is_isolated() {
  local database="$APPLICATION_SUPPORT_ROOT/LinkDigest/history.sqlite"
  [[ -f "$database" ]] || {
    echo "vertical-smoke: injected temporary database was not created" >&2
    return 1
  }
  [[ "$database" == "$SMOKE_ROOT/"* ]] || {
    echo "vertical-smoke: database escaped the dedicated temporary root" >&2
    return 1
  }
}

cleanup() {
  local command_status=$?
  local cleanup_status=0
  set +e
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -f "$SOCKET" "$APP_LOG"
  if [[ -n "$APP_PID" ]]; then
    assert_smoke_database_is_isolated || cleanup_status=1
  fi
  rm -rf "$SMOKE_ROOT"
  [[ ! -e "$SMOKE_ROOT" ]] || {
    echo "vertical-smoke: temporary Application Support root was not removed" >&2
    cleanup_status=1
  }
  if [[ "$command_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    exit "$cleanup_status"
  fi
  exit "$command_status"
}
trap cleanup EXIT

mkdir -p "$APPLICATION_SUPPORT_ROOT"

LINKDIGEST_SOCKET_PATH="$SOCKET" \
LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT="$APPLICATION_SUPPORT_ROOT" \
"$APP" >"$APP_LOG" 2>&1 &
APP_PID=$!

for _ in {1..50}; do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
[[ -S "$SOCKET" ]] || { echo "vertical-smoke: APP socket did not start" >&2; exit 1; }
assert_smoke_database_is_isolated

LINKDIGEST_SOCKET_PATH="$SOCKET" node - "$HOST" "$FIXTURE" <<'NODE'
const { readFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const net = require("node:net");
const host = process.argv[2];
const base = JSON.parse(readFileSync(process.argv[3], "utf8"));

async function main() {
const stalled = net.createConnection(process.env.LINKDIGEST_SOCKET_PATH);
await new Promise((resolve, reject) => { stalled.once("connect", resolve); stalled.once("error", reject); });
stalled.write(Buffer.from([100, 0, 0, 0, 123]));

for (let index = 0; index < 20; index += 1) {
  const envelope = { ...base, requestId: `smoke-${index}`, idempotencyKey: `smoke-${index}` };
  const body = Buffer.from(JSON.stringify(envelope));
  const frame = Buffer.allocUnsafe(4 + body.length);
  frame.writeUInt32LE(body.length, 0);
  body.copy(frame, 4);
  const result = spawnSync(host, { input: frame, env: process.env });
  if (result.status !== 0 || result.stdout.length < 4) throw new Error(`Host failed at send ${index + 1}`);
  const length = result.stdout.readUInt32LE(0);
  const response = JSON.parse(result.stdout.subarray(4, 4 + length).toString("utf8"));
  if (response.kind !== "taskAccepted" || response.requestId !== envelope.requestId) {
    throw new Error(`Unexpected response at send ${index + 1}: ${response.kind}/${response.error?.code ?? "unknown"}`);
  }
}
stalled.destroy();
console.log("vertical-smoke: OK (debug smoke root explicitly injected; live Application Support resolution is forbidden; stalled client isolated; 20/20 captures accepted through Host → socket → SwiftUI process)");
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
NODE
