#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=C \
  LC_ALL=C \
  PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/python3 "$ROOT/scripts/native-host/local_test_release_check.py" "$@"
