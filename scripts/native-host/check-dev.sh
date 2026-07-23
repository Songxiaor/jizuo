#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/native-host/install-dev.sh"
PLAN="$ROOT/scripts/native-host/uninstall-plan.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/linkdigest-native-host-check.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
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

expect_failure_with_message() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
  grep -Fq -- "$expected" <<<"$output" || {
    echo "failure did not contain expected message: $expected" >&2
    exit 1
  }
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
  echo "brave dry-run must use Chrome's active user-level target" >&2
  exit 1
fi

"$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
BRAVE_TARGET="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.syc.linkdigest.v01.json"
[[ -f "$BRAVE_TARGET" ]]
[[ "$(stat -f '%Lp' "$BRAVE_TARGET")" == "600" ]]
LEGACY_BRAVE_TARGET="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.syc.linkdigest.v01.json"
[[ ! -e "$LEGACY_BRAVE_TARGET" && ! -L "$LEGACY_BRAVE_TARGET" ]]

"$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
backup_count="$(find "$(dirname "$BRAVE_TARGET")" -maxdepth 1 -name 'com.syc.linkdigest.v01.json.*.bak' -type f | wc -l | tr -d ' ')"
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
FAILURE_TEMP_PATH="$(find "$(dirname "$BRAVE_TARGET")" -maxdepth 1 -name '.com.syc.linkdigest.v01.json.tmp.*' -type f -print | sort | head -n 1)"
[[ -n "$FAILURE_TEMP_PATH" ]]

FIXED_DATE="20990101010101"
FAKE_BIN="$SANDBOX/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nprintf "%s\\n" "%s"\n' "$FIXED_DATE" > "$FAKE_BIN/date"
chmod 700 "$FAKE_BIN/date"
BACKUP_SYMLINK="$BRAVE_TARGET.$FIXED_DATE.bak"
BACKUP_MARKER="$SANDBOX/backup-marker"
printf 'marker\n' > "$BACKUP_MARKER"
ln -s "$BACKUP_MARKER" "$BACKUP_SYMLINK"
PATH="$FAKE_BIN:$PATH" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser brave --apply >/dev/null
[[ -L "$BACKUP_SYMLINK" ]]
[[ -f "$BRAVE_TARGET.$FIXED_DATE.1.bak" ]]

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

EDGE_PROFILE_SYMLINK_REAL="$SANDBOX/edge-profile-symlink-real"
EDGE_PROFILE_SYMLINK="$SANDBOX/edge-profile-symlink"
mkdir -p "$EDGE_PROFILE_SYMLINK_REAL"
ln -s "$EDGE_PROFILE_SYMLINK_REAL" "$EDGE_PROFILE_SYMLINK"
expect_failure_with_message "refusing symlink profile path component" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_PROFILE_SYMLINK" --apply
[[ ! -e "$EDGE_PROFILE_SYMLINK_REAL/NativeMessagingHosts" ]]

EDGE_PARENT_REAL="$SANDBOX/edge-parent-real"
EDGE_PARENT_LINK="$SANDBOX/edge-parent-link"
mkdir -p "$EDGE_PARENT_REAL/profile"
ln -s "$EDGE_PARENT_REAL" "$EDGE_PARENT_LINK"
expect_failure_with_message "refusing symlink profile path component" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_PARENT_LINK/profile" --apply
[[ ! -e "$EDGE_PARENT_REAL/profile/NativeMessagingHosts" ]]

EDGE_INTERMEDIATE_ROOT="$SANDBOX/edge-intermediate-root"
EDGE_INTERMEDIATE_OUTSIDE="$SANDBOX/edge-intermediate-outside"
mkdir -p "$EDGE_INTERMEDIATE_ROOT" "$EDGE_INTERMEDIATE_OUTSIDE/profile"
ln -s "$EDGE_INTERMEDIATE_OUTSIDE" "$EDGE_INTERMEDIATE_ROOT/link"
expect_failure_with_message "refusing symlink profile path component" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_INTERMEDIATE_ROOT/link/profile" --apply
[[ ! -e "$EDGE_INTERMEDIATE_OUTSIDE/profile/NativeMessagingHosts" ]]

EDGE_DOT_PROFILE="$SANDBOX/edge-dot-profile"
mkdir -p "$EDGE_DOT_PROFILE"
expect_failure_with_message "must not contain empty, . or .. path components" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$SANDBOX/./edge-dot-profile" --apply
[[ ! -e "$EDGE_DOT_PROFILE/NativeMessagingHosts" ]]

EDGE_DOTDOT_PARENT="$SANDBOX/edge-dotdot-parent"
EDGE_DOTDOT_PROFILE="$SANDBOX/edge-dotdot-profile"
mkdir -p "$EDGE_DOTDOT_PARENT" "$EDGE_DOTDOT_PROFILE"
expect_failure_with_message "must not contain empty, . or .. path components" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_DOTDOT_PARENT/../edge-dotdot-profile" --apply
[[ ! -e "$EDGE_DOTDOT_PROFILE/NativeMessagingHosts" ]]

EDGE_REPEATED_SLASH_PROFILE="$SANDBOX/edge-repeated-slash-profile"
mkdir -p "$EDGE_REPEATED_SLASH_PROFILE"
expect_failure_with_message "must not contain empty, . or .. path components" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$SANDBOX//edge-repeated-slash-profile" --apply
[[ ! -e "$EDGE_REPEATED_SLASH_PROFILE/NativeMessagingHosts" ]]

EDGE_TRAILING_SLASH_PROFILE="$SANDBOX/edge-trailing-slash-profile"
mkdir -p "$EDGE_TRAILING_SLASH_PROFILE"
expect_failure_with_message "must be a non-root canonical absolute path" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_TRAILING_SLASH_PROFILE/" --apply
[[ ! -e "$EDGE_TRAILING_SLASH_PROFILE/NativeMessagingHosts" ]]

EDGE_PROFILE="$SANDBOX/edge-user-data"
mkdir -p "$EDGE_PROFILE"
edge_profile_output="$($SCRIPT --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_PROFILE")"
grep -Fq "TARGET: $EDGE_PROFILE/NativeMessagingHosts/com.syc.linkdigest.v01.json" <<<"$edge_profile_output"
"$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$EDGE_PROFILE" --apply >/dev/null
EDGE_PROFILE_TARGET="$EDGE_PROFILE/NativeMessagingHosts/com.syc.linkdigest.v01.json"
[[ -f "$EDGE_PROFILE_TARGET" ]]
[[ "$(dirname "$(dirname "$EDGE_PROFILE_TARGET")")" == "$EDGE_PROFILE" ]]
expect_failure "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser chrome --user-data-dir "$EDGE_PROFILE"
expect_failure_with_message "must be an existing directory" "$SCRIPT" --extension-id "$EXTENSION_ID" --host-path "$HOST_PATH" --browser edge --user-data-dir "$SANDBOX/missing-profile"

printf 'edge-profile guards passed: profile-symlink parent-symlink intermediate-symlink dot dotdot repeated-slash trailing-slash direct-child no-outside-write\n'
printf 'native-host check passed; TEST_SANDBOX=%s FAILURE_TEMP_PATH=%s\n' "$SANDBOX" "$FAILURE_TEMP_PATH"
