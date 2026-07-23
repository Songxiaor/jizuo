#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-$ROOT/apps/desktop/.build/arm64-apple-macosx/release/LinkDigestApp}"

fail() {
  echo "release-test-seams: FAIL: $*" >&2
  exit 1
}

case "$BINARY" in
  */Tests/*|*.xctest/*) fail "refusing to inspect a test binary" ;;
  */release/LinkDigestApp) ;;
  *) fail "expected a Release LinkDigestApp binary, got $BINARY" ;;
esac

[ -f "$BINARY" ] || fail "Release LinkDigestApp binary is missing: $BINARY"
[ -x "$BINARY" ] || fail "Release LinkDigestApp binary is not executable: $BINARY"
command -v strings >/dev/null 2>&1 || fail "strings is unavailable"
command -v nm >/dev/null 2>&1 || fail "nm is unavailable"
command -v otool >/dev/null 2>&1 || fail "otool is unavailable"

STRING_OUTPUT="$(strings -a "$BINARY")" || fail "strings failed for $BINARY"
SYMBOL_OUTPUT="$(nm -a "$BINARY")" || fail "nm failed for $BINARY"
LINKED_LIBRARIES="$(otool -L "$BINARY")" || fail "otool failed for $BINARY"

if ! printf '%s\n' "$LINKED_LIBRARIES" | grep -Fq $'\t/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit '; then
  fail "required AVKit.framework dependency is missing"
fi

for forbidden in \
  trustAnchorsForTesting \
  eventSinkForTesting \
  verify-anchor-failed \
  connection-ready \
  allowLoopbackForTesting \
  portForTesting; do
  if printf '%s\n%s\n' "$STRING_OUTPUT" "$SYMBOL_OUTPUT" | grep -Fq "$forbidden"; then
    fail "forbidden test seam present: $forbidden"
  fi
done

echo "release-test-seams: OK ($BINARY)"
