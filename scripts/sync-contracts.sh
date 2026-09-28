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
