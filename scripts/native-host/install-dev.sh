#!/usr/bin/env bash
set -euo pipefail
HOST_NAME="com.syc.linkdigest.v01.json"
EXTENSION_ID=""
HOST_PATH=""
APPLY=0
BROWSER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --extension-id) EXTENSION_ID="${2:-}"; shift 2;;
    --host-path) HOST_PATH="${2:-}"; shift 2;;
    --browser) BROWSER="${2:-}"; shift 2;;
    --apply) APPLY=1; shift;;
    --help) echo "Usage: $0 --extension-id ID --host-path PATH --browser chrome|brave|edge [--apply]"; exit 0;;
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
  chrome|brave) TARGETS=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts");;
  edge) TARGETS=("$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts");;
  *) echo "--browser is required and must be chrome, brave, or edge" >&2; exit 2;;
esac

assert_no_home_symlink_components() {
  local target="$1"
  [[ "$HOME" = /* ]] || { echo "HOME must be an absolute path" >&2; exit 2; }
  [[ ! -L "$HOME" ]] || { echo "refusing symlink HOME: $HOME" >&2; exit 2; }
  case "$target" in
    "$HOME"/*) ;;
    *) echo "target is outside HOME: $target" >&2; exit 2;;
  esac
  local relative="${target#"$HOME"/}"
  local current="$HOME"
  local component
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || { echo "refusing symlink path component: $current" >&2; exit 2; }
  done
}

for dir in "${TARGETS[@]}"; do
  assert_no_home_symlink_components "$dir"
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
    mkdir -p "$dir"
    assert_no_home_symlink_components "$dir"
    file="$dir/$HOST_NAME"
    [[ ! -L "$file" ]] || { echo "refusing symlink target manifest: $file" >&2; exit 2; }
    if [[ -e "$file" && ! -f "$file" ]]; then
      echo "refusing non-regular target manifest: $file" >&2
      exit 2
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
    TMP_FILE="$(mktemp "$dir/.${HOST_NAME}.tmp.XXXXXX")"
    chmod 600 "$TMP_FILE"
    printf '%s\n' "$payload" > "$TMP_FILE"
    mv -f "$TMP_FILE" "$file"
    TMP_FILE=""
  done
  trap - EXIT
fi
echo "Brave 150 当前用户级查找映射到 Chrome 目录；此处不写 BraveSoftware 目录。"
echo "卸载说明：使用 uninstall-plan.sh 查看精确目标，再由人工执行 rm。"
