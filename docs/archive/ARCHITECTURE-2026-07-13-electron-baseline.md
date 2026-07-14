# LinkDigest 架构基线（归档）

> 归档日期：2026-07-13。本文保留 Electron + TypeScript 主干方案，**不再是当前架构真相源**。当前架构以 `docs/ARCHITECTURE.md` 为准。

> 状态：阶段 1 工程完成，过程讲解已嵌入。本文描述目标边界，不代表相应代码、云服务或容量已经实现。

## 一句话定位

LinkDigest 使用同一条 TypeScript 主干连接 Chromium 扩展、Electron 本地核心和可选云端控制面：正文、摘要和历史默认留在本机，云端只承担账号、权益、选择性同步、托管模型和运营控制。

这套设计的承诺不是“任何技术永远不换”，而是：从 10 万增长到 100 万注册用户时，不因规模本身推翻客户端、领域模型和跨端协议；只有经过测量的局部瓶颈才允许在稳定接口后替换实现。

## 1. 场景、角色与交接

### 1.1 用户场景

用户在 Chrome、Brave 或 Edge 打开一篇已经合法可见的页面，主动点击 LinkDigest。扩展取得当前页面内容，桌面 APP 在本机完成提取、BYOK 模型调用、保存和导出。用户选择注册后，才启用设备、权益、同步或托管模型能力。

### 1.2 四层角色

```text
Chromium 扩展
  职责：读取当前标签页的 URL、标题、选区和可见 DOM
  交接：版本化 CaptureEnvelope
        |
        v
Electron 本地核心
  职责：安全进程边界、提取、BYOK 模型、本地历史、导出
  存储：SQLite + OS Keychain
  交接：用户主动启用后的 Cloud API 请求
        |
        v
TypeScript 云端模块化单体
  职责：Identity / Entitlement / Sync / Managed AI /
        Usage Ledger / Remote Config
  交接：事务数据、加密对象、短期任务
        |
        v
云基础设施
  PostgreSQL：云端事实库
  对象存储：用户主动同步的加密 blob
  缓存与队列：可丢弃或可重建的临时加速层
```

### 1.3 端到端工作流

```text
用户点击扩展
   |
   v
Content Script 读取当前页面
   |
   v
Extension Service Worker 校验并发送 CaptureEnvelopeV1
   |
   v
Native Messaging Host 转交 Electron Main Process
   |
   v
本地任务核心创建 Task / ContentSnapshot / Run
   |
   +-- BYOK ----------> Provider API（Key 只在本机安全存储）
   |
   +-- 本地保存 ------> SQLite
   |
   +-- 用户主动同步 --> Cloud API v1 --> 加密对象存储
   |
   +-- 托管模型 ------> Cloud API v1 --> Queue --> Worker --> Provider
```

任何云端故障都不得阻止免登录的本地提取、BYOK 总结、历史查看和导出。

## 2. 客户端边界

### 2.1 Chromium 扩展

- 使用 WXT 组织 Manifest V3 工程，但 WXT 不是产品协议的一部分，可以替换。
- `content script` 只读取页面并生成候选内容，不直接连接 Native Messaging。
- `service worker` 负责权限、协议校验、重试和 `runtime.connectNative()`。
- P0 默认权限保持 `activeTab`、`scripting`、`storage`、`nativeMessaging`；Cookie 不是 DOM 权限，后续必须按域、主动、短时授权。
- 扩展包不执行远程托管代码，消息载荷在离开扩展前完成大小限制和运行时校验。

Chrome 官方规定 Native Messaging 只能从扩展页面或 service worker 调用，content script 必须先把消息交给它们，见 [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)。

### 2.2 Electron 进程

| 进程 | 只负责 | 不允许 |
|---|---|---|
| Main Process | 窗口生命周期、Keychain、SQLite、Native Messaging、受控系统能力 | 渲染不可信网页、承载长时间 CPU 密集任务 |
| Preload | 通过 `contextBridge` 暴露最小、具名、可校验的 IPC | 暴露整个 `ipcRenderer`、文件系统或任意命令执行 |
| Renderer | React UI、用户交互、可观察状态 | 直接访问 Node.js、Keychain、数据库或 shell |
| Utility Process / Worker | 提取、媒体处理等可崩溃或 CPU 密集任务 | 持有 UI 权限或绕过领域接口写数据库 |

生产窗口默认启用 `contextIsolation`、sandbox 和严格 CSP，关闭 renderer 的 Node.js integration；所有 IPC 同时校验 sender 和 payload。Electron 官方将这些列为安全基线，见 [Process Model](https://www.electronjs.org/docs/latest/tutorial/process-model) 与 [Security](https://www.electronjs.org/docs/latest/tutorial/security)。

### 2.3 本地领域核心

本地核心不依赖 React、Electron API 或某个模型 Provider。它只认识领域命令和端口：

```text
Domain Commands
  createTask / attachSnapshot / startRun / appendArtifact / exportTask
        |
        +-- ExtractionPort
        +-- ModelProviderPort
        +-- LocalRepositoryPort
        +-- SecretStorePort
        +-- CloudSyncPort（可选）
```

这样新增 Provider、平台提取器或同步后端时，只新增 adapter，不重写任务语义。

## 3. 云端模块化单体

### 3.1 为什么先做模块化单体

模块化单体是“一个 API/worker 代码库和部署单元，内部按业务模块隔离”。它保留单体的开发、调试和事务简单性，同时避免所有代码任意互相调用。只有真实证据表明某个模块需要独立扩缩容、故障隔离或团队所有权时，才从稳定端口后拆出服务。

Fastify 的 plugin encapsulation 可把 route、hook 和依赖限制在模块上下文中，适合这一边界，见 [Fastify Encapsulation](https://fastify.dev/docs/latest/Reference/Encapsulation/)。

### 3.2 业务模块

| 模块 | 职责 | 拥有的数据 | 禁止直接依赖 |
|---|---|---|---|
| Identity | 用户、会话、设备与身份提供商映射 | User、Device、Session | Sync blob、模型 Provider |
| Entitlement | 套餐、功能开关、额度判断 | Entitlement、Plan | 原文与摘要 |
| Sync | manifest、冲突版本、加密 blob 引用 | SyncManifest、EncryptedBlob metadata | 解密用户正文 |
| Managed AI | 托管任务接收、调度、结果状态 | ManagedJob | 直接修改权益余额 |
| Usage Ledger | 只追加的额度预留、消费、退款流水 | UsageLedger | 用户正文 |
| Remote Config | 最低版本、灰度开关、平台适配器状态 | ConfigSnapshot | 用户私有数据 |

模块通过 application service 或明确事件交接，route handler 只完成鉴权、输入校验、调用 use case 和映射响应，不写业务规则。

### 3.3 API 与 worker

- API 和 worker 使用同一 TypeScript 代码库、同一领域模块、不同进程入口。
- API 是无状态实例，可横向增加；持久状态只进入 PostgreSQL 或对象存储。
- 写请求携带 `idempotencyKey`；重复提交返回同一业务结果，不重复创建任务或扣减额度。
- 跨模块异步动作使用 transactional outbox：业务事务和待发布事件一起提交，worker 再安全投递。
- 队列只负责调度，PostgreSQL 中的 job/ledger 状态才是可恢复事实。

## 4. 数据所有权与隐私

| 数据 | 默认位置 | 是否上云 | 云端可见性 |
|---|---|---|---|
| API Key / Provider secret | OS Keychain | 否 | 不可见 |
| 原始正文、摘要、翻译 | SQLite | 用户逐项或规则主动选择 | 端到端加密 blob，服务端不解密 |
| 本地任务和运行历史 | SQLite | 默认不同步完整内容 | 只同步必要索引或加密 blob 引用 |
| 账号、设备、权益 | PostgreSQL | 注册后必须 | 服务端可见最小字段 |
| 用量与计费流水 | PostgreSQL | 使用托管能力时 | 不包含正文、Key 或 Cookie |
| 遥测 | 本地优先；用户同意后上报 | 可选 | 不包含正文、私人 URL 或秘密 |

### 4.1 同步原则

- 设置和同步索引可以进入云端；原文和结果默认不上传。
- 用户主动开启内容同步后，客户端先加密再上传；服务端只处理 ciphertext、版本和大小。
- 不自创加密算法。正式实现前必须单独完成威胁模型、密钥恢复与经过审计的库选择。
- 删除账号时删除云端身份、权益和可识别元数据，并进入有时限的对象删除队列；本地数据由用户独立控制。

### 4.2 BYOK 与托管模型

```text
BYOK：Desktop Main -> 用户 Provider
      云端不经过、不计费、不记录 prompt

托管：Desktop -> Cloud API -> Entitlement reserve
                    -> Queue -> Worker -> Provider
                    -> Usage Ledger settle/refund
```

托管任务必须有明确的内容发送确认、保留期限、取消与退款语义。模型不可用时，本地已保存内容仍可导出或切换到 BYOK。

## 5. 稳定协议

### 5.1 通用消息头

所有跨扩展、进程和网络边界的消息都包含：

```ts
type MessageMeta = {
  version: number;
  requestId: string;
  createdAt: string;
  idempotencyKey?: string;
};
```

`requestId` 用于追踪一次交接，`idempotencyKey` 用于保护写请求重试。日志可以记录二者，但不得记录正文、Key、Cookie 或完整私人 URL。

### 5.2 本地链路模型

| 模型 | 稳定语义 |
|---|---|
| `CaptureEnvelopeV1` | 扩展交给桌面的页面来源、标题、选区、清理后正文和捕获证据 |
| `Task` | 用户想完成的一次工作，不等同于某次模型调用 |
| `ContentSnapshot` | 某个时间、账号可见状态和提取路径下的正文快照 |
| `Run` | 一次提取、总结、翻译或导出的执行与状态变化 |
| `Artifact` | 某次 Run 生成的可保存、比较、复制或导出的结果 |
| `AppError` | `category / code / retryable / action / safeDetail` 的可解释失败 |

### 5.3 云端链路模型

| 模型 | 稳定语义 |
|---|---|
| `User` | 最小账号主体，不承载业务内容 |
| `Device` | 已登记设备、平台、版本与撤销状态 |
| `Entitlement` | 某用户当前可使用的功能和额度快照 |
| `SyncManifest` | 本地项目与加密 blob 的版本、冲突和删除标记 |
| `EncryptedBlob` | 对象存储引用、加密版本、校验和与大小，不包含明文 |
| `UsageLedger` | 托管能力的预留、结算、退款和人工调整流水，只追加不覆盖 |

协议变更规则：兼容字段只新增为可选；破坏性变化发布新 major version；客户端遇到未知新字段应宽容读取，遇到不支持的 major version 必须给出升级或降级操作。

## 6. 数据库与迁移

- SQLite 与 PostgreSQL 共享领域含义，不共享物理表、索引或 ORM entity。
- 每个数据库都有按顺序执行、可重复检测、只向前的 migration history。
- 发布前验证“旧版本数据库 -> 新版本应用”的升级，不允许通过删除数据库解决迁移失败。
- PostgreSQL 是账号、权益、同步元数据和 ledger 的唯一事实库。
- Redis-compatible cache、队列和对象存储不得保存唯一业务事实；清空后系统必须能从事实库恢复或重新计算。
- 大表分区、读副本和模块拆服务都由 `docs/CAPACITY_MODEL.md` 的测量触发，不因想象中的百万用户提前启用。

## 7. 扩容而不重写

```text
阶段 A：单机开发
  Electron + SQLite；Cloud API/worker 本地单进程

阶段 B：公开测试
  1 个 PostgreSQL；API/worker 分进程；对象存储；基础遥测

阶段 C：10 万注册准备度
  多 API/worker replica；连接池；队列；备份恢复；限流

阶段 D：100 万注册准备度
  自动扩缩容；读路径缓存；归档/分区评估；多区域读取评估
```

允许拆服务的信号必须至少满足一项：

1. 单模块资源曲线与其它模块明显不同，需要独立扩缩容。
2. 单模块故障频繁影响其它核心能力，需要故障隔离。
3. 单体部署时间或团队所有权已经成为有数据的交付瓶颈。
4. 经过 profiling 后，TypeScript/Node 的某个隔离热路径无法达到 SLO。

拆分时保留原有 API/event contract；没有上述证据，不创建微服务。

## 8. 可观测性与安全门禁

- 服务端从第一条 API 开始产生结构化日志、request trace 和核心 metrics。
- Node 端采用 OpenTelemetry API；官方当前将 traces 与 metrics 标记为 stable，logs 仍为 development，见 [OpenTelemetry JavaScript](https://opentelemetry.io/docs/languages/js/)。
- 客户端遥测必须脱敏、可关闭，不上传正文或秘密；云端日志使用 allowlist 字段。
- 关键指标：请求延迟、错误率、活跃连接、数据库连接、慢查询、队列年龄、任务成功率、托管模型成本。
- CI 必须包含类型检查、单元测试、契约兼容检查、迁移测试、secret scan 和依赖许可证检查。
- 商业闭源产品默认只接受许可证边界清晰的依赖；GPL、AGPL 和非商业许可证需要单独评估和 Syc 确认。

## 9. 推荐技术与可替换边界

| 区域 | 推荐默认 | 可以替换 | 不可改变的边界 |
|---|---|---|---|
| Desktop | Electron + React + TypeScript | 若发布验证出现明确阻塞，可评估 Tauri | renderer 无 Node 权限；本地领域核心与 UI 分离 |
| Extension | WXT + MV3 | 原生 MV3 工程 | content script / service worker / Native Messaging 分工和协议不变 |
| Local data | SQLite + OS Keychain | SQLite binding 可按打包验证替换 | 秘密不进数据库；迁移只向前 |
| Cloud API | Fastify + TypeScript modular monolith | 其它支持严格模块边界的 Node framework | route 与 domain 分离；API 版本化；无状态横向扩展 |
| Cloud truth | PostgreSQL | 托管厂商可换 | 领域数据语义和 migration history 不变 |
| Async | queue adapter + worker | 托管队列或 Redis-compatible 实现 | 幂等、outbox、可恢复状态不变 |
| Telemetry | OpenTelemetry | 后端观测厂商可换 | trace/metric 语义与隐私边界不变 |

## 10. 已知未知项

- Electron + SQLite binding 在签名、公证、自动更新和 Native Messaging 安装下的最终组合尚未做 release spike。
- 全球账号的首个身份提供商尚未选择；架构只固定 OIDC-compatible adapter 和本地免登录边界。
- 端到端加密算法库、恢复密钥体验与多设备撤销需要独立安全设计，不在本阶段假装已经解决。
- 多区域部署只保留数据归属和接口边界；没有真实地域延迟与合规需求前不实施 active-active。
- 100 万注册是容量验证目标，不代表已有注册、流量、服务器或成本证据。

## 11. 架构检查与可选跟做

### 自动检查

- 文档包含本地、云端、数据和协议四类边界。
- 容量指标与扩容触发条件只在 `docs/CAPACITY_MODEL.md` 维护，本文通过链接引用。
- 已由 Syc 确认的架构决策通过 Brain CLI 固化；后续发生反转时追加 reversal，不以学习作业作为写回门槛。

### 过程讲解重点与可选跟做

开发过程中应围绕下面三条路径解释每一步由谁负责；Syc 想亲手跟做时可任选一条，不阻塞后续工作：

1. 当前 Chrome 页面如何进入桌面 APP 并保存到 SQLite。
2. BYOK 为什么不经过 LinkDigest 云端。
3. 用户主动同步一篇原文时，云端为什么只能看到加密 blob。

“云端挂了仍可使用哪些功能”和“什么时候才允许拆微服务”是本阶段提供到 L3 的共同观察点，不要求 Syc 额外提交答案。
