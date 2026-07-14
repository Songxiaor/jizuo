#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apps/desktop"

for specification in "LinkDigestApp Debug" "LinkDigestApp Release" "LinkDigestNativeHost Debug" "LinkDigestNativeHost Release"; do
  scheme="${specification% *}"
  configuration="${specification##* }"
  log="/tmp/linkdigest-xcode-${scheme}-${configuration}.log"
  xcodebuild -scheme "$scheme" -configuration "$configuration" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1
  grep -q "\*\* BUILD SUCCEEDED \*\*" "$log"
  echo "xcode-build: OK ($scheme $configuration)"
done
