#!/usr/bin/env bash
set -euo pipefail

# GitHub runners are clean machines. Make every non-package prerequisite used by
# `scripts/doctor` explicit instead of relying on one developer machine.

if ! command -v rg >/dev/null 2>&1; then
  case "$(uname -s)" in
    Linux)
      sudo apt-get update
      sudo apt-get install -y ripgrep
      ;;
    Darwin)
      brew install ripgrep
      ;;
    *)
      echo "Unsupported CI platform for ripgrep installation: $(uname -s)" >&2
      exit 1
      ;;
  esac
fi

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep installation did not produce rg" >&2
  exit 1
}

brain_repo="https://github.com/mindmuxai/brain.md.git"
brain_sha="028ab3fc954f35c6e6efeeb75bdf82f3f98bd75f"
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
brain_checkout="$(mktemp -d "$temp_root/linkdigest-brain-cli.XXXXXX")"

git -C "$brain_checkout" init -q
git -C "$brain_checkout" fetch -q --depth 1 "$brain_repo" "$brain_sha"
git -C "$brain_checkout" checkout -q --detach FETCH_HEAD

brain_cli="$brain_checkout/skills/brain-page/bin/brain.mjs"
test -f "$brain_cli" || {
  echo "Pinned brain-page CLI is missing: $brain_cli" >&2
  exit 1
}

if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'BRAIN_CLI=%s\n' "$brain_cli" >> "$GITHUB_ENV"
else
  echo "BRAIN_CLI=$brain_cli"
fi

echo "CI verification tools ready: rg + brain-page@$brain_sha"
