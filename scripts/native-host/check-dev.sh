#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/native-host/install-dev.sh"
PLAN="$ROOT/scripts/native-host/uninstall-plan.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/linkdigest-native-host-check.XXXXXX")"
export HOME="$SANDBOX/home"
HOST_PATH="$SANDBOX/bin/LinkDigestNativeHost"
HOST_RESOURCE_BUNDLE="$SANDBOX/bin/LinkDigest_LinkDigestCore.bundle"
SCHEMA="$ROOT/contracts/capture-envelope-v1.schema.json"
EXTENSION_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

mkdir -p "$SANDBOX/bin" "$HOST_RESOURCE_BUNDLE/Resources/contracts"
cp "$SCHEMA" "$HOST_RESOURCE_BUNDLE/Resources/contracts/capture-envelope-v1.schema.json"
printf '#!/bin/sh\nexit 0\n' > "$HOST_PATH"
chmod 700 "$HOST_PATH"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

MISSING_BUNDLE_HOST="$SANDBOX/missing-bundle/LinkDigestNativeHost"
mkdir -p "$(dirname "$MISSING_BUNDLE_HOST")"
cp "$HOST_PATH" "$MISSING_BUNDLE_HOST"
expect_failure "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$MISSING_BUNDLE_HOST" --browser chrome

MISSING_SCHEMA_HOST="$SANDBOX/missing-schema/LinkDigestNativeHost"
mkdir -p "$(dirname "$MISSING_SCHEMA_HOST")/LinkDigest_LinkDigestCore.bundle/Resources/contracts"
cp "$HOST_PATH" "$MISSING_SCHEMA_HOST"
expect_failure "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$MISSING_SCHEMA_HOST" --browser chrome
expect_failure "$SCRIPT" --extension-id invalid-extension-id --host-path "$HOST_PATH" --browser chrome
expect_failure "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path relative/LinkDigestNativeHost --browser chrome
expect_failure "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH"

if "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser all >/dev/null 2>&1; then
  echo "expected --browser all to be rejected" >&2
  exit 1
fi

dry_run_output="$($SCRIPT --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave)"
grep -Fq "TARGET: $HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json" <<<"$dry_run_output"
if grep -Fq "TARGET: $HOME/Library/Application Support/BraveSoftware" <<<"$dry_run_output"; then
  echo "brave dry-run must map to the Chrome user-level target" >&2
  exit 1
fi

"$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
CHROME_TARGET="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"
BRAVE_TARGET="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.syc.linkdigest.v01.json"
[[ -f "$CHROME_TARGET" && ! -e "$BRAVE_TARGET" ]]
[[ "$(stat -f '%Lp' "$CHROME_TARGET")" == "600" ]]

"$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
backup_count="$(find "$(dirname "$CHROME_TARGET")" -maxdepth 1 -name 'com.syc.linkdigest.v01.json.*.bak' -type f | wc -l | tr -d ' ')"
[[ "$backup_count" -ge 1 ]]

FAIL_BIN="$SANDBOX/fail-bin"
mkdir -p "$FAIL_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAIL_BIN/mv"
chmod 700 "$FAIL_BIN/mv"
if failure_output="$(PATH="$FAIL_BIN:$PATH" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply 2>&1)"; then
  echo "expected atomic rename failure to be reported" >&2
  exit 1
fi
grep -Fq "temporary manifest retained" <<<"$failure_output"
FAILURE_TEMP_PATH="$(find "$(dirname "$CHROME_TARGET")" -maxdepth 1 -name '.com.syc.linkdigest.v01.json.tmp.*' -type f -print | sort | head -n 1)"
[[ -n "$FAILURE_TEMP_PATH" ]]

FIXED_DATE="20990101010101"
FAKE_BIN="$SANDBOX/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nprintf "%s\\n" "%s"\n' "$FIXED_DATE" > "$FAKE_BIN/date"
chmod 700 "$FAKE_BIN/date"
BACKUP_SYMLINK="$CHROME_TARGET.$FIXED_DATE.bak"
BACKUP_MARKER="$SANDBOX/backup-marker"
printf 'marker\n' > "$BACKUP_MARKER"
ln -s "$BACKUP_MARKER" "$BACKUP_SYMLINK"
PATH="$FAKE_BIN:$PATH" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
[[ -L "$BACKUP_SYMLINK" ]]
[[ -f "$CHROME_TARGET.$FIXED_DATE.1.bak" ]]

SYMLINK_HOME="$SANDBOX/symlink-home"
SYMLINK_DIR="$SYMLINK_HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$SYMLINK_DIR"
SYMLINK_TARGET="$SYMLINK_DIR/com.syc.linkdigest.v01.json"
ln -s "$SANDBOX/dangling-manifest" "$SYMLINK_TARGET"
expect_failure env HOME="$SYMLINK_HOME" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser chrome
[[ -L "$SYMLINK_TARGET" ]]

COMPONENT_HOME="$SANDBOX/component-home"
mkdir -p "$COMPONENT_HOME/Library/Application Support/Google"
ln -s "$SANDBOX/escaped-chrome" "$COMPONENT_HOME/Library/Application Support/Google/Chrome"
expect_failure env HOME="$COMPONENT_HOME" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser chrome

snapshot_home_files() {
  find "$HOME" -type f -print | sort | while IFS= read -r path; do
    printf '%s\t%s\t%s\n' \
      "$(stat -f '%Lp' "$path")" \
      "$(shasum -a 256 "$path" | awk '{print $1}')" \
      "$path"
  done
}

before="$(snapshot_home_files)"
plan_output="$("$PLAN" --browser brave)"
after="$(snapshot_home_files)"
[[ "$before" == "$after" ]]
grep -Fq "STATE: exists" <<<"$plan_output"
grep -Fq "MANUAL REMOVE: rm" <<<"$plan_output"
grep -Fq "不读取文件内容、不修改。" <<<"$plan_output"

edge_output="$($SCRIPT --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge)"
grep -Fq "Microsoft Edge/NativeMessagingHosts/com.syc.linkdigest.v01.json" <<<"$edge_output"

printf 'native-host check passed; TEST_SANDBOX=%s FAILURE_TEMP_PATH=%s\n' "$SANDBOX" "$FAILURE_TEMP_PATH"
