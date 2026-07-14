#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/sync-contracts.sh"
(cd "$ROOT/apps/desktop" && swift build -c debug)
