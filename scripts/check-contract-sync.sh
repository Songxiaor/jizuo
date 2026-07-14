#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/contracts"
DESTINATION="$ROOT/apps/desktop/Sources/LinkDigestCore/Resources/contracts"

cmp "$SOURCE/capture-envelope-v1.schema.json" "$DESTINATION/capture-envelope-v1.schema.json"
for source in "$SOURCE/fixtures/"*.json; do
  cmp "$source" "$DESTINATION/fixtures/$(basename "$source")"
done

echo "contract-sync: OK"
