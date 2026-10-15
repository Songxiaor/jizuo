#!/bin/bash
# 用法: scripts/perf/make-perf-app.sh <名字>
# 把测速构建（.build-perf，带 -DLINKDIGEST_PERF）的二进制装进本机正式版汲作的外壳，
# 放到 /private/tmp/jz-perf/<名字>.app。改了包名（com.syc.linkdigest.perf）和可执行文件名
# （LinkDigestPerf），不接 linkdigest:// 链接，不查更新；正式版和用户数据都不动。
# 先构建：
#   source scripts/xcode-env.sh && swift build -c release --package-path apps/desktop \
#     --scratch-path apps/desktop/.build-perf --disable-sandbox --skip-update \
#     --product LinkDigestApp -Xswiftc -DLINKDIGEST_PERF
set -euo pipefail
NAME="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/apps/desktop/.build-perf/release"
SHELL_APP="${PERF_SHELL_APP:-$HOME/Applications/汲作.app}/Contents"
DEST="/private/tmp/jz-perf/$NAME.app"
[ -e "$DEST" ] && { echo "exists: $DEST"; exit 1; }
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
ditto "$SHELL_APP/Frameworks" "$DEST/Contents/Frameworks"
cp "$SHELL_APP/Info.plist" "$DEST/Contents/Info.plist"
[ -e "$SHELL_APP/PkgInfo" ] && cp "$SHELL_APP/PkgInfo" "$DEST/Contents/PkgInfo"
for item in "$SHELL_APP/Resources"/*; do
  base=$(basename "$item")
  [ "$base" = "LinkDigest_LinkDigestCore.bundle" ] && continue
  ditto "$item" "$DEST/Contents/Resources/$base"
done
ditto "$SRC/LinkDigest_LinkDigestCore.bundle" "$DEST/Contents/Resources/LinkDigest_LinkDigestCore.bundle"
cp "$SHELL_APP/MacOS/LinkDigestMCP" "$DEST/Contents/MacOS/LinkDigestMCP"
cp "$SRC/LinkDigestApp" "$DEST/Contents/MacOS/LinkDigestPerf"
install_name_tool -add_rpath @executable_path/../Frameworks "$DEST/Contents/MacOS/LinkDigestPerf" 2>/dev/null || true
PL="$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.syc.linkdigest.perf" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LinkDigestPerf" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleName 汲作测速" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 汲作测速" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 汲作测速" "$PL"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$PL"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PL" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$DEST" >/dev/null 2>&1
codesign --verify --deep --strict "$DEST" && echo "built $DEST"
