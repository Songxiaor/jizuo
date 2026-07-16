# Desktop App

负责本地任务、模型设置、提取调度、历史和导出。P0 使用 Swift + SwiftUI；只有富文本、窗口、菜单等明确能力缺口才局部桥接 AppKit。

当前目录已建立 Swift 6 Package，包含 `LinkDigestApp`、`LinkDigestCore`、`LinkDigestAdapters`、`LinkDigestTransport`、`LinkDigestPersistence` 与 `LinkDigestNativeHost`。V0.2 已完成单个 ProviderProfile/Keychain secret、Chat Completions streaming adapter、总结/翻译 RunState、统一中文错误恢复、输出 redaction 和 secret hygiene；V0.3 已完成正式 SQLite/GRDB History、Capture/Run 持久化、原生 Sidebar/详情/确认删除与 future-schema 只读浏览。Loop 2 已接入三格式本地导出，Loop 3 的数据去向确认/连接测试已最终独立复审 PASS。Loop 4 r1 的 `arm64` Release Host package、bundle/checksum verifier 与只在系统临时 clean-room 的首次安装已最终独立 re-review PASS；没有真实 HOME/浏览器 apply、升级、卸载、真实 Provider、签名、公证或发布。

边界：SwiftUI View 不直接访问 Keychain、SQLite、文件系统或模型 Provider；平台能力通过具名 adapter 交给 Application/Domain 层。

```bash
cd apps/desktop
swift test
swift build -c debug
swift build -c release
../../scripts/xcode-build.sh
../../scripts/build-release.sh --output-root /absolute/nonexistent/output-root
../../scripts/native-host/check-stable-package.sh
```
