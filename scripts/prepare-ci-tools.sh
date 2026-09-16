#!/usr/bin/env bash
set -euo pipefail

# GitHub runners are clean machines. Make every non-package prerequisite used by
# `scripts/doctor` explicit instead of relying on one developer machine.

RG_VERSION="14.1.1"

os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Linux-x86_64|Linux-amd64)
    rg_asset="ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    rg_dir="ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl"
    ;;
  Darwin-arm64)
    rg_asset="ripgrep-${RG_VERSION}-aarch64-apple-darwin.tar.gz"
    rg_dir="ripgrep-${RG_VERSION}-aarch64-apple-darwin"
    ;;
  Darwin-x86_64)
    rg_asset="ripgrep-${RG_VERSION}-x86_64-apple-darwin.tar.gz"
    rg_dir="ripgrep-${RG_VERSION}-x86_64-apple-darwin"
    ;;
  *)
    echo "Unsupported CI platform for pinned ripgrep: $os $arch" >&2
    exit 1
    ;;
esac

need_rg=1
if command -v rg >/dev/null 2>&1; then
  if rg --version | grep -q "$RG_VERSION"; then
    need_rg=0
  fi
fi

if [ "$need_rg" -eq 1 ]; then
  install_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/linkdigest-rg"
  mkdir -p "$install_root"
  url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${rg_asset}"
  curl -fsSL "$url" | tar -xz -C "$install_root"
  export PATH="$install_root/$rg_dir:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$install_root/$rg_dir" >> "$GITHUB_PATH"
  fi
fi

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep installation did not produce rg" >&2
  exit 1
}
rg --version | grep -q "$RG_VERSION" || {
  echo "pinned ripgrep $RG_VERSION is not on PATH" >&2
  rg --version >&2 || true
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

echo "CI verification tools ready: rg@$RG_VERSION + brain-page@$brain_sha"
