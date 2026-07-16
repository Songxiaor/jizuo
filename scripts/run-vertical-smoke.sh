#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/desktop/.build/debug/LinkDigestApp"
HOST="$ROOT/apps/desktop/.build/debug/LinkDigestNativeHost"
FIXTURE="$ROOT/contracts/fixtures/valid.json"
LIVE_LINKDIGEST_ROOT="$HOME/Library/Application Support/LinkDigest"
TMP_BASE="/private/tmp"

[[ -d "$TMP_BASE" && ! -L "$TMP_BASE" && "$(cd "$TMP_BASE" && pwd -P)" == "$TMP_BASE" ]] || {
  echo "vertical-smoke: fixed temporary root /private/tmp is unavailable or unsafe" >&2
  exit 2
}
current=""
IFS='/' read -r -a tmp_base_components <<< "$TMP_BASE"
for component in "${tmp_base_components[@]}"; do
  [[ -n "$component" ]] || continue
  current="$current/$component"
  [[ -d "$current" && ! -L "$current" ]] || {
    echo "vertical-smoke: temporary root contains a symlink or non-directory component" >&2
    exit 2
  }
done
export TMPDIR="$TMP_BASE"

"$ROOT/scripts/build-dev.sh" >/dev/null

# This intentionally records metadata only. The manifest never leaves its
# case-local temporary root, while the printed digest proves the live directory
# was identical before and after each path without printing user filenames.
snapshot_live_linkdigest_state() {
  local destination="$1"
  if [[ ! -e "$LIVE_LINKDIGEST_ROOT" ]]; then
    printf 'absent\n' >"$destination"
    return
  fi

  {
    printf 'present\n'
    find -s "$LIVE_LINKDIGEST_ROOT" -xdev -exec stat -f '%HT|%i|%z|%m|%N' {} \;
  } | LC_ALL=C sort >"$destination"
}

state_digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

run_host_case() {
  local expected="$1"
  LINKDIGEST_SOCKET_PATH="$SOCKET" node - "$HOST" "$FIXTURE" "$expected" <<'NODE'
const { readFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const net = require("node:net");
const host = process.argv[2];
const base = JSON.parse(readFileSync(process.argv[3], "utf8"));
const expected = process.argv[4];

function send(host, envelope) {
  const body = Buffer.from(JSON.stringify(envelope));
  const frame = Buffer.allocUnsafe(4 + body.length);
  frame.writeUInt32LE(body.length, 0);
  body.copy(frame, 4);
  const result = spawnSync(host, { input: frame, env: process.env });
  if (result.status !== 0 || result.stdout.length < 4) {
    throw new Error(`Host failed for ${envelope.requestId}`);
  }
  const length = result.stdout.readUInt32LE(0);
  const maximumResponseBytes = 4 * 1024 * 1024;
  if (
    length === 0 ||
    length > maximumResponseBytes ||
    result.stdout.length !== 4 + length
  ) {
    throw new Error(`Host returned an invalid frame for ${envelope.requestId}`);
  }
  return JSON.parse(result.stdout.subarray(4, 4 + length).toString("utf8"));
}

async function main() {
  const stalled = net.createConnection(process.env.LINKDIGEST_SOCKET_PATH);
  await new Promise((resolve, reject) => {
    stalled.once("connect", resolve);
    stalled.once("error", reject);
  });
  stalled.write(Buffer.from([100, 0, 0, 0, 123]));

  for (let index = 0; index < 20; index += 1) {
    const envelope = {
      ...base,
      requestId: `smoke-${expected}-${index}`,
      idempotencyKey: `smoke-${expected}-${index}`,
    };
    const response = send(host, envelope);
    if (expected === "success") {
      if (response.kind !== "taskAccepted" || response.requestId !== envelope.requestId) {
        throw new Error(`Unexpected success response at send ${index + 1}: ${response.kind}/${response.error?.code ?? "unknown"}`);
      }
    } else if (
      response.kind !== "error" ||
      response.error?.requestId !== envelope.requestId ||
      response.error?.category !== "storage" ||
      response.error?.code !== "STORAGE_UNAVAILABLE" ||
      response.error?.safeDetail !== undefined
    ) {
      throw new Error(`Unexpected failure response at send ${index + 1}: ${response.kind}/${response.error?.code ?? "unknown"}`);
    }
  }

  stalled.destroy();
  const outcome = expected === "success" ? "20/20 captures accepted" : "20/20 captures rejected with STORAGE_UNAVAILABLE";
  console.log(`vertical-smoke: ${expected} path OK (${outcome}; stalled client isolated)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
NODE
}

run_case() (
  set -euo pipefail
  local expected="$1"
  local smoke_root=""
  local application_support_root=""
  local socket=""
  local app_log=""
  local app_pid=""
  local before_state=""
  local after_state=""

  stop_app() {
    if [[ -n "$app_pid" ]]; then
      kill "$app_pid" 2>/dev/null || true
      wait "$app_pid" 2>/dev/null || true
      app_pid=""
    fi
  }

  cleanup() {
    local command_status=$?
    local cleanup_status=0
    trap - EXIT
    set +e
    stop_app
    if [[ -z "$smoke_root" || "$smoke_root" != "$TMP_BASE"/linkdigest-vertical-smoke.* ]]; then
      echo "vertical-smoke: refusing to remove an unexpected temporary root" >&2
      cleanup_status=1
    else
      rm -rf -- "$smoke_root"
      if [[ -e "$smoke_root" ]]; then
        echo "vertical-smoke: temporary Application Support root was not removed" >&2
        cleanup_status=1
      fi
    fi
    if [[ "$command_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
      exit "$cleanup_status"
    fi
    exit "$command_status"
  }
  trap cleanup EXIT

  smoke_root="$(mktemp -d "$TMP_BASE/linkdigest-vertical-smoke.XXXXXX")"
  application_support_root="$smoke_root/Application Support"
  socket="$smoke_root/linkdigest.sock"
  app_log="$smoke_root/app.log"
  before_state="$smoke_root/live-before.state"
  after_state="$smoke_root/live-after.state"
  mkdir -p "$application_support_root"
  snapshot_live_linkdigest_state "$before_state"

  if [[ "$expected" == "failure" ]]; then
    LINKDIGEST_SOCKET_PATH="$socket" \
    LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT="$application_support_root" \
    LINKDIGEST_SMOKE_FORCE_STORAGE_OPEN_FAILURE=1 \
    "$APP" >"$app_log" 2>&1 &
  else
    LINKDIGEST_SOCKET_PATH="$socket" \
    LINKDIGEST_SMOKE_APPLICATION_SUPPORT_ROOT="$application_support_root" \
    "$APP" >"$app_log" 2>&1 &
  fi
  app_pid=$!

  for _ in {1..50}; do
    [[ -S "$socket" ]] && break
    sleep 0.1
  done
  [[ -S "$socket" ]] || { echo "vertical-smoke: APP socket did not start ($expected path)" >&2; exit 1; }

  if [[ "$expected" == "success" ]]; then
    database="$application_support_root/LinkDigest/history.sqlite"
    [[ -f "$database" ]] || { echo "vertical-smoke: injected temporary database was not created" >&2; exit 1; }
    [[ "$database" == "$smoke_root/"* ]] || { echo "vertical-smoke: database escaped the dedicated temporary root" >&2; exit 1; }
  else
    [[ ! -e "$application_support_root/LinkDigest" ]] || {
      echo "vertical-smoke: deterministic open failure unexpectedly created a temporary database directory" >&2
      exit 1
    }
  fi

  SOCKET="$socket" run_host_case "$expected"
  stop_app
  snapshot_live_linkdigest_state "$after_state"
  cmp "$before_state" "$after_state" >/dev/null || {
    echo "vertical-smoke: live LinkDigest Application Support state changed during $expected path" >&2
    exit 1
  }
  printf 'vertical-smoke: %s path left live LinkDigest state unchanged (sha256 %s)\n' \
    "$expected" "$(state_digest "$after_state")"
)

run_case success
run_case failure
echo "vertical-smoke: OK (success and deterministic storage-open failure both use isolated temporary Application Support roots)"
