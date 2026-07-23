#!/usr/bin/env bash
set -euo pipefail
HOST_NAME="com.syc.linkdigest.v01.json"
EXTENSION_ID=""
HOST_PATH=""
APPLY=0
BROWSER=""
USER_DATA_DIR=""
EDGE_PROFILE_SCOPED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --extension-id) EXTENSION_ID="${2:-}"; shift 2;;
    --host-path) HOST_PATH="${2:-}"; shift 2;;
    --browser) BROWSER="${2:-}"; shift 2;;
    --user-data-dir) USER_DATA_DIR="${2:-}"; shift 2;;
    --apply) APPLY=1; shift;;
    --help) echo "Usage: $0 --extension-id ID --host-path PATH --browser chrome|brave|edge [--user-data-dir PATH] [--apply]"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[[ -n "$EXTENSION_ID" && -n "$HOST_PATH" ]] || { echo "--extension-id and --host-path are required" >&2; exit 2; }
[[ "$EXTENSION_ID" =~ ^[a-p]{32}$ ]] || { echo "--extension-id must be a 32-character Chromium extension ID" >&2; exit 2; }
[[ "$HOST_PATH" = /* && -f "$HOST_PATH" && -x "$HOST_PATH" ]] || { echo "--host-path must be an absolute executable file path" >&2; exit 2; }
HOST_RESOURCE_BUNDLE="$(dirname "$HOST_PATH")/LinkDigest_LinkDigestCore.bundle"
[[ -d "$HOST_RESOURCE_BUNDLE" && -r "$HOST_RESOURCE_BUNDLE" ]] || { echo "Native Host resource bundle is missing or unreadable: $HOST_RESOURCE_BUNDLE" >&2; exit 2; }
HOST_SCHEMA="$HOST_RESOURCE_BUNDLE/Resources/contracts/capture-envelope-v1.schema.json"
[[ -f "$HOST_SCHEMA" && -r "$HOST_SCHEMA" ]] || { echo "Native Host contract schema is missing or unreadable: $HOST_SCHEMA" >&2; exit 2; }
case "$HOST_PATH" in
  */Documents/*|*/Desktop/*|*/Downloads/*)
    echo "WARNING: Host is inside a macOS privacy-protected folder; a browser-launched process may wait for TCC permission. Stage the executable and resource bundle outside Documents/Desktop/Downloads for real-browser acceptance." >&2
    ;;
esac
case "$BROWSER" in
  chrome)
    [[ -z "$USER_DATA_DIR" ]] || { echo "--user-data-dir is supported only with --browser edge" >&2; exit 2; }
    TARGET_ROOT="$HOME"
    TARGETS=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts")
    ;;
  brave)
    [[ -z "$USER_DATA_DIR" ]] || { echo "--user-data-dir is supported only with --browser edge" >&2; exit 2; }
    TARGET_ROOT="$HOME"
    TARGETS=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts")
    ;;
  edge)
    if [[ -n "$USER_DATA_DIR" ]]; then
      EDGE_PROFILE_SCOPED=1
      TARGET_ROOT="$USER_DATA_DIR"
      TARGETS=("$USER_DATA_DIR/NativeMessagingHosts")
    else
      TARGET_ROOT="$HOME"
      TARGETS=("$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts")
    fi
    ;;
  *) echo "--browser is required and must be chrome, brave, or edge" >&2; exit 2;;
esac

assert_no_target_root_symlink_components() {
  local root="$1"
  local target="$2"
  [[ "$root" = /* ]] || { echo "target root must be an absolute path" >&2; exit 2; }
  [[ ! -L "$root" ]] || { echo "refusing symlink target root: $root" >&2; exit 2; }
  case "$target" in
    "$root"/*) ;;
    *) echo "target is outside root: $target" >&2; exit 2;;
  esac
  local relative="${target#"$root"/}"
  local current="$root"
  local component
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || { echo "refusing symlink path component: $current" >&2; exit 2; }
  done
}

assert_canonical_edge_profile_path() {
  local profile="$1"
  [[ "$profile" = /* && "$profile" != "/" && "$profile" != */ ]] || {
    echo "--user-data-dir must be a non-root canonical absolute path" >&2
    exit 2
  }
  case "$profile" in
    *//*|*/./*|*/../*|*/.|*/..)
      echo "--user-data-dir must not contain empty, . or .. path components" >&2
      exit 2
      ;;
  esac
  [[ -d "$profile" ]] || { echo "--user-data-dir must be an existing directory" >&2; exit 2; }
}

assert_no_symlink_components_from_root() {
  local path="$1"
  local current=""
  local component
  IFS='/' read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || { echo "refusing symlink profile path component: $current" >&2; exit 2; }
    [[ -d "$current" ]] || { echo "profile path component is not a directory: $current" >&2; exit 2; }
  done
}

assert_edge_profile_target() {
  local profile="$1"
  local target="$2"
  assert_canonical_edge_profile_path "$profile"
  assert_no_symlink_components_from_root "$profile"
  [[ "$target" == "$profile/NativeMessagingHosts" ]] || {
    echo "Edge profile target must be the direct NativeMessagingHosts child" >&2
    exit 2
  }
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] || {
      echo "refusing non-directory or symlink Edge profile target: $target" >&2
      exit 2
    }
  fi
}

for dir in "${TARGETS[@]}"; do
  if [[ $EDGE_PROFILE_SCOPED -eq 1 ]]; then
    assert_edge_profile_target "$TARGET_ROOT" "$dir"
  else
    assert_no_target_root_symlink_components "$TARGET_ROOT" "$dir"
  fi
  file="$dir/$HOST_NAME"
  [[ ! -L "$file" ]] || { echo "refusing symlink target manifest: $file" >&2; exit 2; }
done

printf 'Native host targets (dry-run=%s, browser=%s):\n' "$([[ $APPLY -eq 1 ]] && echo false || echo true)" "$BROWSER"
for dir in "${TARGETS[@]}"; do printf 'TARGET: %s/%s\n' "$dir" "$HOST_NAME"; done
payload=$(python3 -c 'import json,sys; print(json.dumps({"name":"com.syc.linkdigest.v01","description":"LinkDigest V0.1 Native Messaging Host","path":sys.argv[1],"type":"stdio","allowed_origins":["chrome-extension://"+sys.argv[2]+"/"]}, indent=2))' "$HOST_PATH" "$EXTENSION_ID")
if [[ $APPLY -eq 1 ]]; then
  TMP_FILE=""
  report_failed_temp() {
    local status=$?
    trap - EXIT
    if [[ -n "$TMP_FILE" && ( -e "$TMP_FILE" || -L "$TMP_FILE" ) ]]; then
      printf 'ERROR: temporary manifest retained for manual review: %s\n' "$TMP_FILE" >&2
    fi
    exit "$status"
  }
  trap report_failed_temp EXIT
  for dir in "${TARGETS[@]}"; do
    if [[ $EDGE_PROFILE_SCOPED -eq 1 ]]; then
      assert_edge_profile_target "$TARGET_ROOT" "$dir"
      if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        mkdir "$dir"
      fi
      assert_edge_profile_target "$TARGET_ROOT" "$dir"
    else
      mkdir -p "$dir"
      assert_no_target_root_symlink_components "$TARGET_ROOT" "$dir"
    fi
    file="$dir/$HOST_NAME"
    [[ ! -L "$file" ]] || { echo "refusing symlink target manifest: $file" >&2; exit 2; }
    if [[ -e "$file" && ! -f "$file" ]]; then
      echo "refusing non-regular target manifest: $file" >&2
      exit 2
    fi
    if [[ $EDGE_PROFILE_SCOPED -eq 1 ]]; then
      assert_edge_profile_target "$TARGET_ROOT" "$dir"
    fi
    if [[ -e "$file" ]]; then
      timestamp="$(date +%Y%m%d%H%M%S)"
      backup="$file.$timestamp.bak"
      suffix=0
      while [[ -e "$backup" || -L "$backup" ]]; do
        suffix=$((suffix + 1))
        backup="$file.$timestamp.$suffix.bak"
      done
      cp -p "$file" "$backup"
      printf 'BACKUP: %s\n' "$backup"
    else
      printf 'BACKUP: (none; target did not exist)\n'
    fi
    if [[ $EDGE_PROFILE_SCOPED -eq 1 ]]; then
      assert_edge_profile_target "$TARGET_ROOT" "$dir"
    fi
    TMP_FILE="$(mktemp "$dir/.${HOST_NAME}.tmp.XXXXXX")"
    chmod 600 "$TMP_FILE"
    printf '%s\n' "$payload" > "$TMP_FILE"
    mv -f "$TMP_FILE" "$file"
    TMP_FILE=""
  done
  trap - EXIT
fi
echo "Chrome 与 Brave 共享 Google/Chrome 的当前用户 NativeMessagingHosts 目录；Edge 使用独立目录。"
echo "卸载说明：使用 uninstall-plan.sh 查看精确目标，再由人工执行 rm。"
