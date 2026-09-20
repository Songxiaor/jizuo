# LinkDigest iOS（汲作 Companion）

iOS V1：手写 / 口述文字笔记、粘贴链接笔记、列表查看与复制；与 Mac 通过 **iCloud CloudKit** 同步（推拉已实现）。

## 目录

| 路径 | 作用 |
|---|---|
| `../../packages/LinkDigestShared` | 跨端 `SyncNoteCard`、本地仓库、CloudKit 推拉 |
| `Sources/LinkDigestIOS` | 列表 / 新建 / 详情 UI 与 ViewModel |
| `App/` | `@main` 入口 + entitlements |
| `LinkDigestIOS.xcodeproj` | iOS App Target（Bundle ID `com.syc.linkdigest.ios`） |

## 本机验证（共享逻辑）

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd packages/LinkDigestShared && swift test
cd apps/ios && swift test
```

Mac 上预览 UI 壳（不经签名）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/ios && swift run LinkDigestIOSDevApp
```

## 接到 iPhone 模拟器 / 真机

1. 打开 `apps/ios/LinkDigestIOS.xcodeproj`。
2. Xcode → Settings → **Apple Accounts** → 登录 Apple ID。
3. Target `LinkDigestIOSApp` → **Signing & Capabilities**：选 Team；确认 **iCloud → CloudKit**；容器 `iCloud.com.syc.linkdigest`。
4. 若无 Simulator Runtime：Settings → Platforms/Components 下载 iOS；真机需匹配 Device Support。
5. Run 后点 App 内同步按钮验收。

## 当前边界

- CloudKit **推拉已实现**；真机/模拟器仍依赖本机 Apple 账号与签名。
- 链接自动抓取 + BYOK、桌面 History 映射、Share Extension：未做。
