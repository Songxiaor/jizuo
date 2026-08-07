#!/usr/bin/env bash
set -euo pipefail

# 打包好的 .app 能不能在别人的机器上跑起来。
#
# 为什么单元测试和现有 smoke 都盖不住这件事：它们跑的是 `.build/debug` 里的裸
# 可执行文件，那条路径上资源包永远找得到（就在二进制旁边），而换机崩恰恰是
# `.app` 这条路径独有的。历史上真崩过两次，两次单元测试都是绿的：
#
#   1. 资源包放进 Contents/Resources（位置对、可签名），但代码走的是
#      `Bundle.module`——它只认 .app 根目录和一条编译期写死的本机 .build 绝对
#      路径，两处都不命中。本机靠 .build 兜底，换机启动即 fatal error。
#   2. 转 universal 构建后 SwiftPM 把扁平资源包改成标准 macOS 包，资源多套了
#      一层 Resources/，`url(forResource:)` 在资源根一个文件都找不到。
#      表现是 App 启动即崩，崩在任何窗口出现之前。
#
# 所以这里不只看「目录在不在」，而是**复刻 CoreResourceBundle 的查找规则**，
# 按它实际会用的资源根去找那几个必需文件。规则变了这个脚本就得跟着变——这正是
# 它该报警的时候。
#
# 只读检查，不启动 App、不改任何文件。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"

fail() {
  echo "app-bundle: FAIL: $*" >&2
  exit 1
}

if [ -z "$APP" ]; then
  display_name="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["appDisplayName"])' "$ROOT/config/app-release.json")" \
    || fail "cannot read appDisplayName from config/app-release.json"
  APP="$HOME/Applications/$display_name.app"
fi

[ -d "$APP" ] || fail "not an app bundle: $APP"
case "$APP" in
  *.app) ;;
  *) fail "expected a path ending in .app, got $APP" ;;
esac

executable="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["executable"])' "$ROOT/config/app-release.json")" \
  || fail "cannot read executable from config/app-release.json"

BINARY="$APP/Contents/MacOS/$executable"
[ -x "$BINARY" ] || fail "missing or non-executable binary: $BINARY"
[ -f "$APP/Contents/Info.plist" ] || fail "missing Info.plist"

# --- 1. 资源包在 .app 里，且资源根按代码的规则解析得出来 -------------------

BUNDLE_NAME="LinkDigest_LinkDigestCore.bundle"
package_root="$APP/Contents/Resources/$BUNDLE_NAME"
[ -d "$package_root" ] || fail "resource bundle missing: $package_root"

# 与 CoreResourceBundle.bundle(inDirectory:) 同一条规则：内层 Contents/Resources/
# Resources 存在就用它当资源根（universal 构建的布局），否则用包根（扁平构建）。
nested="$package_root/Contents/Resources/Resources"
if [ -d "$nested" ]; then
  resource_root="$nested"
  layout="universal(nested)"
else
  resource_root="$package_root"
  layout="flat"
fi

# 生产路径上真正会被读的资源。少一个就是「App 起来后某条链路静默失灵」或直接崩，
# 而不是编译错误——所以必须逐个点名，不能只数文件个数。
required_resources=(
  "product-display.json"
  "browser-support/manifest-integrity.json"
  "contracts/capture-envelope-v1.schema.json"
  "contracts/capture-envelope-v2.schema.json"
  "contracts/native-response-fixtures.json"
)
for relative in "${required_resources[@]}"; do
  [ -f "$resource_root/$relative" ] \
    || fail "resource not reachable from the bundle's resource root ($layout): $relative"
done

# --- 2. Native host 一起进了包 ---------------------------------------------

[ -d "$APP/Contents/Resources/NativeHost" ] || fail "missing Contents/Resources/NativeHost"

# --- 3. 两种芯片都能跑 ------------------------------------------------------

# 对外承诺支持 Intel Mac。缺一个架构时，本机（Apple silicon）完全正常，
# 只有 Intel 用户打不开——是最难自查的一类回归。
arches="$(/usr/bin/lipo -archs "$BINARY" 2>/dev/null)" || fail "lipo could not read $BINARY"
for arch in arm64 x86_64; do
  case " $arches " in
    *" $arch "*) ;;
    *) fail "binary is not universal; missing $arch (has: $arches)" ;;
  esac
done

# --- 4. 签名完整 ------------------------------------------------------------

# --deep --strict 才会走进嵌套的资源包。少了它，资源包被改动过也照样报 valid。
/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null \
  || fail "code signature is not valid (run codesign --verify --deep --strict for detail)"

echo "app-bundle: OK ($APP, $layout, $arches)"
