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

# 同 check_paths，但允许**逐行**豁免：命中行若带 `secret-hygiene:reviewed`
# 标记，视为已人工审查过，不计入失败。
#
# 为什么需要这个：`unknown-code-visible-sink` 靠正则匹配 `code` 这个标识符名，
# 无法区分「provider 返回的原始文本」和「内部错误码枚举」。实测三处命中全是
# 业务错误码（B站 -101、YouTube 播放器码、内部 catalog 错误码），都安全。
#
# 放宽正则会放过真问题，所以规则本身保持严格；改为要求每一处豁免都写明理由，
# 这样新增的违规照样会被抓住，而已审查的不再持续制造噪音——一个长期误报的
# blocking 检查最终只会被所有人忽略，那才是真正的风险。
#
# 传入的命令必须输出 `文件:行号:内容`（即 rg 带 -n），否则无法逐行判断。
check_lines_waivable() {
  local rule="$1"
  shift
  local hits paths

  hits="$("$@" 2>/dev/null || true)"
  hits="$(printf '%s\n' "$hits" | grep -v 'secret-hygiene:reviewed' || true)"
  paths="$(printf '%s\n' "$hits" | sed -n 's/^\([^:]*\):[0-9]*:.*/\1/p' | sort -u || true)"
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

check_lines_waivable "unknown-code-visible-sink" rg -ni \
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
