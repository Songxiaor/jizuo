#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The clean-room fixture must pre-create .transaction.lock with the fixed r2
# content/mode; this wrapper and every CLI subcommand are strictly read-only
# with respect to the lock leaf.
exec python3 "$ROOT/scripts/native-host/transaction_host.py" "$@"
