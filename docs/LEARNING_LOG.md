# LinkDigest 学习日志

学习日志记录“哪项任务工程上完成了、AI 在过程中解释了什么、哪里可以继续深挖”。它不是开发日报，也不是要求 Syc 课后答题的成绩单。

## 状态说明

- **工程进行中**：功能或文档仍在实施。
- **工程完成**：产物已经验证，场景、角色与交接、工作流和工具协同已在过程中讲解并留下入口。
- **可选深挖**：不是任务状态；Syc 对某个概念感兴趣或仍有疑问时，可另开小窗口学习，不阻塞主开发流程。

## 任务 001：建立项目骨架与完整 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：把模糊产品想法变成可持续开发、可最终上架的真实项目。
- 工程产物：项目目录、PRD、架构建议、学习指南、Project Brain 骨架和本地 Git 仓库。
- 本次核心名词：Repository、PRD、Project Brain、Git、Monorepo。
- 自动验证：PRD lint 通过；`package.json` 可解析；Brain 链接检查通过；Git 分支为 `main`。
- 过程讲解重点：
  1. PRD 和代码分别解决什么问题？
  2. Git 为什么不是网盘？
  3. `apps/` 和 `packages/` 在这个仓库里分别承担什么角色？
- 可选跟做：在 Finder 或编辑器打开项目，找到桌面端、扩展和共享包三个区域；该动作不阻塞后续任务。
- 可选深挖：Repository、Git 或 Monorepo 中任一概念可单独开小窗口学习。

## 任务 002：建立任务级学习闭环

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：避免开发过程变成“AI 写完代码，Syc 只看到结果”。
- 工程产物：任务学习模板、名词词典、学习日志和项目级双验收规则。
- 本次核心名词：Definition of Done（完成定义）、工程验收、学习验收、理解等级。
- 自动验证：三个学习文档均存在；README、项目规则和学习指南已建立入口；Brain `lint-links` 通过并识别 1 个 active 决策页。
- 过程讲解重点：
  1. 为什么自动化测试通过还不等于学习完成？
  2. L1 与 L3 的区别是什么？
  3. 以后一个任务在什么条件下才能标记为“完整完成”？
- 可选跟做：浏览 `TASK_TEMPLATE.md` 的八个部分，观察过程讲解现在位于哪一段；不要求提交答案。
- 可选深挖：理解等级和工程验收可以单独开小窗口学习。

## 任务 003：建立百万注册架构与容量路基

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：从项目第一天就建立可从本地 MVP 平滑增长到 10 万、100 万注册用户的边界，避免因为规模增长推翻客户端、领域模型和 TypeScript 主干。
- 本次只解决：架构、数据边界、稳定协议、容量计算、SLO、扩容与恢复触发条件；不修改 PRD、不安装依赖、不开始功能代码。
- 角色与交接：`ARCHITECTURE.md` 定义扩展、Electron、本地领域核心、云端模块和基础设施的职责；`CAPACITY_MODEL.md` 把注册目标换算成 RPS、jobs/s、数据规模和压测阈值；过程讲解完成后直接交给下一阶段，不设置学习考试门。
- 工程产物：重写 `docs/ARCHITECTURE.md`；新增 `docs/CAPACITY_MODEL.md`；补充五个实际进入项目的架构名词。
- 本次核心名词：Capacity Model、Modular Monolith、RPS、SLO、Idempotency。
- 技术选择：TypeScript 主干、Electron + React、WXT + MV3、Fastify 模块化单体、SQLite 本地事实、PostgreSQL 云端事实、缓存/队列/对象存储为可替换适配层。
- 自动验证：架构与容量 8 项结构断言全部通过；Brain `lint-links` 通过；`package.json` 可解析；未发现 `TODO`、`待补充` 或 placeholder。
- 已确认失败路径：Cloud API、PostgreSQL、队列、对象存储和模型 Provider 故障时的降级与恢复已分别定义；云端故障不得阻止本地提取、BYOK、历史和导出。
- 恢复方式：本阶段只修改架构、容量、词典和学习日志；PRD、代码、依赖和 Git 历史均未改变。产品判断发生反转时，修订文档并通过 Brain CLI 追加 reversal。
- 过程讲解：已在任务开始、架构写入和容量检查三个节点解释场景、组件职责、交接物与选择原因。
- 过程讲解重点：
  1. 为什么 100 万注册用户不等于 100 万人同时请求服务器？
  2. 原文、API Key、账号权益和同步密文分别由谁保存？
  3. 什么证据出现后才允许把模块化单体拆成微服务？
- 可选跟做：打开 `docs/CAPACITY_MODEL.md` 第 4 节，把峰值在线从 10,000 改为 5,000 进行口算；预期目标从 1,000 RPS 变为 500 RPS。该动作不是继续开发的前置条件。
- 可选深挖：Capacity Model、Modular Monolith、RPS、SLO、Idempotency 均可单独开小窗口学习。

## 任务 004：建立唯一 Project Brain 与 doctor 门禁

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：让新的 Agent 或新会话能快速读懂项目，并能发现入口、记忆、架构和规则已经互相漂移。
- 本次只解决：项目记忆播种、统一 Brain CLI、只读健康检查、验证入口和非阻塞学习协作；不安装依赖、不修改 PRD、不提交 Git。
- 角色与交接：README 提供当前入口；AGENTS 规定工作方式；BRAIN 与 9 条 active decision 保存耐久判断；`scripts/brain` 提供统一读写入口；`scripts/doctor` 检查它们是否一致；`VERIFY.md` 解释检查和恢复方式。
- 工程产物：六个已播种 Brain 根页面、8 条新架构决策、学习契约 reversal、`scripts/brain`、`scripts/check-brain-root`、`scripts/doctor`、`VERIFY.md`、五条 APP 学习主线。
- 本次核心名词：Single Source of Truth、Bootstrap、Doctor、Drift。
- 自动验证：`./scripts/doctor` 实跑为 `PASS=35 WARN=2 FAIL=0`；两项 WARN 分别是无首次 Git commit 和工作树未提交，均需要 Syc 明确授权而不是脚本自动处理。
- 已确认失败路径：Brain CLI 缺失、根页面仍为 placeholder、坏链、阻塞式学习旧文案、敏感文件候选和缺少 Git 基线都有独立报告与恢复说明。
- 过程讲解：在创建入口、播种 Brain、首次运行 doctor 三个节点解释了唯一真相源、完整文档与耐久决策的区别、doctor 的只读职责及预期 warning。
- 可选跟做：运行 `./scripts/doctor` 并观察五个 section；这不是继续 PRD 重写的前置条件。
- 可选深挖：想了解 Brain timeline、reversal 或 doctor shell 实现时，可分别开一个小窗口学习。

## 任务 005：按百万注册架构重写 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：把 local-first、可选账号、加密同步、托管模型和 10 万/100 万容量边界翻译成用户能看到、开发者能实现、测试能验收的产品规则。
- 本次只解决：更新 11 章 PRD；不安装依赖、不创建账号服务、不购买云资源、不开始功能代码。
- 角色与交接：架构文档提供组件边界，容量模型提供数字与触发条件，PRD 把它们转换成 P0–P3、UI 状态、数据模型、失败路径、SLO 和验收剧本；下一阶段代码只实现 PRD 已确定的最小顺序。
- 工程产物：本地免登录 P0；账号/设备、选择性加密同步、托管模型与额度三个新模块；六个云端稳定模型；四层技术架构；10 万/100 万优先级与性能指标；五条端到端验收剧本。
- 本次核心名词：Identity、Entitlement、Encrypted Blob、Usage Ledger、OIDC Adapter。
- 自动验证：`qiaomu-ai-prd` lint 通过；章节、P0–P3、云端模型和五条验收剧本的额外结构断言通过；`./scripts/doctor` 为 `PASS=35 WARN=2 FAIL=0`。
- 被证据修正的一点：首轮 PRD lint 把 Markdown 方括号、`active-active` 中的“区域 a”和优先级章节重复出现的 `P0` 判为模板/结构问题；已改为不产生歧义的正文，产品语义未改变。
- 过程讲解：在产品分层、账号/同步/托管模块、数据模型、容量优先级和 lint 修复节点分别解释了架构如何变成用户行为，以及为什么不能用百万用户目标过度建设 P0。
- 已确认失败路径：Cloud API、身份 session、同步密钥、版本冲突、对象存储、托管额度、Provider 限流、重复请求、账号删除和容量劣化均有用户提示与恢复动作。
- 可选跟做：按 PRD 第 3.8–3.10 节观察 Identity、Sync、Managed AI 三个模块如何各自拥有状态；不要求提交答案。
- 可选深挖：Identity/OIDC、端到端加密、Usage Ledger 或容量压测均可单独开小窗口学习。

## 任务 006：建立 TypeScript monorepo 与共享协议

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：在扩展、Electron、本地数据库和未来 Cloud API 开工前，先建立一套机器可验证、可锁版本、可在 CI 复现的数据合同。
- 本次只解决：项目级 TypeScript 工具链、lockfile、CI、12 个稳定模型的 Zod Schema 与协议测试；不安装 Electron/React/WXT/Fastify，不连接真实页面、模型、数据库或云端。
- 角色与交接：`common.ts` 提供共同 ID、时间、请求与错误；`local.ts` 提供捕获、任务、快照、运行和结果；`cloud.ts` 提供用户、设备、权益、同步密文和用量流水；index 统一导出给后续应用。
- 工程产物：pnpm workspace 工具链、TypeScript/ESLint/Vitest、`pnpm-lock.yaml`、固定 SHA 的 GitHub CI、`@linkdigest/shared`、许可证清单与门禁。
- 本次核心名词：Dependency、Lockfile、Schema、Type Check、Contract Test。
- 被证据修正的一点：最新 TypeScript 7.0.2 超出 typescript-eslint 的 `<6.1.0` peer dependency，改为兼容的 TypeScript 6.0.3；没有为了追最新版制造工具冲突。
- 自动验证：`pnpm check` 通过；lint 和 typecheck 通过；Vitest 9 项协议测试通过；frozen-lockfile 安装通过；生产与完整依赖审计均未发现已知漏洞；doctor 无失败。
- 协议失败证据：拒绝 `CaptureEnvelopeV1` 的 version 2、非 HTTP(S) URL、正文字符数不一致、持久快照字符数不一致、AppError 未声明 `apiKey` 字段，以及用户与 Blob 不一致的对象存储路径。
- 许可证证据：生产依赖仅 Zod/MIT；全依赖树无 GPL、AGPL、非商业、UNLICENSED 或 UNKNOWN 包；开发链 MPL-2.0 已单独记录。
- 过程讲解：在依赖选择、兼容修正、Schema 分层、安装、四道门和许可证检查节点解释了每个工具的场景、职责、交接与失败表现。
- 安全边界：Schema 负责格式、版本和对象自洽；未来 Cloud API 仍必须用登录身份重新判断资源归属，不能把客户端传来的 `userId` 当作授权证据。
- 可选跟做：运行 `pnpm --filter @linkdigest/shared test` 观察 9 个合同测试；该动作不阻塞下一阶段。
- 可选深挖：Zod、TypeScript 类型推导、CI SHA 固定或 peer dependency 可分别开小窗口学习。

## 任务 007：收敛 macOS 原生第一版并重构 PRD

- 日期：2026-07-13
- 当前状态：工程完成
- 用户场景：第一版只做 Apple 平台，并把 Sam 一类原生 UI 质感作为产品价值，不再让远期 Windows 与百万容量规划主导当前实现。
- 本次只解决：冻结 SwiftUI + 少量 AppKit 桌面路线；保留 TypeScript/WXT Chromium 扩展；精简 P0 PRD；建立 V0.1 垂直切片；同步 Architecture、README、验证与 Project Brain。
- 明确不做：创建 Xcode 工程、安装 WXT/Swift 依赖、修改现有 TypeScript 合同代码、建立账号/云端、提交或推送 Git。
- 角色与交接：扩展读取当前页面并交出版本化 JSON；Native Host 校验 framing 与版本；Swift Local Core 转成领域对象；SwiftUI 展示用户可观察结果。
- 本次核心名词：SwiftUI、AppKit Bridge、Native Host、Vertical Slice、Reversal。
- 被修正的判断：旧路线认为共享 TypeScript 源码和未来 Windows 的复用价值高于 Mac 原生体验；在第一版 Apple-only 且 UI 是差异点的约束下，桌面端改为 SwiftUI，TypeScript 只保留在浏览器扩展和现有协议原型。
- 工程产物：当前 PRD、V0.1 规格、当前 Architecture、旧方案归档、项目入口和 doctor 真相源更新；Project Brain 新增 SwiftUI 混合架构决策，旧 TypeScript 主干、百万容量、同步和托管模型四条决策以 reversal 归档。
- 自动验证：`pnpm check` 全部通过；ESLint、TypeScript typecheck 和 Vitest 9 项合同测试通过；Brain `lint-links` 为 10 pages / 6 roots / 0 broken links；doctor 为 `PASS=45 WARN=2 FAIL=0`，两项 WARN 仍是无首次 commit 和工作树未提交。
- 失败与恢复：如果 Native Messaging 公证、安装或跨语言合同 spike 失败，先保留协议与证据并重新评估 Helper 结构；不能因一次 spike 失败静默改回 Electron。
- 可选跟做：对照 `docs/PRD.md` 的 P0“必须完成/明确不做”，观察第一版范围如何从账号、同步和百万容量收敛到一条本地闭环；不要求提交答案。
- 可选深挖：SwiftUI/AppKit 分工、Native Messaging framing 或跨语言 JSON Schema 可分别开小窗口学习。

## 任务 008：建立 V0.1 当前页到 SwiftUI 自动化垂直链路

- 日期：2026-07-14
- 当前状态：工程进行中（自动化链路与 Chrome/Brave 真实验收完成；Edge 真实验收待授权）
- 用户场景：用户在 Chromium 当前文章页点击扩展，标题、URL、正文、捕获方式和字符数进入本机 SwiftUI APP；APP 或 Host 不可用时得到可恢复错误。
- 本次只解决：语言中立合同、固定文章提取、MV3 background、Native Messaging framing、独立 Host、APP socket inbox 与 SwiftUI 展示；不实现模型、SQLite、账号、云、签名、公证或正式视觉。
- 角色与交接：Popup 接收用户动作；注入函数读取 DOM；background 交出 `CaptureEnvelopeV1`；Native Host 校验 framing 与合同；Unix domain socket 交给 APP；Application inbox 幂等接收；SwiftUI 只展示状态。
- 本次核心名词：`CaptureEnvelopeV1`、JSON Schema、Native Messaging Framing、Application Boundary、Idempotency。
- 技术选择：JSON Schema Draft 2020-12 是跨语言唯一合同；TypeScript 使用 Ajv，Swift 运行时执行打包的同一 Schema；Schema 无法表达的字符数 invariant 由两端同 fixtures 验证。Host 与 APP 用用户私有 Unix socket；APP 离线返回 `APP_UNAVAILABLE`，不自动拉起。
- 被证据修正的判断：
  1. 首轮 Xcode 使用了错误的 `-packagePath` 参数，实际从 `apps/desktop` 运行 `xcodebuild -scheme ...` 可以发现并构建 Swift Package schemes。
  2. 首轮 Swift 只同步 Schema 文件但未执行完整 Schema，无法防止 `usedCookie=true`、非法枚举和时间越过边界；已增加 Swift JSON Schema evaluator 与专项测试。
  3. 首轮 APP 串行读取连接，半包不结束会阻塞后续消息；已改为每连接独立 task、读写超时，并用 stalled client + 20 条消息验证隔离。
  4. WXT 双许可传递依赖被旧 checker 误判为 GPL-only；检查器现按 SPDX `OR` 选择 MIT/BSD 路径，纯 GPL/AGPL 仍失败。
  5. Node/Vitest 中可运行的 Ajv runtime compiler 在 Chrome MV3 Service Worker 中被 CSP 拒绝；已改为构建期生成静态 validator，并加入同 fixtures 与无动态代码生成测试。
  6. 终端可直接启动的 Host 从 Chrome 启动时会因 `Documents` TCC 等待权限；单独搬 executable 又缺 Swift resource bundle。真实验收改为成对暂存 executable + resource bundle，正式安装边界由“一个二进制”修正为“签名 Host 与合同资源的完整交付单元”。
  7. Brave 150 在 macOS 上把用户级 Native Messaging 查找目录兼容映射到 Chrome 的注册位置；现场进程时间线与对应源码一致。验收因此以“确认实际生效的 manifest”作为交接检查，不把浏览器品牌目录名本身当作真相源，也不把当前版本行为外推为永久规则。
- 自动验证：shared 10 tests、extension 6 tests、Swift 11 tests；WXT MV3 build；Swift/Xcode App 与 Host Debug/Release；Host 离线/超限 smoke；stalled client + 20/20 vertical smoke；doctor 无 FAIL。Chrome 真实触发另完成 APP 离线 `APP_UNAVAILABLE`、SwiftUI 字段观察和 20/20 Release p95 `49.2 ms`；Brave 隔离 Profile 完成离线错误、在线接收和 20/20 p95 `34.9 ms`。完整命令与剩余步骤见 `docs/V0.1_IMPLEMENTATION.md`。
- 已确认失败路径：不支持版本、非 Web URL、空正文、字符数不一致、超大正文/Frame、非法 Schema 字段、Host 未安装、APP 未运行、Native timeout 均有稳定错误或测试证据；普通日志不记录正文和秘密。
- 恢复方式：合同漂移用 `scripts/sync-contracts.sh` + `pnpm check`；APP 离线打开后重试；manifest 使用实际 extension ID dry-run 后再 apply；路线失败保留合同与证据并通过 Brain CLI 记录 reversal。
- 过程讲解：任务开始与每个实施阶段已按“场景 → 角色与交接 → 工作流 → 工具协同”解释合同、framing、Application boundary、幂等、连接隔离、CSP、TCC 与失败恢复；解释跟随真实断点出现，没有把理解变成 Syc 的关闭任务门槛。
- 可选跟做：对同一 `contracts/fixtures/valid.json` 把 `version` 改成 2，观察 TypeScript 与 Swift 都拒绝；或运行 `./scripts/run-vertical-smoke.sh` 观察 stalled client 不阻塞后续 20 条。两者都不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：JSON Schema evaluator、Chromium framing、Unix socket 或 Swift MainActor 可分别另开小窗口。
- 下一步：Edge 需先获得安装授权并复用当前已验证的测试 Host 交付单元完成同一验收；Edge 通过前不把任务标为完整完成。正式稳定目录、Developer ID 签名与公证留到后续 release spike。

## 任务 009：收紧 Native Host 安装与卸载门禁

- 日期：2026-07-14
- 当前状态：工程完成（脚本边界与隔离回归完成；Edge 真实安装仍待显式授权）
- 用户场景：开发者需要把同一个 Native Host manifest 绑定到指定 Chromium 浏览器，同时能够预览、备份和人工卸载，不误写其它浏览器配置。
- 角色与交接：安装脚本接收显式浏览器选择和 Host 交付单元；路径校验器确认 executable、resource bundle 与 Schema；同目录 rename 写入步骤交出固定 basename manifest；只读卸载计划交出人工命令，不执行破坏性动作。
- 本次核心名词：显式授权、目标去重、同目录 rename 设计、只读卸载计划。
- 被现场证据修正的判断：Brave 150 当前用户级查找映射到 Chrome 目录，因此不能简单把浏览器品牌名当作目录真相；脚本现在将 Brave 与 Chrome 去重，并要求 Edge 单独显式选择。
- 自动验证：`pnpm native-host:check` 在隔离临时 `HOME` 中通过；验证 `all`/缺 browser/非法 ID/相对路径/缺 bundle/缺 Schema 拒绝、Brave→Chrome 目标、Edge dry-run、目标与路径组件 symlink 拒绝、备份候选 symlink 不跟随、资源/Schema 校验、0600 权限、唯一备份、同目录 rename 设计、失败临时文件保留及 uninstall-plan 无写入。沙盒和失败临时文件保留并打印路径，不清理临时目录。
- 安全边界：没有读取其它 Native Messaging manifest，没有真实 HOME apply，没有执行 `rm`，没有安装 Edge 或修改外部目录。
- 可选跟做：在隔离 `HOME` 下运行 `./scripts/native-host/uninstall-plan.sh --browser brave`，只观察目标存在状态和人工恢复命令；不是继续开发的前置条件。
- 下一步：验证 Edge 前先获得浏览器安装授权；浏览器存在后，按原始任务已经给出的测试 manifest 授权，先列出精确 Edge 目标、备份同名旧文件，再显式执行单浏览器 `--apply`。正式稳定目录、Developer ID 签名与公证留到后续 release spike。

## 任务 010：统一文档状态与 PRD 范围口径

- 日期：2026-07-14
- 当前状态：工程完成
- 用户场景：让读者能区分第一版产品目标、V0.1 已实现链路和后续里程碑，避免依据过期文案误判当前能力。
- 本次只解决：校准 PRD、V0.1 规格、README、学习指南、词典和依赖基线的状态与范围表述；不改代码、Project Brain 或产品范围。
- 角色与交接：PRD 定义产品目标；V0.1 规格记录当前链路；README 提供仓库入口；学习、词典与依赖文档分别统一课程、术语和版本口径。
- 本次核心名词：语言中立合同、APP 未运行恢复路径、release spike；均为项目已出现概念，本次未新增词典条目。
- 过程讲解：任务开始时已按“场景 → 角色与交接 → 工作流 → 工具协同”说明文档职责；实施前说明了合同真相源、成功/恢复路径和当前模块边界。
- 失败与恢复：若后续实现状态变化，先以代码、测试和真实验收核对当前事实，再更新对应真相源；不要把 `/tmp` 测试 Host 路径写成发布方案。
- 可选跟做：对照 `docs/PRD.md` 顶部说明与第 7 节里程碑，观察 P0 目标和 V0.1 当前实现如何分开；该动作不阻塞后续任务。
- Syc 主动提出的待解释点：无。

## 任务 011：V0.2 BYOK 实现前置规划

- 日期：2026-07-14
- 当前状态：工程完成（规划文档）
- 用户场景：在 V0.1 已能显示当前正文的基础上，把“用户自带模型连接”拆成安全、可测试、可逐步实施的本地链路。
- 本次只解决：Provider profile、Keychain secret、OpenAI-compatible streaming、RunState、错误语义、测试与后续任务拆分；不实现业务代码，不改变 V0.1 状态。
- 角色与交接：SwiftUI 交出用户意图；ModelRunOrchestrator 协调 profile、secret 与 ModelProvider；OpenAICompatibleProvider 交出 stream event；RunState 把状态交回 MainActor UI。
- 工程产物：`docs/specs/V0.2_BYOK_PLAN.md`；Architecture 入口；5 个实际进入规划的名词。
- 本次核心名词：ProviderProfile、SecretStore、ModelProvider、RunState、有界重试。
- 被当前实现修正的判断：现有 `AppViewModel` 仍直接承接 V0.1 socket 展示，尚无 Application/Provider 边界；V0.2 必须先建立 port/adapter，不能从 View 直接接 Keychain 或 URLSession。
- 安全与恢复：API Key 只进入 Keychain；写入失败不降级明文；流中断保留 partial 并标记 incomplete；取消传播到 URLSession；V0.1 Edge 未关闭时不宣称浏览器矩阵完成。
- 过程讲解：在规划开始、读取当前实现和收敛组件边界三个节点解释了配置、秘密、Provider、streaming 与 UI 的交接关系。
- 自动验证：规划完成后运行目标 `git diff`、关键词检查与 `./scripts/doctor`；结果记录在本次执行回报。
- 可选跟做：沿 `V0.2_BYOK_PLAN.md` 第 2 节数据流，从 ContentView 依次指出 Orchestrator、SecretStore、ModelProvider 与 RunState；该动作不阻塞后续开发。
- Syc 主动提出的待解释点：无。
- 可选深挖：Keychain access model、SSE 解析、Swift cancellation 或有界重试可分别另开小窗口。

## 任务 012：实现 Provider profile 与 Keychain secret boundary

- 日期：2026-07-14
- 当前状态：工程完成
- 用户场景：用户在 macOS APP 中配置单个 OpenAI-compatible Base URL、模型名和 API Key，APP 能恢复非敏感配置，但永远不回显或普通存储完整 Key。
- 本次只解决：ProviderProfile、SecretReference、profile/secret ports、UserDefaults 与 Keychain adapters、staged save、最小 SwiftUI 配置 UI 和相应测试；不实现模型请求、streaming、总结/翻译、SQLite、多 Provider 或连接测试。
- 角色与交接：ProviderSettingsView 只交出输入动作；ProviderSettingsViewModel 交给 ProviderConfigurationService；服务先把 Key 写入 SecretStore，再把 opaque reference 写入 ProviderProfileStore；UI 只接收稳定状态与固定 mask。
- 工程产物：`LinkDigestAdapters` target；Core 配置合同与 staged-save 服务；Keychain/UserDefaults adapters；SecureField 配置 UI；Core、Adapter 与 ViewModel 测试。
- 本次核心名词：ProviderProfile、SecretReference、SecretStore、staged save、secure input。
- 工程证据：`swift test` 与 `pnpm swift:test` 均通过 20 项测试；Keychain 使用随机测试 service/account 完成写入、读取、替换和删除；Swift Debug/Release 与 Xcode App/Host Debug/Release 构建全部通过；doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 失败与恢复：
  1. 第一次增量测试因先声明 test target、尚未创建测试目录而停止；补齐测试文件后恢复。
  2. XCTest autoclosure 不接受 async 调用；改为先 await 结果再断言。
  3. Swift 6 拒绝把仍在测试侧访问的 UserDefaults 实例发送给 actor；adapter 改为只接收 suite name 并在 actor 内创建实例。
  4. Keychain 写入失败映射为 `SECRET_STORE_WRITE_FAILED`，不会提交新的 profile reference；profile 保存失败会 best-effort 删除 staged secret。
- 安全边界：完整 Key 只进入 SecureField 的局部短时输入、ProviderConfigurationService 方法参数和 Keychain adapter；不进入 ProviderProfile、UserDefaults、ObservableObject、日志、safeDetail、fixture、截图、导出或 Git。
- 过程讲解：在 Core/Adapter 分层、首次编译失败和完整测试通过三个节点说明了 port/adapter、staged save 与 Swift 6 actor 隔离的职责和交接物。
- 可选跟做：打开 APP，输入一个专用测试值并保存，观察界面只显示固定 `••••••••`；该动作会写入本机 Keychain，但不是任务关闭门槛，也不要使用真实生产 Key。
- Syc 主动提出的待解释点：无。
- 可选深挖：Keychain generic password item、Swift actor isolation 或 staged save 可分别另开小窗口。
- 已知限制：profile 提交成功后删除旧 Keychain item 采用 best-effort；若系统在该时刻拒绝删除，新 profile 仍然有效，但旧 item 可能暂时成为 orphan，后续需要决定是否增加清理队列或维护入口。
- 下一步：任务 B 才实现 Chat Completions adapter、fake server 和连接测试；本任务没有调用任何模型 API。

## 任务 013：实现 OpenAI-compatible streaming adapter 与 fake server

- 日期：2026-07-14
- 当前状态：工程完成（adapter 与自动验证；设置页连接测试 UI 未纳入本轮）
- 用户场景：在不发送真实页面正文、不调用真实 Provider 的前提下，先证明 APP 能按 OpenAI-compatible Chat Completions 规则组装请求、接收流、解释失败并停止请求。
- 本次只解决：ModelProvider port、connection-test intent、stream event、稳定失败、Base URL 安全拼接、Chat Completions 请求、SSE 解码、有界重试、取消传播与 loopback fake server；不实现总结/翻译正文 UI、RunState、SQLite、多 Provider、Responses API、Ollama 或真实 Provider 测试。
- 角色与交接：未来 Orchestrator 短时交出已校验 profile、Keychain 读取的 secret 与 intent；OpenAICompatibleProvider 组装请求；URLSession 交出字节流；ChatCompletionsStreamDecoder 把 `data:` 行翻译为 delta/completed；稳定失败只把 code、retryable 和 hadOutput 交回上层。
- 工程产物：`ModelProvider.swift`、`OpenAICompatibleProvider.swift`、`ChatCompletionsStreamDecoder.swift`、Network.framework loopback fake server 与 adapter 测试。
- 本次核心名词：ModelProvider、SSE、Chat Completions、有界重试、cancellation propagation。
- 工程证据：fake server 覆盖 path prefix、重复 endpoint 拒绝、method/header/body、多 delta + `[DONE]`、401/404/413、429/5xx 三次总尝试、`Retry-After` 10 秒上限、delta 后断流、malformed、错误 Content-Type、取消与 secret hygiene；`swift test` 与 `pnpm swift:test` 均通过 28 项测试，Swift Debug/Release 与对应 pnpm 包装构建均通过，doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 失败与恢复：首次编译发现 HTTP response 的局部作用域错误，提升为单次尝试状态后同时接入 `Retry-After`；Swift 6 对 fake server 并发 closure 的捕获提出 Sendable 错误，改为锁保护的内部状态；取消测试在本次复核后改为显式取消 Provider 活动 producer task，并断言 500 ms 内退出、活动计数归零和无迟到 delta，避免依赖 TCP 对端何时感知关闭或 URLSession delegate 回调时序。
- 安全边界：完整 Key 只作为 `stream` 方法的短时参数进入 Authorization header；生产代码无日志；fake server 丢弃 header value，只记录 present/matched 布尔值；错误 description 只有稳定 code，测试运行时生成随机 sentinel，并断言 request record 与 failure 不含它。
- 过程讲解：在 port/adapter 数据流、第一次编译失败、fake server 首次全绿与取消/404/413 补强四个节点解释了职责、交接物和失效表现。
- 可选跟做：运行 `cd apps/desktop && swift test --filter OpenAICompatibleProviderTests`，观察八个 loopback 协议测试；不会访问真实 Provider，也不是后续开发的前置条件。
- Syc 主动提出的待解释点：无。
- 可选深挖：SSE line framing、URLSession cancellation、Retry-After 或 loopback fake server 可分别另开小窗口学习。
- 已知限制：连接测试 intent 已存在，但尚无 Application Orchestrator 从 SecretStore 短时取 Key，因此本轮没有让 SwiftUI ViewModel 直接接触 Keychain 或 API Key；对应 UI 应在保持该边界的后续小任务中接入。
- 下一步：任务 C 前先由 Syc/MindMux 决定是否补一个独立连接测试 UI 小任务，并继续遵守 V0.1 Edge 未关闭时不得宣称浏览器矩阵完成。

## 任务 014：实现总结/翻译 RunState、streaming UI 与取消传播

- 日期：2026-07-14
- 当前状态：工程完成（自动化与构建证据完成；未调用真实 Provider）
- 用户场景：用户已把当前网页正文送入 APP，希望点击总结或翻译后看到流式文本，并能停止、保留部分结果和理解失败状态。
- 本次只解决：`RunIntent.summarize/translate`、`RunState`、`ModelRunOrchestrator`、当前 capture prompt、SwiftUI 结果区、停止传播和 stale-run 隔离；不实现 SQLite、导出、Q&A、自动分块、多 Provider、连接测试 UI、Edge、签名或发布。
- 角色与交接：SwiftUI 只交出总结/翻译/停止意图；Orchestrator 从 `ProviderConfigurationService` 短时取得 profile 与 Key；`ModelProvider` 交回 delta/completed/failure；Orchestrator 映射为 UI-safe `RunState`；MainActor ViewModel 只接受当前 run identifier 的状态。
- 本次核心名词：RunState、ModelRunOrchestrator、cancellation propagation、stale run isolation、incomplete result。
- 技术选择：状态机与运行协调放在 Core，而不塞进 ViewModel；API Key 只作为 `loadCredentials → Orchestrator → ModelProvider.stream` 的局部短时值，RunState、ViewModel、fixture、日志和 fake request record 均不保存原文。
- Prompt 边界：总结 prompt 要求只依据捕获正文、不得编造并提示可能不完整；翻译 prompt 固定目标语言为简体中文、保留结构/名称/数字/链接；两者只加入可选标题和正文，不加入 source URL、Cookie、Header 或 Key。
- 自动验证：新增 8 项 Orchestrator 测试、3 项 AppViewModel 测试和 1 项 adapter prompt 测试；`swift test` 与 `pnpm swift:test` 共 40 项通过；Swift Debug/Release、Xcode App/Host Debug/Release 通过；doctor 为 `PASS=48 WARN=2 FAIL=0`。
- 正常与失败证据：delta 顺序累积后 completed；无 profile、secret read failure 与空正文均不会调用 Provider；无 partial 的 Provider failure 进入 failed，有 partial 则保留为 incomplete；stop 产生 stopping/stopped 并取消 fake producer；新 run 建立后旧延迟 delta 不进入最终状态。
- 被实现证据修正的判断：无需把 API Key 暴露给 AppViewModel 才能启动模型请求；共享同一个 `ProviderConfigurationService` 即可让设置保存与 Orchestrator 短时读取保持单一边界。为避免 actor reentrancy 下的 UI 覆盖，除了 Core 的 current run ID，MainActor ViewModel 也维护 visible run ID。
- 遇到的错误及恢复：本轮新增代码首次编译与测试均通过；主要风险不是语法错误，而是取消和 MainActor 交接的竞态，因此通过延迟 delta、stop 和连续新 run 三组自动测试固定恢复语义。收口时曾从 `apps/desktop` 误运行 `./scripts/doctor`，因相对路径错误失败；改用项目根运行或 `../../scripts/doctor` 后恢复，代码与 doctor 门禁本身没有失败。
- 安全边界：没有真实 API Key、Cookie、Token、私人 URL 或正文进入日志/fixture；测试只生成随机 sentinel，并只记录 Key 是否存在；没有调用真实模型 API。
- 过程讲解：在任务开始、Core/Adapter 首次编译通过、状态机测试完成和全量构建四个节点解释了 RunState、Orchestrator、取消传播、旧 run 隔离与 incomplete 的职责、交接物和失效表现。
- 可选跟做：运行 `cd apps/desktop && swift test --filter ModelRunOrchestratorTests`，观察停止与旧 run 隔离测试；该动作不访问网络，也不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：Swift actor reentrancy、AsyncThrowingStream termination 或 MainActor 状态过滤可分别另开小窗口。
- 已知限制与下一步：设置页连接测试 UI 未接入；真实 Provider 兼容抽样需要单独授权；错误恢复文案与秘密门禁随后已由任务 D 收口；Edge 未完成前不得宣称 V0.1 浏览器矩阵关闭。

## 任务 015：统一错误语义、秘密门禁并完成 V0.2 工程验收

- 日期：2026-07-14
- 当前状态：工程完成（本地 V0.2 工程链路；不表示发布完成）
- 用户场景：配置、模型和运行失败时，普通用户需要看到一致的中文原因和下一步动作；同时项目需要证明 API Key 不会随着错误、partial 或测试证据进入可见状态和仓库。
- 本次只解决：22 个 stable code 的统一文案与恢复动作、failed/incomplete/stopped 状态收口、Provider 异常回显 Key 的 redaction、独立 secret scan、V0.2 集中验收证据和文档状态；不实现 SQLite、历史、导出、连接测试 UI、多 Provider、真实 Provider、Edge 或发布能力。
- 角色与交接：Core/Adapter 交出 stable code 与 RunState；`V02ErrorCatalog` 交出固定 `message/recoveryAction`；SwiftUI 只显示这份 allowlist 文案；Orchestrator 在 delta 进入 RunState 前移除本次 Key；Swift tests 与 secret scan 反向检查整个交接。
- 本次核心名词：稳定错误、恢复动作、redaction、验收证据。
- 工程产物：统一错误目录、Orchestrator 输出 redaction、错误/状态/secret tests、`scripts/check-v02-secret-hygiene.sh`、`pnpm secret:check`、doctor 门禁与 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`。
- 工程证据：22 个 stable code 都有非空中文原因和恢复动作；unknown input 不回显 raw body/Header/URL/secret；stopped 和 incomplete 明确“不完整”；随机 sentinel 不进入 RunState、ViewModel visible text、错误文案、fake record、ProviderProfile 或 UserDefaults。Swift 46 项测试、Swift/pnpm Debug/Release、Xcode App/Host 四项均通过；secret scan 为 OK；doctor 为 `PASS=51 WARN=2 FAIL=0`。
- 失败与恢复：第一次增量测试只有一项失败，原因是旧断言要求 UI 包含内部 stable code，而新产品要求改为普通用户文案；更新为统一目录断言后恢复。未通过增加 raw detail 解决，因为那会破坏秘密边界。
- 安全边界：生产 Swift 源无普通日志调用；unknown code 不被插值；API Key 只短时进入 Authorization header，并在任何异常回显进入 RunState 前替换为固定 `[已隐藏]`；没有新增第三方依赖。
- 过程讲解：在规则读取、stable code 盘点、旧断言失败、运行时/静态门禁通过和工程证据收口五个节点解释了错误目录、恢复动作、redaction 与验收证据的职责和交接物。
- 可选跟做：运行 `pnpm secret:check`，观察只读门禁如何检查日志、observable state、fixture 和 UserDefaults adapter；不会读取 Keychain 或访问网络，也不是继续开发的门槛。
- Syc 主动提出的待解释点：无。
- 可选深挖：allowlist 错误目录、流式输出 redaction 的边界或发布前 secret incident response 可分别另开小窗口。
- 已知限制：单独测试连接 UI 留给后续小任务；真实 Provider 抽样需要单独授权；旧 Keychain orphan 清理仍需要后续维护入口；V0.1 Edge 未关闭。

## 任务 016：V0.2 收口后复核修正与下一阶段准备

- 日期：2026-07-14
- 当前状态：工程完成（复核修正；不表示产品发布完成）
- 用户场景：V0.2 本地 BYOK 链路已经收口，需要再次确认文档没有把工程完成写成产品发布，错误文案和秘密门禁没有遗漏，并为 V0.3 前的工作排出顺序。
- 本次只解决：状态口径、未知错误防回显测试、secret hygiene 规则、doctor/VERIFY 说明、集中验收证据和下一步排序；不实现 Edge、真实 Provider、连接按钮、Keychain 清理、SQLite、历史、导出、签名、公证或发布。
- 角色与交接：代码和 Swift tests 提供当前行为；`V02ErrorCatalog` 把 stable code 交成固定中文文案；`pnpm secret:check` 只交出规则名与路径；doctor 把检查结果归入 PASS/FAIL；acceptance 文档把已完成、未完成和建议顺序交给下一阶段。
- 本次核心名词：secret hygiene、sentinel、Keychain orphan；stable error 和 `Retry-After` 复用已有概念。
- 被复核证据修正的判断：README 的产品定位句容易被理解为粘贴链接、历史和导出已经可用；V0.2 plan 仍把翻译目标语言写成未决，并保留“后续不实现测试”的旧时态；当前 UI 也尚未实现真实 Provider 发送前的数据去向提示。现已修正文档，最后一项明确保留为发布/真实抽样前缺口，没有扩张成本任务。
- 错误与秘密边界：所有 22 个 stable code 继续使用 allowlist 文案；unknown 输入测试扩展到原始 code、Provider body、Header、API Key sentinel 和完整私人 URL。secret hygiene 从“禁止任何生产日志”收敛为“阻断日志中的敏感形状”，并补齐 observable/RunState、fixture/snapshot、UI code sink 与 UserDefaults 规则；命中不打印疑似值。
- 取消复核：重复运行发现原测试把“服务端后续 TCP 写入失败”当作底层取消证据，存在非确定时序；同时 Orchestrator 没有显式调用 Provider 取消入口。现已增加 `ModelProvider.cancelActiveStreams()`，OpenAI adapter 跟踪并取消活动 producer task，Orchestrator stop 先调用该入口再取消消费 Task；测试固定 500 ms 内退出、活动计数归零、无迟到 delta 和 stop 交接次数。
- 自动验证：`pnpm secret:check`、`./scripts/doctor`、Swift 46 项测试、Swift/pnpm Debug/Release build、`git status --short` 与 `git diff --check` 均在本任务结束前执行并记录；不调用真实 Provider。
- 失败与恢复：若 secret hygiene 误报，先看规则名和路径，再用明显 `sentinel-<UUID>` 复现；不得把真实值粘贴进日志或聊天。若后续实现使测试数量变化，以当次命令输出更新 acceptance，不保留过期数字。
- 过程讲解：任务开始时解释复核的场景、角色、工作流和工具协同；实施时就地说明 stable code、sentinel、secret hygiene 与 Keychain orphan 的职责、交接物和失效表现。
- 可选跟做：运行 `pnpm secret:check`，观察成功时只显示 `secret-hygiene: OK`；该动作不读取 Keychain、不访问网络，也不是下一阶段的前置条件。
- Syc 主动提出的待解释点：无。
- 建议下一步：Edge 真实验收 → 可选真实 Provider 手工抽样 → 可选测试连接按钮 → Keychain orphan 清理维护入口 → V0.3 SQLite 本地历史。

## 任务 017：迁移到 Multica 并修复干净 CI 的 WXT 类型准备

- 日期：2026-07-14
- 当前状态：工程进行中（Multica 组织迁移与首次 GitHub 推送完成；等待修复后的 CI 复核）
- 用户场景：把 Codex 本地项目迁移为可视化、可分派、可由专业 Agent 协作的 Multica 项目，并确保远程仓库能在没有本机缓存的干净环境中复现检查。
- 角色与交接：Multica Project 保存产品上下文与仓库资源；总控 Agent 拆分和分派专业 Issue；GitHub Actions 从全新 checkout 安装依赖；WXT `prepare` 在 typecheck 前生成 `.wxt` 全局类型，再交给 TypeScript 编译器。
- 本次核心名词：Project Resource、Squad Leader、Stage、clean checkout、WXT prepare。
- 被远程证据修正的判断：本机 `pnpm check` 通过是因为已有 `.wxt` 缓存；首次 GitHub CI 在干净 checkout 中找不到 `browser` 和 `defineBackground`，证明 typecheck 不能依赖本机生成目录。扩展脚本现显式在 build/typecheck/test 前运行 `wxt prepare`。
- 工程产物：私有 GitHub 基线、6 个专业 Agent、LinkDigest 产品小队、16 个历史 Issue、8 阶段未来路线、`docs/MULTICA_WORKFLOW.md` 与干净环境 WXT 类型准备。
- 安全边界：没有上传 API Key、Cookie、Token 或私人正文；所有未来功能 Issue 保持 backlog；没有安装 Edge、调用真实 Provider、购买服务、签名、公证或发布。
- 验证方式：删除 WXT 生成缓存后运行扩展 typecheck，再运行完整 `pnpm check`；通过 PR 和新的 GitHub Actions 结果确认远程干净环境。
- 过程讲解：迁移时解释了总控、专业 Agent、Squad Leader 路由、backlog/todo 和 Stage；CI 失败后解释了本机缓存为何会掩盖干净环境缺失步骤。
- 可选跟做：在 Multica 打开 `SYC-24` 查看八个 Stage，并观察所有未来任务仍在 backlog；不需要启动任务或回答问题。
