#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/contracts"
DESTINATION="$ROOT/apps/desktop/Sources/LinkDigestCore/Resources/contracts"

mkdir -p "$DESTINATION/fixtures"
cp "$SOURCE/capture-envelope-v1.schema.json" "$DESTINATION/"
cp "$SOURCE/capture-envelope-v2.schema.json" "$DESTINATION/"
cp "$SOURCE/x-profile-candidates-v1.schema.json" "$DESTINATION/"
cp "$SOURCE/native-response-fixtures.json" "$DESTINATION/"
cp "$SOURCE/fixtures/"*.json "$DESTINATION/fixtures/"

# 评论收集脚本：App 内「抓取评论」在隐藏网页里运行的就是扩展这份构建产物，
# 两边同一份实现。扩展没构建过时保留仓库里已有的副本。
COMMENT_SCRIPT="$ROOT/apps/browser-extension/.output/chrome-mv3/extract-comments.js"
if [ -f "$COMMENT_SCRIPT" ]; then
  mkdir -p "$DESTINATION/../browser-scripts"
  cp "$COMMENT_SCRIPT" "$DESTINATION/../browser-scripts/extract-comments.js"
fi

# 正文提取脚本：App 里「添加链接」在隐藏网页里运行的也是扩展这份构建产物，
# 扩展和 App 两条抓取路用同一份正文提取（2026-10-02）。
for PAGE_SCRIPT_NAME in extract-page extract-youtube; do
  PAGE_SCRIPT="$ROOT/apps/browser-extension/.output/chrome-mv3/$PAGE_SCRIPT_NAME.js"
  if [ -f "$PAGE_SCRIPT" ]; then
    mkdir -p "$DESTINATION/../browser-scripts"
    cp "$PAGE_SCRIPT" "$DESTINATION/../browser-scripts/$PAGE_SCRIPT_NAME.js"
  fi
done
