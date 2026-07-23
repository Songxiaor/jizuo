#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$ROOT/scripts/native-host/transaction_host_check.py"
