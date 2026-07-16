#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${LINKDIGEST_HOST_PATH+x}" || -n "${LINKDIGEST_SKIP_BUILD+x}" ]]; then
  echo "raw LINKDIGEST_HOST_PATH/LINKDIGEST_SKIP_BUILD overrides are forbidden; use a verified LINKDIGEST_HOST_PACKAGE_ROOT" >&2
  exit 2
fi
if [[ -n "${LINKDIGEST_HOST_SMOKE_SOCKET_PATH+x}" ]]; then
  echo "LINKDIGEST_HOST_SMOKE_SOCKET_PATH is forbidden; Host smoke sockets stay inside fixed /private/tmp" >&2
  exit 2
fi

FIXED_TMP_ROOT="/private/tmp"
[[ -d "$FIXED_TMP_ROOT" && ! -L "$FIXED_TMP_ROOT" && "$(cd "$FIXED_TMP_ROOT" && pwd -P)" == "$FIXED_TMP_ROOT" ]] || {
  echo "fixed Host smoke root /private/tmp is unavailable or unsafe" >&2
  exit 2
}
export TMPDIR="$FIXED_TMP_ROOT"

if [[ -n "${LINKDIGEST_HOST_PACKAGE_ROOT:-}" ]]; then
  PACKAGE_ROOT="$LINKDIGEST_HOST_PACKAGE_ROOT"
  python3 "$ROOT/scripts/native-host/stable_host.py" verify-package --package-root "$PACKAGE_ROOT" >/dev/null
  ENTRYPOINT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["entrypoint"])' "$ROOT/config/native-host.json")"
  HOST="$PACKAGE_ROOT/$ENTRYPOINT"
else
  (cd "$ROOT/apps/desktop" && swift build -c debug >/dev/null)
  HOST="$ROOT/apps/desktop/.build/debug/LinkDigestNativeHost"
fi
[[ "$HOST" == /* && -f "$HOST" && -x "$HOST" ]] || {
  echo "selected Host must be an absolute executable file" >&2
  exit 2
}
HOST_BUNDLE="$(dirname "$HOST")/LinkDigest_LinkDigestCore.bundle"
[[ -d "$HOST_BUNDLE" && ! -L "$HOST_BUNDLE" ]] || {
  echo "Host resource bundle is missing beside the selected Host" >&2
  exit 2
}
[[ -f "$HOST_BUNDLE/Resources/contracts/capture-envelope-v1.schema.json" ]] || {
  echo "Host contract schema is missing from the selected resource bundle" >&2
  exit 2
}
FIXTURE="$ROOT/contracts/fixtures/valid.json"
SOCKET_PARENT="$FIXED_TMP_ROOT"
[[ -d "$SOCKET_PARENT" && ! -L "$SOCKET_PARENT" && "$(cd "$SOCKET_PARENT" && pwd -P)" == "$SOCKET_PARENT" ]] || {
  echo "fixed Host smoke root /private/tmp is unavailable or unsafe" >&2
  exit 2
}
current=""
IFS='/' read -r -a socket_parent_components <<< "$SOCKET_PARENT"
for component in "${socket_parent_components[@]}"; do
  [[ -n "$component" ]] || continue
  current="$current/$component"
  [[ -d "$current" && ! -L "$current" ]] || {
    echo "Host smoke socket parent contains a symlink or non-directory component" >&2
    exit 2
  }
done
SOCKET="$SOCKET_PARENT/linkdigest-host-smoke.$$.sock"
[[ ! -e "$SOCKET" && ! -L "$SOCKET" ]] || {
  echo "fixed Host smoke socket target already exists" >&2
  exit 2
}

cleanup_socket() {
  local status=$?
  trap - EXIT
  if [[ -S "$SOCKET" ]]; then
    rm -f -- "$SOCKET"
  elif [[ -e "$SOCKET" || -L "$SOCKET" ]]; then
    echo "Host smoke refuses to remove a replacement non-socket target: $SOCKET" >&2
    [[ $status -ne 0 ]] || status=1
  fi
  exit "$status"
}
trap cleanup_socket EXIT

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
  try {
    require("node:fs").lstatSync(process.env.LINKDIGEST_SOCKET_PATH);
    throw new Error("Host smoke socket target appeared before timeout probe");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
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
    if (timeoutResponse.error?.code !== "NATIVE_MESSAGE_TIMEOUT" || timeoutResponse.error?.category !== "network") {
      throw new Error(`Expected network/NATIVE_MESSAGE_TIMEOUT, received ${timeoutResponse.error?.category ?? "unknown"}/${timeoutResponse.error?.code ?? "unknown"}`);
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

verifyResponseTimeout()
  .then(() => console.log("host-smoke: OK (offline, oversized framing, and socket response timeout mapped to stable errors)"))
  .catch((error) => { console.error(error); process.exitCode = 1; });
NODE
