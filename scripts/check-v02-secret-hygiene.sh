#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0

report_paths() {
  local rule="$1"
  local paths="$2"
  [ -z "$paths" ] && return

  echo "secret-hygiene: FAIL rule=$rule" >&2
  printf '%s\n' "$paths" >&2
  FAILED=1
}

check_paths() {
  local rule="$1"
  shift
  local paths

  paths="$("$@" 2>/dev/null || true)"
  report_paths "$rule" "$paths"
}

secret_pattern='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sk-(proj-)?[A-Za-z0-9_-]{32,}|gh[pousr]_[A-Za-z0-9]{20,}'
check_paths "high-confidence-secret" rg -l --hidden \
  -g '!.git/**' \
  -g '!.scatter/**' \
  -g '!node_modules/**' \
  -g '!**/.build/**' \
  -g '!**/.output/**' \
  -g '!**/DerivedData/**' \
  "$secret_pattern" .

check_paths "sensitive-production-log" rg -liU \
  '(print|debugPrint|NSLog|os_log|Logger)[[:space:]]*\((?s:.{0,400})(apiKey|authorization|cookie|token|secret|password|headers?|responseBody|rawBody)' \
  apps/desktop/Sources

check_paths "observable-secret-property" rg -liU \
  '(@Published|@Observable)(?s:.{0,160})(var|let)[[:space:]]+(apiKey|authorization|cookie|token|secret|password)\b' \
  apps/desktop/Sources/LinkDigestApp

run_state_path="apps/desktop/Sources/LinkDigestCore/ModelRunOrchestrator.swift"
if sed -n '/public enum RunState/,/public actor ModelRunOrchestrator/p' "$run_state_path" \
  | rg -qi '^[[:space:]]*case[^\n]*(apiKey|authorization|cookie|token|secret|password)\b'; then
  report_paths "run-state-secret-field" "$run_state_path"
fi

check_paths "fixture-or-snapshot-secret" rg -li \
  -g '**/fixtures/**' \
  -g '**/snapshots/**' \
  -g '*.snap' \
  -g '*.snapshot' \
  '"(apiKey|authorization|cookie|token|secret|password)"[[:space:]]*:|Bearer[[:space:]]+[A-Za-z0-9._-]{16,}|sk-(proj-)?[A-Za-z0-9_-]{32,}' \
  .

check_paths "unknown-code-visible-sink" rg -li \
  '"[^"\n]*\\\([[:space:]]*code[[:space:]]*\)|Text[[:space:]]*\([[:space:]]*(verbatim:[[:space:]]*)?code[[:space:]]*\)|((statusText|message|recoveryAction|visibleText)[[:space:]]*[:=]|return)[[:space:]]*code\b' \
  apps/desktop/Sources/LinkDigestApp

check_paths "userdefaults-secret-storage" rg -li \
  '(apiKey|authorization|cookie|token|password|secretValue|rawSecret|credential)' \
  apps/desktop/Sources/LinkDigestAdapters/UserDefaultsProviderProfileStore.swift

if [ "$FAILED" -ne 0 ]; then
  echo "secret-hygiene: FAILED (only rule names and paths are shown)" >&2
  exit 1
fi

echo "secret-hygiene: OK"
