#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUTPUT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root)
      OUTPUT_ROOT="${2:-}"
      shift 2
      ;;
    --help)
      echo "Usage: $0 --output-root /absolute/nonexistent/path"
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$OUTPUT_ROOT" ]] || { echo "--output-root is required" >&2; exit 2; }
[[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != / && "$OUTPUT_ROOT" != */ ]] || {
  echo "--output-root must be a non-root canonical absolute path" >&2
  exit 2
}
case "$OUTPUT_ROOT" in
  *//*|*/./*|*/../*|*/.|*/..)
    echo "--output-root must not contain empty, . or .. path components" >&2
    exit 2
    ;;
esac
[[ ! -e "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] || {
  echo "--output-root must not already exist" >&2
  exit 2
}
OUTPUT_PARENT="$(dirname "$OUTPUT_ROOT")"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || {
  echo "--output-root parent must be an existing real directory" >&2
  exit 2
}
[[ "$(cd "$OUTPUT_PARENT" && pwd -P)" == "$OUTPUT_PARENT" ]] || {
  echo "--output-root parent must be canonical and contain no symlink components" >&2
  exit 2
}

"$ROOT/scripts/sync-contracts.sh"
python3 "$ROOT/scripts/native-host/stable_host.py" check-config

SCRATCH_PATH="${LINKDIGEST_SWIFTPM_SCRATCH_PATH:-$ROOT/apps/desktop/.build}"
BUILD_HOME="${LINKDIGEST_BUILD_HOME:-$SCRATCH_PATH/release-build-home}"
MODULE_CACHE="${LINKDIGEST_MODULE_CACHE_PATH:-$SCRATCH_PATH/release-module-cache}"
CONFIG_PATH="${LINKDIGEST_SWIFTPM_CONFIG_PATH:-$SCRATCH_PATH/release-swiftpm-config}"
CACHE_PATH="${LINKDIGEST_SWIFTPM_CACHE_PATH:-$SCRATCH_PATH/release-swiftpm-cache}"
mkdir -p "$BUILD_HOME" "$MODULE_CACHE" "$CONFIG_PATH" "$CACHE_PATH"

SWIFT_ARGS=(
  --package-path "$ROOT/apps/desktop"
  --configuration release
  --disable-sandbox
  --disable-netrc
  --skip-update
  --config-path "$CONFIG_PATH"
  --cache-path "$CACHE_PATH"
  --scratch-path "$SCRATCH_PATH"
)

HOME="$BUILD_HOME" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
swift build "${SWIFT_ARGS[@]}"
BIN_PATH="$(HOME="$BUILD_HOME" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFT_MODULECACHE_PATH="$MODULE_CACHE" swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

read_config() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' \
    "$ROOT/config/native-host.json" "$1"
}

VERSION="$(read_config productVersion)"
ARCHITECTURE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["architectures"][0])' "$ROOT/config/native-host.json")"
ENTRYPOINT="$(read_config entrypoint)"
RESOURCE_BUNDLE="$(read_config resourceBundle)"
PACKAGE_NAME="LinkDigestNativeHost-${VERSION}-macos-${ARCHITECTURE}"

[[ -x "$BIN_PATH/$ENTRYPOINT" ]] || { echo "Release Host is missing: $BIN_PATH/$ENTRYPOINT" >&2; exit 1; }
[[ -d "$BIN_PATH/$RESOURCE_BUNDLE" && ! -L "$BIN_PATH/$RESOURCE_BUNDLE" ]] || {
  echo "Release resource bundle is missing: $BIN_PATH/$RESOURCE_BUNDLE" >&2
  exit 1
}
[[ ! -e "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] || {
  echo "--output-root appeared during build; refusing overwrite" >&2
  exit 2
}
mkdir -m 0755 "$OUTPUT_ROOT"

PACKAGE_ROOT="$OUTPUT_ROOT/$PACKAGE_NAME"
python3 "$ROOT/scripts/native-host/stable_host.py" create-package \
  --host-source "$BIN_PATH/$ENTRYPOINT" \
  --bundle-source "$BIN_PATH/$RESOURCE_BUNDLE" \
  --package-root "$PACKAGE_ROOT"
python3 "$ROOT/scripts/native-host/stable_host.py" verify-package --package-root "$PACKAGE_ROOT"
printf 'stable release package: %s\n' "$PACKAGE_ROOT"
