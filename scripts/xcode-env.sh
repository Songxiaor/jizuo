#!/usr/bin/env bash
# 项目内 Xcode 工具链选择（供脚本 source 使用；不改全局 xcode-select）：
# 本机默认 xcode-select 可能指向 CommandLineTools，其 swift 没有 XCTest
# 模块，直接 `swift test` 会报 `no such module 'XCTest'`；完整 Xcode 可通过。
# 规则：已显式设置 DEVELOPER_DIR 时尊重；否则仅当系统默认不是完整 Xcode、
# 且标准路径存在完整 Xcode 时，为本命令导出 DEVELOPER_DIR。
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    /Applications/*Xcode* | /Library/Developer/*Xcode*)
      ;; # 默认已是完整 Xcode，保持原样（CI 场景）
    *)
      if [ -d "/Applications/Xcode.app/Contents/Developer/Toolchains" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
      fi
      ;;
  esac
fi
