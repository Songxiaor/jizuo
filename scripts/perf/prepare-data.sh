#!/bin/bash
# 准备测速用的隔离资料：把本机资料库做一份只读快照（sqlite3 .backup，不打扰正在运行的汲作），
# 媒体、缩略图等用 APFS 克隆（不占额外空间），放到 /private/tmp/jz-perf/appsupport/LinkDigest。
# 再把界面相关的偏好（主题、字体、侧栏展开状态……）抄给测速版的包名；模型服务、钥匙串、
# 知识库目录、网站登录这些一概不抄。
set -euo pipefail
SRC="$HOME/Library/Application Support/LinkDigest"
ROOT=/private/tmp/jz-perf
D="$ROOT/appsupport/LinkDigest"
[ -e "$D" ] && { echo "已存在：$D（要重做先自己挪开）"; exit 1; }
mkdir -p "$D"
for x in Media Thumbnails WebsiteFavicons GitHubREADMEImages SemanticIndex; do
  [ -e "$SRC/$x" ] && cp -cR "$SRC/$x" "$D/$x"
done
for f in companion-note-cards-v1.json capture-preferences-v1.json model-display-names.json; do
  [ -e "$SRC/$f" ] && cp -c "$SRC/$f" "$D/$f"
done
sqlite3 "$SRC/history.sqlite" ".backup '$D/history.sqlite'"
cp -c "$D/history.sqlite" "$ROOT/history.pristine.sqlite"
DOMAIN=com.syc.linkdigest
PERF=com.syc.linkdigest.perf
for k in com.syc.linkdigest.appearance-theme com.syc.linkdigest.reading-font com.syc.linkdigest.ui-font; do
  v=$(defaults read $DOMAIN "$k" 2>/dev/null) && defaults write $PERF "$k" -string "$v"
done
v=$(defaults read $DOMAIN com.syc.linkdigest.reading-font-size 2>/dev/null) && defaults write $PERF com.syc.linkdigest.reading-font-size -int "$v"
for k in $(defaults read $DOMAIN | sed -nE 's/^ *"?((history\.navigation|experimental)\.[^"=]*[^" ])"? = (0|1);$/\1/p') \
         com.syc.linkdigest.reading-wide-layout semanticSearch.enabled onboarding.capture-v1.dismissed; do
  v=$(defaults read $DOMAIN "$k" 2>/dev/null) || continue
  case "$v" in 0|1) defaults write $PERF "$k" -bool $([ "$v" = 1 ] && echo YES || echo NO);; *) defaults write $PERF "$k" -int "$v";; esac
done
defaults write $PERF mcp.enabled -bool NO
defaults write $PERF SUEnableAutomaticChecks -bool NO
echo "测速资料已就绪：$D"
