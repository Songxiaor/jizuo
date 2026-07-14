#!/usr/bin/env bash
set -euo pipefail

HOST_NAME="com.syc.linkdigest.v01.json"
BROWSER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser) BROWSER="${2:-}"; shift 2;;
    --help) echo "Usage: $0 --browser chrome|brave|edge"; exit 0;;
    --apply|--rm|--delete) echo "This script is read-only; use no destructive options." >&2; exit 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

case "$BROWSER" in
  chrome|brave) TARGET_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts";;
  edge) TARGET_DIR="$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts";;
  *) echo "--browser is required and must be chrome, brave, or edge" >&2; exit 2;;
esac

TARGET="$TARGET_DIR/$HOST_NAME"
printf 'READ-ONLY UNINSTALL PLAN (browser=%s)\n' "$BROWSER"
printf 'TARGET: %s\n' "$TARGET"
if [[ -L "$TARGET" ]]; then
  printf 'STATE: symlink (manual removal required)\n'
  printf 'MANUAL REMOVE: rm %q\n' "$TARGET"
elif [[ -e "$TARGET" ]]; then
  printf 'STATE: exists\n'
  printf 'MANUAL REMOVE: rm %q\n' "$TARGET"
else
  printf 'STATE: absent\n'
  printf 'MANUAL REMOVE: no action (target is absent)\n'
fi

found_backup=0
for backup in "$TARGET_DIR/$HOST_NAME".*.bak; do
  [[ -e "$backup" || -L "$backup" ]] || continue
  found_backup=1
  if [[ -L "$backup" ]]; then
    printf 'BACKUP: symlink ignored: %s\n' "$backup"
  else
    printf 'BACKUP: %s\n' "$backup"
    printf 'MANUAL RESTORE: cp -p %q %q\n' "$backup" "$TARGET"
  fi
done
if [[ "$found_backup" -eq 0 ]]; then
  printf 'BACKUP: none found for this basename\n'
fi
printf '不读取文件内容、不修改。\n'
