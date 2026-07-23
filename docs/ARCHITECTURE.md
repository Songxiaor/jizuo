# LinkDigest 架构基线

> 状态：V0.1–V0.4 本地工程链已按各自证据收口；视频路线 M0–M3 已完成各自范围内的本地工程实现和自动验证。M2 交付当前捕获的远程速览、明确降级与用户主动收藏；M3 交付 directFile 按需临时媒体与 Apple 本机转写的可测试 Debug 链，但真实三条中文样本、断网、GUI、HLS 转写和日用部署仍未完成。M4–M6 未进入。Loop 4 r1/r2/r3/r4a 已最终独立工程复审 PASS。Chrome/Edge manifest 为 malformed，unsigned App/DMG 仅完成工程绑定，产品继续 BLOCKED。

## 1. 一句话定位

LinkDigest 用 SwiftUI 构建 macOS 原生桌面 APP，用 TypeScript/WXT 构建 Chromium 扩展；两端不共享语言源码，而是通过版本化 JSON 与 Native Messaging 交接。P0 的提取、BYOK、历史和导出全部 local-first，不依赖 LinkDigest 云端。

## 2. 场景、角色与交接

```text
Chromium Extension（TypeScript/WXT）
  职责：读取用户主动触发的当前页面 DOM/选区
  交接：纯文本 CaptureEnvelopeV1 / 已分类视频 CaptureEnvelopeV2 JSON
        |
        v Native Messaging
macOS Native Host / App Boundary（Swift）
  职责：framing、版本校验、大小限制、唤起与错误映射
  交接：已验证的 Swift 领域对象
        |
        v
macOS Local Core（Swift）
  职责：任务编排、提取、BYOK、SQLite、Keychain、导出
  交接：可观察状态和领域结果
        |
        v
SwiftUI + 少量 AppKit
  职责：任务列表、原文、结果、执行记录和系统交互
```

### 2.1 为什么采用双语言

- Chromium 扩展的权限、service worker、content script 和商店工具链天然适合 TypeScript。
- 第一版只做 macOS，原生窗口、菜单、快捷键、材质、焦点和可访问性是产品质量的一部分。
- Swift 与 TypeScript 通过语言中立协议隔离，避免为了“共享类型”把整个桌面 APP 绑定到 Web Runtime。
- Windows 若进入后续阶段，复用产品协议与行为规范，不承诺复用 macOS UI 源码。

## 3. P0 组件边界

### 3.1 Chromium 扩展

| 组件 | 负责 | 不负责 |
|---|---|---|
| Content Script | 读取当前 DOM、选区和页面元数据 | Native Messaging、数据库、模型调用 |
| Service Worker | 权限、载荷校验、Native Messaging、超时 | 渲染完整历史和复杂设置 |
| Popup | 捕获范围、动作、字符数和连接状态 | 长期任务状态、导出、Key 管理 |

P0 默认权限：

- `activeTab`
- `scripting`
- `storage`
- `nativeMessaging`

不申请 Cookie、浏览器历史或全站静默访问。受限页面只显示明确说明，不尝试绕过。

### 3.2 Native Messaging 边界

Native Messaging 是首要 release spike，必须单独验证：

- Chrome/Brave/Edge Host manifest 的安装和卸载。
- APP 已运行、未运行、升级中三种状态。
- 长度前缀 framing、消息上限和超时。
- Host 与 APP 的签名、公证和路径稳定性。
- 扩展/APP 版本不一致时的恢复文案。

独立 `LinkDigestNativeHost` executable 处理 Chromium 4-byte little-endian framing、4 MiB 上限、默认约 20 秒超时（含冷启动预算）和合同校验，再通过用户私有 `/tmp/linkdigest-<uid>.sock` Unix domain socket 交给桌面 APP。APP 未在监听时，Host 仅打开**同包** `LinkDigest.app`（或 `LINKDIGEST_APP_BUNDLE_PATH` 覆盖，测试用），轮询 socket 就绪后重试转发；仍失败才返回 `APP_UNAVAILABLE`。Host 不承载提取、模型或数据库业务。

Loop 4 r1 将 `config/native-host.json` 作为 Host 版本/名称/协议/架构/entrypoint/resource bundle 的 canonical config。`scripts/build-release.sh` 只向显式绝对且不存在的输出根组装 `Host + LinkDigest_LinkDigestCore.bundle + package.json + SHA256SUMS`；verifier 拒绝 symlink/FIFO/socket/额外顶层项、权限和 checksum 漂移、缺 bundle/Schema、根合同漂移、metadata 不一致与非 `arm64` Mach-O。manifest renderer 只生成精确、排序去重的 origins；release extension IDs 未冻结时 fail closed。

clean-room initial installer 没有 real-HOME/uninstall 模式：session/home 必须在 fixed canonical `/private/tmp` 内、带 sentinel 的 canonical 专属 root，不读取 `TMPDIR`，并从 `/` 到 version/manifest/receipt 的现存祖先逐级拒绝 symlink。Host smoke 同样固定 `/private/tmp`，packaged smoke 只接受先通过 verifier 的 package root，禁止 raw executable/skip-build/socket override。安装交付物以版本目录、Chrome/Brave 共享或 Edge 默认/隔离 manifest、非敏感 `receipt-v1.json` 交接；同 hash 二次 apply 是不改 mtime 的 noop，未知目标拒绝。r1 cleanup 不是完整 rollback；其冻结合同见 `docs/specs/P0_RC_LOOP_4_STABLE_HOST.md`。

r2 在 r1 package verifier 之后新增独立 transaction layer。clean-room session 必须预置精确 sentinel 和永久 `.transaction.lock`；事务 wrapper 从不创建、替换或删除锁。`plan` 只读生成 canonical plan/`planDigest`，`apply` 获取非阻塞排他 `flock` 后重算相同计划，再写 durable journal。所有文件 mutation 锚定已验证的 session dirfd，关键点复核 session device/inode；receipt、manifest、version tree、backup 和 journal 都执行 owner/type/link-count/mode/hash 或完整 inventory 验证。

首次独立 review 发现三项 P1，当前修复合同为：Edge profile、manifest target、transaction `install_rel` 与 verified `packageRoot` 之间任何父子方向重叠都在 plan/journal validation 阶段拒绝；r1 `stable_host.verify_package` 默认仍只接受 config 的 canonical `0.1.0`，只有 transaction 先从 metadata 读取安全 SemVer，再作为显式 `expected_product_version` 传入；journal 的 plan、before/after receipt、tree/manifest records、phase、action/operation 关系与 payload coverage 全部执行 strict schema，malformed journal 统一映射为 `RECOVERY_REQUIRED` exit 8，不再落到内部错误 70。

`receipt-v2.json` 把 `current`、严格 SemVer 顺序的 `lineage` 与 `ownedManifests` 作为 ownership 真相；升级把旧 current 留在 lineage，r2 不做旧版本 GC。journal 记录 prepared、backup/publish、receipt commit 与 terminal phase；live receipt 是唯一 commit point：commit 前 recover 回滚，commit 后 recover 向前收尾。initial install、v1 migration、manifest reconcile、严格升级、uninstall、noop 与 recover 共用这套边界。checksum/package digest 只用于一致性与漂移检测，不是签名、来源认证或发布真实性。完整合同、退出码、barriers、STOP 条件、首次 86 项历史证据与当前 110 项修复证据见 `docs/specs/P0_RC_LOOP_4_R2_TRANSACTIONS.md`。

r2 clean-room PASS 不宣称对同 UID 恶意进程、断电、内核/文件系统故障或所有崩溃窗口提供形式化证明；也没有真实 `$HOME`、真实 browser profile、签名、公证或发布授权。发现多个 active journals、ownership/anchor/commit state 无法精确解释时 fail closed 并保留现场，而不是猜测清理。

### 3.2.1 Browser Support Installer（Loop 8）

Loop 8 把“浏览器支持”放在 App 的独立 Settings tab，但没有把旧的 `/private/tmp` clean-room Python installer 放宽成真实 HOME 安装器。两者职责不同：旧脚本继续只证明候选装箱的隔离事务；Swift `BrowserSupportInstaller` 是产品动作的最小文件系统适配器。它只在 Syc 从 App 明确点击安装、修复、卸载或恢复时，才由 composition root 注入当前用户 HOME；工程测试永远显式注入唯一的 `/private/tmp/.../isolated-home`，不通过修改进程 `HOME` 模拟，也不读取或写入真实 `~/Library`、浏览器 profile 或系统设置。

```text
Settings「浏览器支持」
  ↓ 用户明确动作 / 未知或漂移先确认
BrowserSupportViewModel（MainActor 入口门禁）
  ↓ browser + confirmation
BrowserSupportInstaller（串行文件事务）
  ↓ 模板 SHA / rendered manifest SHA / Host package digest / receipt
当前用户的 LinkDigest receipt + 已存在的 NativeMessagingHosts leaf
  ↓
Chrome/Brave shared default target，或 Edge 独立 default target
```

- Chrome 与 Brave 保留两个 UI 行，但 macOS active target 都是 `Google/Chrome/NativeMessagingHosts`，并且只使用一个 `chrome` receipt entry、backup 与状态；任一行的 install/repair/uninstall/restore 都会同步另一个行。Edge 继续独立使用 `Microsoft Edge/NativeMessagingHosts`。`brave` receipt key 和 `BraveSoftware/Brave-Browser` leaf 仅为旧 journal/receipt 的 decode/recovery 保留：它们不会把当前 Chrome/Brave 行显示为已安装，也不会被新动作静默删除或覆盖。目标目录不存在时只显示“未检测到浏览器”，**绝不创建**目录猜测安装位置。此映射已同步到 App、dev scripts 与 r3 preflight；r2 transaction 和 r4 release-unit/local-test probe 仍是 legacy independent-Brave 合同，不能被视为 shared active mapping 的 release evidence，下一次 candidate freeze 前必须版本化迁移。
- App 运行时只接受 `LinkDigestCore` resource bundle 中的三份模板。`manifest-integrity.json` 的 extension ID、Host name、version 与三个 SHA-256 必须逐项匹配 Loop 7 的 `identity-artifact`；装箱/gate 再逐字节比对 App bundle 副本、source archive 与 handoff 模板。模板只允许那个固定 extension origin，并且 Host 路径在写入前才替换为 App 已封装的 Native Host executable。
- 首装、修复、卸载与恢复使用 receipt 目录内唯一的 durable `operation-v1.json`。journal 只发布一次，保存 action、target、before/after receipt 原始字节、before/after manifest 与精确 backup/quarantine hash；live receipt 是唯一 commit point：等于 before 则回滚 manifest，等于 after 则向前清理，第三种组合保留现场并 fail closed。启动、inspect 和下一次 mutation 都先执行 recovery；因此正常进程终止不会留下“receipt 有 entry 但 manifest 缺失”的永久无操作状态。
- manifest、receipt 与 journal 发布都先同步临时文件，再在 link/rename/unlink 后 `fsync` 父目录。对 browser manifest 的替换/删除不在 live basename 上 compare-then-mutate：旧 leaf 先通过 `renameatx_np(RENAME_EXCL)` 原子移到唯一 quarantine，移动后才校验；新 manifest 只用 no-overwrite publish。并发出现的 B 不会被覆盖或删除，无法精确解释时保留 quarantine/journal 并停止。
- receipt 记录 rendered manifest SHA-256、Host executable SHA-256、完整 Native Host package/resource tree digest 与版本。重复安装只有这些绑定和文件内容全部一致才是 no-op；Host、资源、模板、receipt 或文件内容任一不一致都显示“漂移”。
- 同名 manifest 没有可验证 receipt 时是“未知”，不会静默覆盖；用户确认后才生成时间戳备份再接管。receipt 同时绑定这一次 backup 的精确 basename 与 SHA-256；恢复只接受名称和哈希都匹配的那一份，绝不按前缀/时间猜选。修复同样要求确认并备份。恢复仍要求当前 manifest 经 receipt 证明属于 LinkDigest，防止“恢复”变成覆盖第三方文件。
- 卸载只在 receipt、当前 manifest 和当前 frozen render 三者一致时删除自有 leaf/receipt entry；漂移或未知状态直接拒绝。失败注入后的测试只接受完整旧态或完整新态，且会检查隔离 HOME 之外的 fixture digest 不变。

这仍不是签名、公证、浏览器扩展安装器或真实 profile 兼容性的发布承诺。Loop 8 的自动证据证明的是已覆盖的 current-user 文件所有权与隔离 HOME 事务；Syc 的真实 HOME 产品安装留给最终人工总检。

### 3.3 macOS APP

```text
App Shell
  SwiftUI App lifecycle / Window / Menu / Settings

Presentation
  Views / View State / Navigation

Application
  Task Orchestrator / Commands / Cancellation

Domain
  Task / ContentSnapshot / Run / Artifact / AppError

Ports
  HistoryRepository / ModelProvider / SecretStore / Exporter

Adapters
  Native Messaging / Network.framework (manual fetch) / URLSession (model) / SQLite / Keychain / File Export
```

边界规则：

- SwiftUI View 不直接访问 SQLite、Keychain、文件系统或模型端点。
- Application 层不依赖具体 SwiftUI View。
- Domain 不依赖浏览器、SQLite binding 或某个模型 Provider。
- Adapter 将平台错误映射成稳定 `AppError`。
- AppKit 只通过小型 adapter/representable 局部使用，不创建第二套 UI 架构。

## 4. 状态与并发

P0 使用 Swift Concurrency：

- UI 状态在 MainActor 更新。
- 页面接收、数据库、导出和模型流在受控异步任务中运行。
- 每个 `Run` 持有可取消任务；停止操作必须向 URLSession/stream 传播取消。
- 不允许 detached task 绕过任务生命周期写数据库。
- 流式结果先属于运行中的 `Run`，完成或中断后再形成 `Artifact`。

状态管理优先使用 Observation/`@Observable` 或等价原生机制；只有明确需要 Publisher 组合时才引入 Combine。

## 5. 稳定协议

### 5.1 协议唯一来源

Swift 与 TypeScript 无法直接共享类型。进入 V0.1 实施前必须确定一种语言中立合同来源：

1. 推荐：受版本控制的 JSON Schema，生成或验证两端模型。
2. 可接受：手写 schema + 同一组跨语言 JSON fixtures。
3. 不接受：只把 TypeScript interface 当成跨语言真相源。

`contracts/capture-envelope-v1.schema.json` 与独立的 `contracts/capture-envelope-v2.schema.json` 是当前跨语言合同真相源。V1 的 schema、fixtures、`capture:v1` namespace、golden fingerprint 与 NativeResponse v1 ACK 冻结兼容；V2 保留 `source/capture/evidence` 并要求 `MediaDescriptor`。扩展构建时由 Ajv 2020 为 V1/V2 判别联合生成静态校验函数，运行时不使用 Manifest V3 CSP 禁止的 `eval` / `new Function`；Swift 按 `version` 选择对应 bundled schema。两端共同读取同一 fixture manifest；`scripts/check-contract-sync.sh` 防止 Swift resource 副本漂移，`generate-contract-validator.mjs --check` 防止扩展静态校验器漂移。

M1 的 `MediaDescriptor` 将媒体分为 `directFile/hls/embed/browserSessionOnly/unsupported`；本阶段检测器不会生成 `embed`。`directFile/hls` 必须携带 HTTPS `ephemeralPlaybackURL` 且不得带失败原因；`browserSessionOnly/unsupported` 必须带稳定失败原因且禁止播放 URL。blob/MSE 固定为 `browserSessionOnly + blob_or_mse`。多视频依次使用 playing、当前可证明的交互焦点、可见交集面积、视口中心距离；完全并列返回 `multiple_candidates`，绝不按 DOM 顺序猜测。

M2 只在 History 详情仍指向 `CurrentCapture.taskID`、且还没有本地 `MediaAsset` 时投影“视频速览”卡。`directFile/hls` 从内存 `ephemeralPlaybackURL` 创建远程 `AVPlayer`；播放器立即以 16:9 占位出现，同时异步读取首条 video track 的 `naturalSize + preferredTransform`，随后用 `VideoDisplayGeometry` 保持真实横竖比例、最大高度 520、不裁切。descriptor/捕获切换、详情离开、卡片消失或本地收藏出现时均执行 pause、移除 current item 并释放 player。`expiresAt` 已过期或格式不可确认时不创建 player；运行失败只显示固定重试/重新发送动作，错误状态不携带播放 URL。

`browserSessionOnly/unsupported/embed` 只渲染原因和返回浏览器动作，不创建 `AVPlayer`、`WKWebView` 或其它远程执行环境。blob/MSE、DRM、多视频歧义、未加载、会话依赖与不支持格式都有稳定中文映射。收藏资格只给 `directFile`：用户明确点击后，`HistoryViewModel` 才把 descriptor 短时映射为 `CaptureMedia`，复用 `VideoMediaDownloader → LocalMediaStore → HistoryApplicationService.attachMedia`；成功后刷新详情并由既有本地 `HistoryVideoPlayerCard` 接管。HLS 本轮明确不保存。V2 接收仍因 `CapturedDocument.media == nil` 不触发旧自动下载；临时 URL 继续不进入 fingerprint、SQLite/WAL/SHM、export、error 或 `media_assets`。

M3 给当前 V2 `directFile` 增加独立的按需本机转写，不把临时媒体伪装成收藏：只有用户点击“本机转写”后，SQLite 先在 `task_transcription_attempts` 分配 task-wide generation；成功取得 owner 后，`TranscriptionTempStore` 才通过既有 `SafeResourceFetching` 安全通道把媒体写入 `Application Support/LinkDigest/TranscriptionTemp/<attempt UUID>/media.mp4|mov`。它沿用 HTTPS、SSRF、逐跳 redirect、120 秒、200MB、容器 magic 与磁盘余量门，并在 descriptor 已知时长或 AVAsset 落地核验超过 120 分钟时拒绝。播放和首帧探测不调用该 store；HLS 显示“当前 Debug 暂不支持 HLS 转写”。

临时文件只交给现有 `AppleSpeechVideoTranscriber`，partial 只停留在 `HistoryViewModel`。成功、识别失败、空转写、取消、模型不可用/安装失败和 History 切换都清除当前 attempt 目录；App 启动清理上次崩溃残留，正常退出通过 `NSApplication.willTerminateNotification` 再清理。删除失败保留明确 UI 状态与“重试清理”，不会进入 `media_assets`、导出或“另存一份”。

Migration006 只追加 `task_transcription_attempts` 与 `task_transcription_evidence`，两表没有 URL 或文件路径列。M0 durable-media attempt 与 M3 transient attempt 共用每个 Task 的单调 generation；任何较旧 owner 的 running/failure/completion 都是 no-op。最终提交在一个 GRDB 事务中插入或复用正文 hash 相同的 snapshot、追加 engine/provider/model/locale/language/time 证据、把 attempt 标为 `completed` 并更新时间；事务失败全部回滚。详情、搜索列表、总结/翻译入口和 Markdown/TXT/JSON 导出通过两类 evidence 的合并 generation 选择 effective latest final，volatile partial 永不参与。

### 5.2 消息头

所有跨浏览器与 APP 边界的消息包含：

```ts
type MessageMeta = {
  version: number;
  requestId: string;
  createdAt: string;
  idempotencyKey?: string;
};
```

兼容规则：

- 兼容字段只能新增为可选。
- 破坏性变化发布新 major version。
- 未知可选字段宽容读取。
- 不支持的 major version 必须拒绝并给出升级动作。
- 重复 `requestId/idempotencyKey` 不得重复创建任务。

### 5.3 P0 领域模型

| 模型 | 含义 |
|---|---|
| `CaptureEnvelopeV1` | 浏览器交给 APP 的来源、正文和捕获证据 |
| `CaptureEnvelopeV2` | V1 页面事实加一个经过能力分类的 `MediaDescriptor` |
| `MediaDescriptor` | 当前会话媒体种类、能力、选择证据与安全降级原因；不是永久媒体资产 |
| `Task` | 用户想完成的一次链接理解工作 |
| `ContentSnapshot` | 某个时间和捕获路径下的正文快照 |
| `Run` | 一次总结或翻译模型执行；提取由 Capture/Snapshot 表达，导出不创建 Run |
| `Artifact` | 可保存、复制或导出的结果 |
| `AppError` | 稳定错误类别、代码与恢复动作 |

云端 `User/Device/Entitlement/SyncManifest/UsageLedger` 不进入 P0 合同实现。

## 6. 本地数据

### 6.1 SQLite

02A 已实现 `HistoryRepository` Port 与 `GRDBHistoryRepository` Adapter；02B 的 `AppComposition` 在生产 Application Support 的 `LinkDigest/history.sqlite` 创建唯一 Repository/Service，完成 access mode 与 interrupted recovery 后才启动 socket server。浏览器 `CaptureReceiver` 按版本解码并验证 V1/V2 后，直接调用 `CaptureIngestService.ingest(envelope:)` 的两个 typed overload；local/manual document 只走独立 document overload，旧的 document + 两个 optional wire 混装入口已删除。V1/V2 overload 在 App 边界再次用各自完整 schema 与 semantic rules 验证，然后才构造 `AcceptCaptureCommand`；local/document factory 明确拒绝 `.browserCapture`，因此 `CapturedDocument(wire:)` 不能改挂 `manual:v1`。

`AcceptCaptureCommand` 把已验证输入降维并闭合为 `CapturedDocument + CaptureDeliveryProvenance + receivedAt`：provenance 只暴露不可变的 delivery key、合同版本与不可逆 semantic SHA-256，不能由裸 `captureContractVersion`、`CapturedDocument.wireVersion` 或 public memberwise initializer 拼出矛盾组合。`HistoryApplicationService` 只接受 closed command，不再暴露 V1/V2 envelope 或 document overload，所以完整 `MediaDescriptor` 不跨过该边界。`GRDBHistoryRepository` 只消费 provenance；它不会持有或重新推断 wire envelope / descriptor，但会防御性核对 digest 形状以及 document origin、key namespace、contract version、request/idempotency suffix 的一致性，不一致统一映射为 `invalidInput`。

V1 继续使用冻结的 `capture:v1:*` key、V1 length-prefixed digest 与 golden；local/manual document 继续使用 `manual:v1:*`。V1 与 V2 command factory 对 wrong version、schema-invalid field 和 semantic-rule violation 对称 fail closed。V2 使用 `capture:v2:*`，生产 safe digest 的冻结字段顺序是：namespace/version → createdAt → source kind/url/title/platform → capture method/text/count/completeness/capturedAt → evidence sourceLabel/usedCookie → media kind/pageURL/canonicalURL/platform/mimeType/posterURL/durationSeconds/author/transcriptionCapability/failureReason/candidateCount/selectionReason/playbackState。`requestId`、`idempotencyKey`、`ephemeralPlaybackURL` 与 `expiresAt` 明确排除。包括 `posterURL` 在内的安全媒体原值只在摘要计算栈中短暂出现；Repository、SQLite/WAL/SHM、日志、导出和 `media_assets` 只可能看到最终 digest，不会收到原始 descriptor。13 个安全媒体字段的摘要回归全部使用 schema-valid before/after envelope；direct/hls 始终带 HTTPS URL 且无 failureReason，browserSessionOnly/unsupported 始终无 URL 且带 failureReason。

V2 只有页面正文与非敏感页面事实进入 History；`MediaDescriptor` 仅随 `CurrentCapture` 留在 commit 后的当前进程内存，`CapturedDocument.media` 始终为 `nil`，因此不会触发旧永久下载、`media_assets`、播放或 ASR 接缝。浏览器与手动链接仍由 `CaptureIngestService` 保证 storage commit 后才发布 CurrentCapture 和 ACK。Migration005 已追加并只把 `capture_deliveries.capture_contract_version` 的约束从 V1 扩为 `{1,2}`；Migration001–004 字节保持冻结，Repository 已按 provenance 写入准确版本与摘要。future schema 继续 fail closed 为只读。

SQLite 保存：

- Task
- ContentSnapshot
- Run
- Artifact
- 非敏感 ProviderProfile
- migration history

GRDB 7.11.1 exact 已通过许可证、SwiftPM Debug/Release、事务、migration、并发、备份与只读恢复门禁。migration 001 的 `Task → ContentSnapshot → Run → Artifact` 与 `capture_deliveries` 已通过独立复审并冻结，02B/02C/Loop 2 均未修改其字节；未来 schema 变化只能追加 002+。future schema 以只读模式打开并保留列表、详情与导出，UI 说明原因、数据未修改和升级恢复动作；签名与公证仍属后续门禁。

### 6.2 Keychain

API Key 使用 Keychain 保存，SQLite 只记录不可逆推出秘密的引用。Keychain 写入失败时禁止降级为明文文件或 UserDefaults。

### 6.3 文件导出

导出由用户选择位置。Loop 2 的 Core renderer 只接收脱敏 `HistoryExportProjection(formatVersion: 1)`，生成确定性的 Markdown、UTF-8 `.txt` 与 pretty-printed/sorted-key JSON；JSON 可以 decode 回安全 projection，且不编码 provider 配置、idempotency、cookie-use 标记、secret reference、raw error 或本机路径。renderer 不接触文件系统；SwiftUI 的 FileDocument/fileExporter 留在 UI 层，取消不报错，同名覆盖由 macOS 面板处理，保存失败显示检查目录权限的固定恢复动作。只读/future-schema 历史同样可导出，不改数据库。

## 7. BYOK 模型路径

> 手动公开链接的 production fetch 不再是单一路径：普通公网继续使用 peer-bound numeric transport；显式系统 HTTP(S) 代理或全 fake-ip DNS 使用 HTTPS-only 的系统代理 transport。后者保持 hostname 的 CONNECT/TLS system-trust 校验，但不拥有 numeric peer binding，必须作为独立代理/VPN 信任边界看待，不能宣称同等 SSRF 防护。`URLSessionWebPageFetcher` 仅为 test-only legacy。

```text
SwiftUI Action
  → Task Orchestrator
  → ProviderProfile + Keychain secret
  → URLSession streaming request
  → Provider Adapter
  → Run progress
  → Artifact
  → SQLite / Export
```

P0 只实现 OpenAI-compatible Chat Completions。Responses、Ollama 和多 Provider 管理在首条本地闭环稳定后评估。

协议、Base URL、模型名和秘密分离：

- Adapter 负责请求路径、Header 和流式事件翻译。
- 领域层不认识具体 Provider 名。
- 401 不自动重试；429/5xx 只做有界重试。
- 流中断保存部分结果并标记不完整，不自动拼接不可信续写。

V0.2 的具体组件、秘密边界、错误矩阵与任务拆分见 `docs/specs/V0.2_BYOK_PLAN.md`，集中验收证据见 `docs/specs/V0.2_BYOK_ACCEPTANCE.md`。02B 已把当前 Capture 与 Run 接入 SQLite：queued commit 早于 starting，running commit 早于 Provider，partial commit 早于 streaming UI，terminal commit 早于 terminal UI；当前 Provider 没有 usage 事件，因此 token/cost 保持 NULL。每个 stable code 由 App 层统一映射为中文原因与恢复动作，storage safeDetail 默认为 nil；Orchestrator 在持久化与 RunState 前对本次短时 API Key 做精确 redaction。02C 在 History 详情中保留当前 Capture 的总结、翻译、停止、流式结果和状态入口；Loop 2 export 只消费已持久化且已脱敏的 projection，不触发 Provider、网络或数据库写入。

### 7.0 Provider 错误展示边界

Provider 的 HTTP response body 是不受本项目控制的自由文本；它只在 Adapter 内以受限字节数短暂解析，用 HTTP 状态和**结构化错误 code**映射稳定内部错误码。它不会进入 `ModelProviderFailure`、`RunState`、连接测试状态、SQLite、导出、日志或 SwiftUI。404 只在明确的结构化 model-not-found code 存在时映射“模型不存在”；未知或仅含 message 的 404 保守映射“接口不存在”。

UI 只按内部错误码组合固定本地化 `message + recoveryAction`：402 保留“到服务商控制台检查支付方式、余额或额度”的行动指引，404 的模型/接口两种固定文案也保留。此前三轮尝试以 denylist 净化任意服务商摘要，先后暴露换行 Key、复合字段/折行 userinfo 和未封闭的 URI/自然语言/Unicode 语法类别；这证明 Provider-neutral 的自由文本不存在可证明完备的过滤集合。固定文案牺牲了服务商原话，却把可见边界收敛为有限的内部 code 集合，因而能由类型、测试和持久化合同共同验证。

### 7.1 数据去向确认与连接测试

```text
用户点总结/翻译
  → AppViewModel 读取非敏感 ProviderProfile
  → DataDestinationIdentity + ConsentStore
  → 原生确认 sheet（Base URL/host、模型、模式）
  → 冻结 Capture + intent + identity 后创建 PersistentRunRequest
  → ModelRunOrchestrator 短时读取 Keychain secret 并调用 Provider
```

`DataDestinationIdentity` 永不含 API Key 或 `secretReference`，未保存草稿也通过不构造 secret reference 的安全初始化器生成同一规范身份。`UserDefaultsDataDestinationConsentStore` 只写该身份集合；读取失败视为未确认，写入失败只放行用户当次明确确认并提示下次重问。`AppViewModel` 以一个 attempt 同时拥有 token、Capture、intent、identity 与 sheet；非 sheet/非 launch 的每个终点都由 owner-checked 释放，成功则先建立 `launchPendingRunID` 再交接。新 Capture、取消或迟到 continuation 只能清理自己的 attempt，不能清理或发送新 attempt。

`ProviderSettingsViewModel` 保存 `savedIdentity` 和非敏感 `draftGeneration`；只有草稿等于已保存 identity、没有保存/测试在途且 API Key 本地输入为空时才允许测试。测试冻结 request ID、generation 与 saved identity，完成时三者仍一致才更新 UI；编辑期间旧成功会被丢弃。`ProviderConfigurationService` 用 actor-owned `configurationRevision` 和 `inFlightMutation`：save 在首个 await 前占有 mutation 并递增 revision，authorize/read 在每个 store await 后复核，保存中 fail closed。连接测试仍只消费完成事件，不保存 delta/回复，不触及 HistoryApplicationService；API Key 不进入 observable state。

### 7.2 Loop 6 生成偏好与代理路由

主窗口工具栏提供可发现的模型设置入口；当前 Capture 和任意可写 History 详情均可发起总结/翻译。`ModelPreferences` 冻结本次默认/自定义总结 prompt 与目标语言，`UserDefaultsModelPreferencesStore` 只保存这两项非秘密偏好；API Key 的 Keychain 边界不变。App composition 在窗口 bootstrap 的最早阶段加载偏好，不依赖打开 Settings；加载期间两类生成按钮禁用，完成后首次总结/翻译才冻结保存的 prompt/目标语言。Provider 只接收冻结后的 prompt、目标语言、标题和正文。

手动链接由 `ProxyAwareWebPageFetcher` 路由：普通公网且无系统 HTTP(S) 代理时继续使用 `PeerBoundNetworkWebPageFetcher`；显式系统代理存在时，或 DNS 全部返回 `198.18.0.0/15` fake-ip 时，交给 `SystemProxyWebPageFetcher`。代理路径**只允许 HTTPS**，保留原 URL hostname，Foundation 通过系统代理/VPN 建立 CONNECT，并在 challenge 中再次用 `SecPolicyCreateSSL(true, hostname)`、`SecTrustSetNetworkFetchAllowed(false)` 与 system trust 校验；每跳仍拒绝私网/test-net、非标准端口、含凭据 URL、redirect 越界和 HTTPS→HTTP 降级。它不验证代理最终解析的 numeric peer，因此是独立信任边界，不与 PeerBound 的 DNS-rebinding/SSRF 保护等价；HTTP 页面 fail closed 并引导浏览器扩展。`urlCredentialStorage` 固定为 `nil`，应用也不读取、转交或默认处理代理认证 challenge：需认证时明确失败，用户须先在系统代理完成认证；凭据不进入状态、日志、导出或 fixture。

### 7.3 Loop 6.5 GitHub 来源适配器与本地 README 图片

`SourceAdapting` 是刻意小的来源接缝：它只判断一个用户提交 URL 是否由自己接管，并产出 `CapturedDocument`；持久化、模型运行与 UI 均不认识具体来源。默认注册表目前只有 `GitHubRepositorySourceAdapter`：仅 `https://github.com/owner/repo`（允许尾斜杠及普通 query/fragment）接管，issues/blob/tree 等路径继续进入通用网页链路。接管后 Adapter 以固定 `Accept: application/vnd.github.raw+json` 请求 `api.github.com/repos/{owner}/{repo}/readme`；它复用 `ProxyAwareWebPageFetcher` 的 PeerBound/系统代理三分流、TLS、redirect、DNS/IP admission 与 response byte limit，绝不另开 URLSession 旁路。404 只映射“仓库不存在或不是公开仓库”，403/429 只映射限流固定文案，response body 不进入任何可见状态。

README Markdown 原样成为正文，标题为 `owner/repo`。图片是可失败的本地附件：只解析仓库相对路径，或 `github.com`、`raw.githubusercontent.com`、`*.githubusercontent.com` 的 HTTPS 绝对路径；外部 badge/图片根本不请求。每张图片仍走同一安全资源 transport，单张最多 5 MiB、最多 20 张，并在**每个 redirect hop 和最终 URL**重验上述 host 边界；MIME 必须是 PNG/JPEG/GIF/WebP 且与对应魔数一致（WebP 必须为 `RIFF....WEBP`）。适配器先按 capture request ID 暂存，SQLite commit 返回 TaskID/SnapshotID 后才原子移到 Application Support 的任务子目录；History 只从这份 manifest 指向的本地 `NSImage` 读取，永不运行时远程加载。成功删除 Task 后清理同名目录；缓存异常、外部图片、MIME/魔数/大小失败都不会阻断 README 的总结或翻译。

### 7.4 Loop 6.6 历史运行元数据、Token 与 favicon

`ModelStreamEvent` 把 OpenAI-compatible SSE 的 usage 尾块与正文 delta 分开：`prompt_tokens`、`completion_tokens`、`total_tokens` 仅在完成 `Run` 时交给既有 `RunUsageCost` 字段，不能成为正文或 RunState 输出。Migration001 已有对应五列，旧 Provider 流不含 usage 时继续保存 unknown；History 详情从 `Task` 和最新 `Run` 读取操作、模型、创建时间、状态和 Token（输入/输出拆分），不从当前设置或网络回填。BYOK 不显示费用：任意模型的价格、缓存规则和币种无法被本机可靠验证，宁可不估算也不制造账单事实。

列表 favicon 是独立的 best-effort 本地附件，不是新的抓取入口。`WebsiteFaviconCache` 只把已捕获 URL 规范为同 scheme/host 的 `/favicon.ico`，再通过 `SafeResourceFetching` 复用 `ProxyAwareWebPageFetcher` 的 URL admission、peer/TLS 与逐跳 redirect 防护；redirect 还必须保持同一规范 host。每 host 最多 64 KiB，要求 image MIME 与 PNG/JPEG/GIF/WebP/ICO 魔数一致；失败、超限或非图片只回退通用文档图标，绝不阻断历史、README、总结或翻译。缓存文件按 host 的 hash 存在 Application Support；每次成功写入清理 30 天未使用项，随后只保留最近 128 host。Task 删除不会删除共享 host 缓存；GitHub 行使用固定本地符号，不发 favicon 请求；SwiftUI 只读取本地 `NSImage`，不在渲染时远程加载。

### 7.5 Loop 6.8 设置与模型选择

设置分为“模型服务”和“生成与数据”两页：前者只管理可编辑的 Base URL、模型、无 Key 的厂商预设和 Keychain 受控的 API Key；后者只管理非秘密的总结提示词、全局输出语言、可选独立翻译模型和数据去向静态卡。预设只是可编辑的 URL 模板与文案，不携带 Key，也不改变 `ProviderSettingsViewModel` 的加载/保存/已配置/更换四态入口门禁。`http://127.0.0.1` 仅在设置保存时显式启用，`localhost` 与其它私网 HTTP 仍被 `ProviderProfile.validatedBaseURL` 拒绝；数据卡和发送前确认都会如实标为本地端点。

`GET /models` 是 `OpenAICompatibleProvider` 的受限目录读取，不是新的网络面：它复用同一个注入 `URLSession`、Base URL 校验、同源 HTTPS redirect guard、固定错误码与 API Key 短时使用边界；只保留最多 500 个非空 `id`，其余响应字段和 body 均丢弃。失败、超时、格式不符或空目录都回退可编辑手填模型，不影响已保存值。`ModelPreferences` 将旧 `targetLanguage` 平滑读取为 `outputLanguage`，总结 prompt 在用户模板之后追加输出语言指令；翻译可选模型和历史“临时模型”只生成运行期 `ProviderProfile`，同一 Base URL/Keychain reference 不变，并以该实际模型重新做发送目的地确认。

History 的同语言翻译门禁是本地、保守的脚本判定：仅中文/日文/韩文/拉丁字母明显占优且可映射到输出语言时禁用翻译；混合、短文本和未知语言仍允许。重新生成只从本机已保存 snapshot 取正文，不重新抓取；可临时换模型。`visible_only` 与 `selection_only` Capture 会在详情明确标注内容截断。

### 7.6 Loop 7 扩展技术身份与显示名边界

Chromium 扩展的技术身份与产品显示名分开管理。`config/extension-identity.json` 只保存公开的 RSA SubjectPublicKeyInfo DER base64、由其 SHA-256 前 16 bytes 映射到 `a...p` 字母表所得的 32 字符 extension ID、版本和公开工件路径；WXT 把该 public key 写进 MV3 `manifest.key`，所以改显示名、描述或 UI 文案不会改 ID。`config/native-host.json` 的 frozen `releaseExtensionIDs` 必须精确等于这个 ID，release renderer、Chrome/Brave/Edge 三份模板的 `allowed_origins` 都是唯一的 `chrome-extension://<ID>/`，没有 wildcard。Team ID、Developer ID、notarization 与真实浏览器安装仍未冻结，产品/公开发布继续 BLOCKED。

开发身份私钥不是仓库输入、候选输入或 Keychain 项。本轮仅开发 key 位于 `/Users/song/Library/Developer/LinkDigest/extension-identity/linkdigest-loop7-development-extension.pem`（0600，Application Support 之外）；`scripts/extension_identity_artifact.py generate-development-key --private-key-path ...` 只允许新建仓库外的同名路径，并只输出可公开的 ID/key 派生结果。未来正式商店 key 由 Syc 单独管理，不能复用或自动导出该开发 key。

`apps/desktop/Sources/LinkDigestCore/Resources/product-display.json` 是当前工作名、扩展描述和 App 中“浏览器扩展”称呼的唯一显示源。WXT 在构建 manifest 时读取它；Swift `ProductDisplay` 从 bundle 读取它；popup 运行时读取 manifest name。改名只编辑这一个资源，工件内容 hash 会自然变化，但 public key、ID、Native Host origin 和工件结构不得变化。

`pnpm browser:build` 先产生 WXT output，再由零依赖 `extension_identity_artifact.py` 创建固定 mtime、排序和 0644 entry mode 的 zip，并生成三份 Host path placeholder 模板。`pnpm browser:identity:check` 从同一 WXT output 双次生成 zip 并断言字节一致、manifest key/ID/version/display 一致、三模板 origin 一致。冻结时 local-test pipeline 只从已冻结 source archive 的 `identity-artifact/` 复制 zip/模板进入 handoff；`BUILD_MANIFEST`、`SHA256SUMS` 和 gate 再交叉绑定 artifact、identity config、template 与 source record hash。它不安装 manifest、不写真实 profile，也不把候选 zip 误称为在候选环境中重新运行 WXT 的证据。

### 7.7 Loop 9 集成交付与总检边界

Loop 9 把 `0.2.0` 的 App、内嵌 Native Host/浏览器模板、确定性扩展 zip、源码归档和证据收敛到一个 exact handoff tree。`config/local-test-release.json` 是版本、候选目录、DMG、source archive、扩展工件和 `docs/ACCEPTANCE_GUIDE.md` 的单一冻结输入；packer 仅从 nofollow live-worktree snapshot 复制它们，随后将候选内指南、App、Host、extension、source/evidence、`BUILD_MANIFEST.json` 与 `SHA256SUMS` 逐项纳入 payload hash 和 tree digest。`identity-artifact/LinkDigest-extension-*-chromium.zip` 必须恰好一项，且路径、内部 manifest version 与 SHA-256 必须等于冻结配置/manifest；因此同一固定 ID 的旧可加载 zip 也会 fail closed。指南的五项 PRD §11.1 目标与验证方法也以逐项文本合同回链 PRD，不能把安装/配置耗时混入“安装与模型配置完成后”才开始的首次价值时间。缺项、多项、hash 不符或指南未能回链 source archive 都会令 gate fail closed。

隔离 gate 不启动 GUI、不写真实 HOME 或调用真实 Provider：它只读挂载 DMG，复验 App tree、Host package、icon、浏览器模板与 extension ID/hash；运行 `ContractTests`、隔离 HOME 的 Browser Support install/repair/uninstall matrix、以及 fixture BYOK 的 summary → automatic tags → translate → GRDB persistence 路径。真实 Chrome/Brave/Edge profile 安装、登录页面捕获、真实 BYOK 和 PRD §11.1 的价值测量由 Syc 按候选内 `ACCEPTANCE_GUIDE.md` 主动执行并记录，不能被这些 fixture 证据替代。

## 8. UI 与 AppKit 边界

SwiftUI 负责：

- App/Scene 生命周期。
- NavigationSplitView、任务列表、详情和设置。
- 原生 toolbar、commands、focus、keyboard shortcuts。
- 空状态、错误卡、进度和动画。

只有以下情况才评估 AppKit：

- SwiftUI TextEditor 无法满足结果编辑与选择行为。
- 精细 NSWindow、NSMenu 或系统服务接入。
- 性能 profiling 证明 SwiftUI 控件不达标。

每个 AppKit bridge 必须拥有单一职责、Coordinator 边界和可测试状态映射。

## 9. P0 安全边界

- API Key、Cookie、Token、正文和私人 URL 不进入普通日志。
- 扩展消息执行大小限制和运行时 schema 校验。
- `ephemeralPlaybackURL` 只允许在扩展→Host→APP 当前进程内存中交接；禁止 SQLite、日志、导出、错误详情和持久化 fingerprint。
- Douyin M1 只读当前 DOM 的公开 `video/source` 与页面 metadata；已删除私有 aweme detail endpoint 和 `credentials: include` 路径。
- 当抖音发布时间或互动字段缺失时，扩展可在**当前 popup**显示独立的 `DouyinMetadataDiagnostic`：它只含固定拒绝码、布尔值与小范围计数/位图。DOM 注入 → background 合并 SSR → popup 是一条 sibling 旁路，绝不写入 `CaptureEnvelope`、schema、Native Host、桌面端或数据库；字段完整时直接丢弃。sanitizer 按字段重建 allowlist，拒绝 URL、标题、作者、时间/统计值、DOM 文本/selector、raw JSON、host、Cookie、storage 与网络资料。
- URL 只接受 `http`/`https`；文件路径与自定义 scheme 默认拒绝。
- APP 不加载远程 Web UI，不嵌入任意网页执行环境。
- 不读取浏览器 Cookie 数据库。
- 测试 fixture 必须脱敏，不包含真实账号页面。
- 商业闭源依赖先检查许可证；GPL/AGPL/非商业许可不得直接合入。

## 10. 发布路线

P0 发布验证按 r1 → r2 → r3 → r4a 顺序推进：

1. r1：Stable Host package、verifier、manifest renderer 与 clean-room 初装（最终独立 re-review PASS）。
2. r2：clean-room 升级/卸载/journal/recover 首次 review BLOCK 后三项 P1 已修复，同一 reviewer 唯一 re-review PASS，P0/P1/P2 = 0/0/0；真实用户目录不在该 PASS 范围。
3. r3：`release_preflight.py report|plan` 只读取 frozen policy、r1 package 与已有离线签名/公证 evidence，canonical JSON 稳定为 `BLOCKED`。正式 review 0/2/2、唯一 re-review 0/1/0 后，cache-safe 101 项候选通过新的独立最终审查，P0/P1/P2 = 0/0/0。codesign 按 exact Authority/TeamIdentifier/flags runtime 行解析，spctl 要求唯一 exact notarized source + Developer ID origin并固定 `--ignore-cache --no-cache`；fixed Apple queries 不继承 caller 环境、DEVNULL/timeout fail closed。r3 不挂载 DMG 或读取真实 install namespace，仍固定阻断未验证的 App-DMG release unit 与 manifest target ownership。
4. r4a：`release_unit.py` 只在 caller 指定的新 `/private/tmp/linkdigest-r4a-release.*` 构建。source、GRDB、resource 与 executable copy 由逐组件 `openat + O_NOFOLLOW` walker 完成，拒绝 symlink、special file 与 regular hardlink。真实 target probe 同样以 anchored directory fd 打开五个固定 leaf，在同一 leaf fd 上 fstat、limit+1 bounded read/hash并复核 inode。attach 的 success/nonzero/坏 plist 都立即进入 cleanup guard；只有 `hdiutil info -plist` 唯一绑定同一 DMG+mount 时才能 exact detach/force。candidate audit 永远只读，tamper/Swift scratch/gate result 只写新的 `/private/tmp/linkdigest-r4a-review.*`。该 unsigned release-unit 工程门禁已独立 PASS，产品仍 BLOCKED。
5. r4b：`local_test_release.py` 不使用 Git，而以 exact allowlist 从 live dirty worktree 生成 nofollow/single-link source snapshot；GRDB 7.11.1 独立 snapshot 后，两份确定性 tar.gz 是 build 的唯一输入。Host 先 ad-hoc sign，再生成并验证 r1 package；App 组装完成后外层 ad-hoc sign，再复验嵌套 package。DMG、源码、BUILD_MANIFEST、SOURCE_MANIFEST、tool/signature/mount evidence 进入同一 exact handoff。gate 只读 audit、写独立 review root；candidate-07 已独立 PASS 0/0/0 并 finalize，当前 `READY_FOR_MANUAL_OPEN`、等待 Syc 手工打开，产品/公开发布仍 BLOCKED。

后续公证 DMG 路径仍需验证：

1. Xcode Release 构建。
2. APP、Helper/Host 与扩展版本对齐。
3. Developer ID 签名与 hardened runtime。
4. Notarization 与 stapling。
5. 干净用户环境安装、升级、卸载。
6. Chrome/Brave/Edge Native Host manifest 检测。

是否进入 Mac App Store 必须在 Native Messaging 与 sandbox spike 后决定，不能在 PRD 中提前承诺。

## 11. 未来云端边界

账号、选择性同步和托管模型仍是候选增值能力，但全部在 P0 之后重新验证。若进入云端阶段：

- local-first 与 BYOK 不依赖 Cloud API。
- 原文默认不上云。
- 云端框架和部署厂商重新选择，不由旧 Electron 方案自动继承。
- `docs/CAPACITY_MODEL.md` 只作为远期假设和压测参考，不驱动当前部署。

## 12. 已知未知项与 spike 顺序

| 顺序 | 未知项 | 证据 |
|---|---|---|
| 1 | 正式 release IDs、Team ID、Developer ID/hardened runtime、notarization/stapling 与真实安装/浏览器验收 | r4a unsigned App-DMG binding 工程 PASS、真实固定 target probe BLOCKED + 后续单独授权 |
| 2 | 跨语言 schema 一致性 | 两端 fixture tests |
| 3 | Swift SQLite binding | 打包、迁移和恢复测试 |
| 4 | 流式 Provider 兼容 | 固定 fake server + 真实端点抽样 |
| 5 | SwiftUI 富文本能力 | 可选择、复制、编辑和长文性能测试 |
| 6 | DMG 与 Mac App Store | sandbox/分发 spike |

未知项按顺序验证；前一项未通过时，不扩大后续平台或云端范围。

## 13. 可替换与不可变

可以替换：

- WXT。
- Swift SQLite binding。
- Native Host 的具体进程形式。
- Provider adapter 实现。
- 公证 DMG 的安装器工具。

不可静默改变：

- macOS 原生 SwiftUI 主路线。
- 当前页面优先。
- local-first 与免登录 P0。
- Provider-neutral。
- 秘密不进普通存储。
- 版本化、可解释的跨端协议。

需要改变不可变项时，必须先通过 Project Brain 记录 reversal，再同步 PRD、Architecture 和验收。
