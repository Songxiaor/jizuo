#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/contracts"
DESTINATION="$ROOT/apps/desktop/Sources/LinkDigestCore/Resources/contracts"

mkdir -p "$DESTINATION/fixtures"
cp "$SOURCE/capture-envelope-v1.schema.json" "$DESTINATION/"
cp "$SOURCE/capture-envelope-v2.schema.json" "$DESTINATION/"
cp "$SOURCE/fixtures/"*.json "$DESTINATION/fixtures/"
