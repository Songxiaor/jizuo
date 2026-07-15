# P0-RC-02A 本机验收证据（2026-07-15）

- 实施范围：Core History Domain、migration 001、GRDB Repository、维护/故障注入、fixtures、正式 benchmark。
- 明确未做：`LinkDigestApp.swift`、App target → Persistence 接线、socket 返回时序、真实 Provider、真实用户目录、历史 UI。
- 专项测试：History 24/24；Contract 5/5；History Core 4/4。Artifact NUL、UUID extra-hyphen、双 Pool conflict、latest Run/Task sort date 与 2 秒 busy-timeout 收口均覆盖。
- Release benchmark：首页 p95 0.57275 ms，详情 p95 0.129084 ms，30+30 raw samples，阈值 300 ms，PASS；种子含 NUL Artifact并在计时外验证。
- 数据集：10k Task / 12k Snapshot / 15k Run / 15k Artifact，20% 多 Snapshot，33.33% rerun，usage/cost 混合 NULL。
- 关键修复：SQLite TEXT 的 Swift String 绑定/读取会在 U+0000 处截断；正式 Adapter 改为完整 UTF-8 Data → SQLite TEXT 与 BLOB bytes → Swift String 双向路径。
- Swift 完整 suite：71 项中 61 通过；10 项既有环境失败为 Network fake server 8、Keychain 1、Unix socket address-in-use 1；History 24/24 保持通过。
- 构建与仓库门禁：Swift Debug/Release PASS；Debug benchmark 按编译条件以 status 64 拒绝；`pnpm check:web` PASS（shared 10/10、extension 10/10）；JS/Swift licenses、secret scan、doctor `52/1/0`、`git diff --check` PASS。
- Xcode：首个 scheme 在 package resolution 被 Hana 外层 nested sandbox `sandbox_apply: Operation not permitted` 阻断，未修改全局 defaults 或测试绕开。
- 结论：独立 Sol xhigh 复审为 `PASS WITH NON-BLOCKING NOTES`；修订后的 migration 001 是首个已接受并冻结的正式候选，后续 schema 变化只能新增 002+。02B 获准启动但尚未接线。
