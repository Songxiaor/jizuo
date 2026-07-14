# Desktop App

负责本地任务、模型设置、提取调度、历史和导出。P0 使用 Swift + SwiftUI；只有富文本、窗口、菜单等明确能力缺口才局部桥接 AppKit。

当前目录已建立 Swift 6 Package，包含 `LinkDigestApp`、`LinkDigestCore`、`LinkDigestAdapters`、`LinkDigestTransport` 与 `LinkDigestNativeHost`。V0.2 任务 A–D 已完成单个 ProviderProfile/Keychain secret、Chat Completions streaming adapter、总结/翻译 RunState 与 UI、统一中文错误恢复、输出 redaction 和 secret hygiene 门禁；这是本地工程验收，不是产品发布。设置页连接测试、SQLite、历史、导出、Q&A、多 Provider、真实 Provider 自动测试、Edge 验收、签名、公证、发布包、云端与正式视觉品牌仍未实现。

边界：SwiftUI View 不直接访问 Keychain、SQLite、文件系统或模型 Provider；平台能力通过具名 adapter 交给 Application/Domain 层。

```bash
cd apps/desktop
swift test
swift build -c debug
swift build -c release
../../scripts/xcode-build.sh
```
