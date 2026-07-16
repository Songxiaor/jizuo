# Desktop App

负责本地任务、模型设置、提取调度、历史和导出。P0 使用 Swift + SwiftUI；只有富文本、窗口、菜单等明确能力缺口才局部桥接 AppKit。

当前目录已建立 Swift 6 Package，包含 `LinkDigestApp`、`LinkDigestCore`、`LinkDigestAdapters`、`LinkDigestTransport`、`LinkDigestPersistence` 与 `LinkDigestNativeHost`。V0.2 任务 A–D 已完成单个 ProviderProfile/Keychain secret、Chat Completions streaming adapter、总结/翻译 RunState 与 UI、统一中文错误恢复、输出 redaction 和 secret hygiene 门禁；V0.3 已完成正式 SQLite/GRDB History、Capture/Run 持久化、原生 Sidebar/详情/确认删除与 future-schema 只读浏览。Loop 2 已在详情分享菜单接入单条 Markdown、`.txt`、JSON 导出：Core renderer 只接收脱敏 projection 并生成确定性 UTF-8 数据，ViewModel 在非 MainActor Repository worker 中准备文件，FileDocument/fileExporter 仅交给 macOS 原生保存面板。取消不报错，保存失败提示检查目录权限；future-schema 的只读历史仍可导出。这些是本地工程验收，不是产品发布。设置页连接测试、Q&A、多 Provider、真实 Provider 自动测试、稳定安装、签名、公证、发布包、云端与正式视觉品牌仍未实现。

边界：SwiftUI View 不直接访问 Keychain、SQLite、文件系统或模型 Provider；平台能力通过具名 adapter 交给 Application/Domain 层。

```bash
cd apps/desktop
swift test
swift build -c debug
swift build -c release
../../scripts/xcode-build.sh
```
