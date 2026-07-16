# LinkDigest 名词词典

这里只记录项目实际出现过、会影响理解和判断的名词。解释优先使用人话和项目中的真实位置，不追求教科书式定义。

讲解深度：L1 认识、L2 定位、L3 共同观察验证、L4 修改。`当前覆盖` 记录项目已经提供到什么讲解深度，不代表对 Syc 进行考试，也不要求 Syc 先证明学会才能继续开发。

| 名词 | 人话解释 | 生活类比 | 在 LinkDigest 中的作用 | 没有或损坏时 | 目标等级 | 当前覆盖 |
|---|---|---|---|---|---|---|
| Repository / 仓库 | 一个项目全部代码、文档和变更历史所在的文件夹 | 带目录和修改记录的工程档案柜 | 保存 LinkDigest 的所有可追踪资料 | 文件散落，无法知道谁改了什么 | L3 | L1 |
| PRD | 说明产品为谁解决什么问题、做到什么程度、如何验收的文档 | 开工前的房屋需求书 | 约束 LinkDigest 的范围、优先级和验收 | AI 容易按想象加功能或漏掉边界 | L2 | L1 |
| Project Brain | 保存长期决策、原因和反转记录的项目记忆 | 项目的长期决策档案 | 让后续 Agent 知道为什么这样设计 | 同样的问题反复讨论，决策漂移 | L2 | L1 |
| Git | 记录文件每次变化并支持比较、恢复的工具 | 工程的时间机器 | 追踪每个开发阶段，未来用于发布协作 | 难以回看和安全恢复 | L3 | L1 |
| Monorepo | 在一个仓库中管理多个相关应用和共享模块 | 同一园区里的不同车间 | 同时管理桌面端、扩展和共享包 | 跨端协议容易重复和漂移 | L2 | L1 |
| Browser Extension / 浏览器扩展 | 安装在浏览器里、能响应用户操作的小程序 | 驻在浏览器里的助手 | 从 Chrome、Brave、Edge 把当前页面发送给 APP | 只能粘贴 URL，拿不到已登录页面正文 | L3 | L3 |
| DOM | 浏览器把网页解析后形成的可读取页面结构 | 网页在浏览器里的结构化施工图 | 让扩展找到标题、正文和选区 | 只能重新请求 URL，可能只抓到登录壳 | L3 | L3 |
| Content Script | 浏览器扩展注入普通网页、负责读写页面的脚本 | 扩展派到网页现场的读取员 | 从 DOM 中提取当前用户看见的内容 | 扩展面板知道 URL，但读不到正文 | L3 | L3 |
| Manifest V3 | Chrome 扩展声明身份、入口和权限的当前规范 | 扩展提交给浏览器的营业执照和权限清单 | 告诉浏览器扩展需要哪些能力 | 扩展无法安装、运行或通过审核 | L2 | L2 |
| Content Security Policy / CSP | 浏览器限制扩展页面能执行哪些脚本的安全规则 | 工作区门禁禁止现场拼装未经检查的机器 | MV3 background 只能运行构建好的静态代码，不能用 `eval` 现场编译 Schema | Service Worker 会在启动时被浏览器阻止 | L2 | L2 |
| TCC | macOS 对“文稿、桌面、下载”等隐私位置的访问许可系统 | 进入私人房间前由系统门卫再次确认 | 决定浏览器启动的 Native Host 能否读取其所在路径和资源 | Host 可能在进入 Swift 主逻辑前等待权限，表现为超时 | L2 | L2 |
| Native Messaging | Chromium 扩展与本机程序之间的官方通信机制 | 浏览器和桌面 APP 之间的专用传送带 | 把当前页面正文安全交给桌面 APP | 扩展和 APP 各自工作但无法交接 | L3 | L3 |
| SwiftUI | Apple 用 Swift 声明原生界面的框架 | 描述“房间应该长什么样”，系统负责摆放和更新 | 承载 LinkDigest 的 macOS 窗口、侧边栏、详情和设置 | 需要改用 AppKit 或跨平台桌面壳 | L3 | L2 |
| AppKit Bridge | 把少数传统 macOS 原生控件接入 SwiftUI 的边界 | 新房里为特殊设备保留一个标准转接头 | 只补富文本、窗口或菜单等 SwiftUI 明确缺口 | 要么放弃能力，要么把整个 UI 写成两套 | L2 | L2 |
| Native Host | 接收 Chromium Native Messaging 并交给本机 APP 的程序入口 | 浏览器传送带在电脑这一端的收货员 | 校验 framing、版本、大小并把消息交给 Swift | 扩展与 APP 无法可靠通信 | L3 | L3 |
| Unix Domain Socket / 本机套接字 | 同一台 Mac 上两个进程使用的私有通信通道 | 同一栋楼里的内部传送管 | V0.1 让独立 Native Host 把已校验消息交给正在运行的 APP | Host 只能知道浏览器消息，无法更新 SwiftUI | L3 | L3 |
| CaptureEnvelopeV1 | 扩展交给 APP 的第一版页面捕获包 | 带版本号和内容清单的标准包裹 | 固定标题、URL、正文、字符数、捕获证据与版本 | Swift 和 TypeScript 会各自猜字段，升级时静默断裂 | L3 | L3 |
| Native Messaging Framing | 在 JSON 前写入四字节小端长度的消息边界 | 包裹外先贴“里面有多少字节”的标签 | 让 Host 从 stdin/stdout 准确读出一条 Chromium 消息 | 半包、粘包或超大消息会被误读或卡住 | L3 | L3 |
| Vertical Slice / 垂直切片 | 从用户入口到可见结果只打通最薄的一条完整链路 | 先修通一部能从一楼到顶楼的电梯 | V0.1 只证明页面可以进入 SwiftUI APP | 容易先造很多零件却没有可运行产品 | L3 | L3 |
| Electron（归档路线） | 用 Chromium 和 Node.js 构建跨平台桌面 APP 的运行框架 | 把网页技术装进桌面程序外壳 | 2026-07-13 前的桌面候选，已被 macOS SwiftUI P0 取代 | 若未来 Windows 成为硬约束可重新评估 | L1 | L1 |
| API | 两个软件按约定请求和返回数据的接口 | 餐厅里标准化的点菜单和出餐口 | 桌面 APP 通过它调用大模型 | 模型无法被程序稳定调用 | L3 | L2 |
| Base URL | 某个 API 服务的基础地址 | 快递要先知道送到哪座园区 | 告诉模型适配器请求发往哪个服务 | 请求可能发错位置，出现 404/405 | L3 | L3 |
| Provider | 实际提供模型 API 或本地模型能力的一方 | 提供不同服务的供应商 | DeepInfra、OpenRouter、Ollama 等都可成为连接 | 产品会被锁死在单一模型端点 | L2 | L2 |
| ProviderProfile | 不含秘密的单个模型连接配置 | 写着服务地址但不写保险柜密码的联系人卡 | 保存 Base URL、模型名、API 模式和 Keychain reference | APP 不知道该连接哪里，或把配置与秘密混在一起 | L3 | L3 |
| SecretStore | 保存和读取秘密的统一接口 | 只通过窗口交接物品的保险柜 | 让 Application 只请求秘密，不依赖具体 Keychain API | Key 容易泄漏到 View、UserDefaults 或测试 | L3 | L3 |
| ModelProvider | 把领域请求翻译成模型协议的接口 | 在业务人员与不同供应商之间工作的翻译员 | 隔离 Orchestrator 与 Chat Completions/URLSession 细节 | 总结流程会被某个端点格式锁死 | L3 | L3 |
| SSE | 服务端在一条 HTTP 连接中连续发送文本事件的格式 | 不断从同一条传送带送来小纸条 | 把 Chat Completions 的 `data:` 行翻译成 delta 与完成事件 | APP 只能等完整结果，或把半包误当最终结果 | L3 | L3 |
| RunState | 一次模型运行从开始到结束的可观察状态 | 显示运输中、已停止或已送达的快递追踪页 | 驱动 starting、streaming、stopped、completed、incomplete 和 failed UI | 界面无法判断结果是否仍在变化或是否可信完整 | L3 | L3 |
| ModelRunOrchestrator | 协调模型配置、秘密读取、流事件和 UI 状态的应用层调度器 | 只负责安排交接、不亲自开车的调度员 | 从当前 capture 生成 intent，短时读取 Key，并把 Provider 事件映射为 RunState | ViewModel 会直接碰 Keychain、网络和 SSE，状态难以单测 | L3 | L3 |
| Cancellation Propagation / 取消传播 | 用户点停止后，把取消信号一路传到底层请求 | 总闸关闭后，每一级设备都真正断电 | 从 SwiftUI 动作传到 Orchestrator Task、AsyncThrowingStream 和 URLSession | UI 看似停止，后台仍消耗 token 并产生迟到文本 | L3 | L3 |
| Stale Run Isolation / 旧任务隔离 | 只接受当前 run identifier 的事件，丢弃已作废任务的迟到更新 | 新订单建立后，旧订单不能继续往新餐盘加菜 | Core 与 MainActor ViewModel 两层过滤旧 run delta | 快速重试或切换动作时，旧结果会覆盖新结果 | L3 | L3 |
| Incomplete Result / 不完整结果 | 已经收到部分文本后异常中断，保留内容但明确标记不完整 | 包裹只送到一部分，收件单注明缺件 | 网络或协议失败且已有 partial 时进入 `RunState.incomplete` | 有用的部分结果会丢失，或被误当成完整答案 | L3 | L3 |
| Stable Error / 稳定错误 | 不把底层原始错误直接给界面，而用固定 code 连接原因与恢复动作 | 医院先按统一分诊编号，再给患者清楚说明 | V0.2 的配置、Provider 与 Run 失败统一进入中文错误目录 | UI 文案漂移，或把 Provider body、URL、Key 暴露给用户 | L3 | L3 |
| Redaction / 脱敏 | 在数据进入可见状态前，把已知秘密替换成固定占位符 | 公开文件前把身份证号涂黑 | Orchestrator 防御异常 Provider 回显本次 API Key，脚本检查日志和状态边界 | 秘密可能进入 RunState、测试输出或截图 | L3 | L3 |
| Secret Hygiene / 秘密卫生门禁 | 用静态规则检查秘密是否可能进入源码、日志、状态或测试材料 | 食品出厂前同时检查原料、容器和标签 | `pnpm secret:check` 在 doctor 中作为 V0.2 阻断检查 | 单测全绿时仍可能把 Key 形状带进仓库或用户可见状态 | L3 | L3 |
| Sentinel / 测试哨兵值 | 测试临时生成的明显假秘密，用来追踪它是否越过安全边界 | 消防演习使用的无害烟雾 | Swift tests 生成 `sentinel-<UUID>` 并断言 RunState、UI 和错误文案不含它 | 很难证明“未泄漏”覆盖了真实数据流，而又不能使用真实 Key | L2 | L2 |
| Keychain Orphan | 已不再被当前配置引用、但因旧 item 删除失败仍留在 Keychain 的条目 | 换锁后遗留且无人登记的一把旧钥匙 | Provider staged save 成功后的 best-effort 旧引用清理 | 新配置仍可用，但历史秘密会不可见地累积 | L3 | L2 |
| Bounded Retry / 有界重试 | 只在明确错误下、最多有限次数重发请求 | 客服只回拨约定次数，不无限拨号 | 429/5xx 在尚无输出时最多重试两次 | 无限请求会增加费用、等待和重复结果风险 | L3 | L3 |
| SQLite | 保存在单个本地数据库文件中的结构化存储 | 本机上的可检索卡片柜 | 保存任务、原文、摘要和执行记录 | 历史只能散落成文件且难以检索 | L3 | L3 |
| Binding | 把 Swift 调用翻译成 SQLite C API 的代码层 | 双语柜台 | GRDB 只存在于 `LinkDigestPersistence` 内部 | 每个连接、参数和错误都要自行封装 | L3 | L3 |
| WAL | 把已提交变更先追加到旁边日志，再择机归并主库 | 仓库的当日流水账 | 让一个 writer 与多个 readers 并行，并生成同目录 `-wal/-shm` | 读写更容易互相阻塞，复制主文件还可能漏数据 | L3 | L3 |
| Migration | 按版本、只向前改变数据库结构 | 房屋逐期装修记录 | V0.3 spike 验证 v001 → v002 与失败回滚 | 老数据库无法安全升级，失败可能留下半结构 | L3 | L3 |
| Online Backup | SQLite 对活跃数据库生成一致快照的受控 API | 营业中的档案馆由管理员复印 | 备份包含 WAL 中已提交状态，再受控恢复并做 integrity check | 直接复制活跃主文件可能漏记录或损坏 | L3 | L3 |
| Read-only Recovery | 写入有风险时禁止修改，但尽量保留读取与导出 | 仓库封存后仍允许盘点取件 | future schema、migration 失败和存储不可写的逃生口 | 用户只能冒险写入或删库重来 | L3 | L3 |
| Canonical URL | 只做无争议规则后的稳定链接身份 | 把门牌大小写和默认端口统一，但不擅自换街道 | Core v1 小写 scheme/host、去 fragment/default port、补 `/`，保留 path/query 顺序 | 同一链接会重复建档，或过度归一化误合并不同内容 | L3 | L3 |
| Payload Fingerprint | 对捕获语义做确定性 SHA-256 指纹 | 给包裹内容盖章，运输单号变化不影响内容身份 | 长度前缀 UTF-8 编码 source/capture/evidence/时间，排除 requestId/idempotencyKey | transport 重试可能重复入库，或 hash JSON 字节导致跨实现漂移 | L3 | L3 |
| Repository Port | Core 声明的稳定数据存取接口 | 统一插座，GRDB 只是可替换插头 | 02A 的 capture/run/history/detail/export/delete 命令与结果边界 | Application/UI 会直接持有 SQL 或 GRDB 类型 | L3 | L3 |
| Keyset Pagination | 从上一页最后一条排序键继续查下一页 | 用上一张书签继续翻，而非每次从第一页数 | History 以 `(updated_at_ms, task_id)` 排序分页，首页不读正文 | 大历史使用 OFFSET 时越翻越慢且并发插入易错位 | L3 | L3 |
| NavigationSplitView | SwiftUI 提供的 macOS 原生分栏容器 | 左边目录、右边正文的原生资料柜 | 02C 承载 340pt History Sidebar 与详情区，并沿用系统选中态和 toolbar | 自行拼接分栏容易偏离 macOS 行为、焦点和可访问性 | L3 | L3 |
| Request Identity Guard / 请求身份闸门 | 只允许当前代际、当前请求的异步结果更新界面 | 换了新取餐号后，旧号码送来的餐不能放进新餐盘 | `HistoryViewModel` 用 generation、list/detail/delete request ID 拒绝分页、快速切换和重新配置后的旧回写 | 慢详情或旧删除结果会覆盖用户刚选择的新记录 | L3 | L3 |
| Deletion Target Binding / 删除目标绑定 | 打开确认框时就冻结要删除的 Task，而不是确认时重新猜当前选择 | 填好快递单后锁定收件人，不能在按下确认时换成旁边的人 | 02C 的 `pendingDeletionTaskID` 防止新 Capture 改选中项后误删；`activeRunTaskID` 另行保护生成中的 Task | 确认期间的页面切换或新 Capture 可能让用户删错记录，活跃 Run 还会被级联破坏 | L3 | L3 |
| local-first | 核心功能和数据默认在用户本机完成与保存 | 先放自己的保险柜，需要时才同步 | P0 不依赖服务器也可总结、翻译和查历史 | 断网不可用，隐私和服务器成本上升 | L3 | L1 |
| Capacity Model / 容量模型 | 把用户目标换算成请求、任务、连接和数据量的计算基线 | 桥梁开工前的承重表 | 连接注册目标、架构设计、压测和扩容判断 | “100 万用户”无法变成可验证的工程目标 | L3 | 未开始 |
| Modular Monolith / 模块化单体 | 一个可部署服务内部按业务划出不可随意穿透的模块 | 一栋楼里的独立店铺，共用大楼但各管各的货 | 组织云端 Identity、Sync、Managed AI 等模块 | 普通单体容易互相缠绕，过早微服务又增加运维成本 | L3 | 未开始 |
| RPS | 每秒到达 API 的请求数量 | 收费站每秒通过多少辆车 | 作为云端 API 压测和横向扩容的统一口径 | 无法量化服务器负载或比较压测结果 | L3 | 未开始 |
| SLO | 系统对延迟、可用性和恢复能力给出的可测目标 | 快递承诺多久送达、多少件不丢 | 判断 API、同步和恢复是否达到发布标准 | 团队只能笼统说“稳定”，无法验收或报警 | L3 | 未开始 |
| Idempotency / 幂等 | 同一个写请求重复执行仍只产生一次业务结果 | 重复按付款按钮也只扣一次钱 | 保护账号、同步、托管任务和额度写入的网络重试 | 断网重试可能制造重复任务、重复记录或重复计费 | L3 | 未开始 |
| Single Source of Truth / 唯一真相源 | 同一类事实只认一个权威位置，其它位置只引用 | 公司只认一份正式制度，其它群消息不能改规则 | 区分 PRD、架构、容量、Brain 和代码分别拥有什么事实 | 多份文档会逐渐互相矛盾，Agent 不知道该信谁 | L3 | L2 |
| Bootstrap / 播种 | 把空模板填入已经确认的真实项目知识 | 给新档案柜放入第一批有效档案 | 将六个 Brain 根页面从 placeholder 变为项目背景、架构、流程、功能、技术和路线图 | Brain 虽然存在，但新 Agent 读取后仍得不到上下文 | L2 | L2 |
| Doctor / 健康检查 | 用一条只读命令串联项目的关键一致性与安全检查 | APP 开工或发布前做一次体检 | 检查入口、Brain、文档、学习规则、敏感边界和 Git 基线 | 文档或记忆损坏后可能直到开发走偏才被发现 | L3 | L3 |
| Drift / 漂移 | 多个入口随着修改逐渐变得不一致 | 地图没有随道路变化而更新 | 描述 README、AGENTS、Brain、PRD 与真实实现之间的偏差 | 后续 Agent 会依据过期规则做出错误修改 | L2 | L2 |
| Identity | 确认一个账号是谁，并把外部登录结果映射到内部用户 | 护照柜台先确认身份，再办理后续业务 | 云端账号模块的入口，关联 User、Device 和 session | 无法安全识别同一用户或撤销设备 | L3 | L2 |
| Entitlement | 描述用户当前可以使用哪些功能、还剩多少额度 | 门票和套餐清单 | 位于账号、同步与托管模型之间 | 系统会把“已登录”错误当成“拥有付费权限” | L3 | L2 |
| Encrypted Blob | 客户端加密后的不透明内容包，云端只负责保存和搬运 | 上锁的保险箱，仓库能搬但看不到里面 | 保存用户主动同步的原文、摘要或翻译 | 只能放弃内容同步，或让服务器接触明文 | L3 | L2 |
| Usage Ledger | 只追加记录额度预留、结算、释放和退款的流水 | 银行对账单 | 托管模型用量与计费的事实记录 | 无法对账、退款或证明没有重复扣费 | L3 | L2 |
| OIDC Adapter | 把不同身份提供商翻译成项目统一账号接口 | 不同国家护照进入同一套边检流程 | Identity 模块与外部登录供应商之间 | 更换登录供应商会侵入用户、设备和权益业务代码 | L2 | L2 |
| Dependency / 依赖 | 项目复用的外部标准代码包 | 购买合规标准零件而不是自己炼钢 | 提供类型检查、测试、lint 和运行时 Schema | 需要重复造轮子，或无法使用成熟验证能力 | L2 | L2 |
| Lockfile / 锁文件 | 记录完整依赖树的精确版本和校验信息 | 经过确认的采购清单 | `pnpm-lock.yaml` 让本机和 CI 安装同一套零件 | 不同机器可能得到不同版本和行为 | L3 | L3 |
| JSON Schema | 与编程语言无关、可在运行时执行的数据合同 | Swift 和 TypeScript 共用的一张海关申报表 | `contracts/capture-envelope-v1.schema.json` 是 V0.1 跨语言唯一真相源 | 两端只能靠复制类型维持，字段和失败语义会漂移 | L3 | L3 |
| Type Check / 类型检查 | 不运行程序就检查代码和数据形状能否连接 | 开工前审查施工图 | 编译阶段发现 TypeScript 接口错误 | 许多交接错误要运行到特定路径才暴露 | L3 | L3 |
| Contract Test / 协议测试 | 验证发送方与接收方仍遵守同一版本和失败语义 | 测试插头与插座是否真的匹配 | 覆盖成功、版本不兼容、字段不一致和秘密字段 | 升级一端可能静默破坏另一端 | L3 | L3 |
| Export Projection / 导出投影 | 为拿走一条历史而准备的、只留下用户需要内容的安全快照 | 档案馆给外借文件准备的脱敏复印件 | Loop 2 的 HistoryExportProjection 是 Core renderer 的唯一输入，排除 provider、idempotency、cookie-use 与 raw error | 导出可能带出 Keychain 引用、内部路径或失败细节 | L3 | L3 |
| Renderer / 渲染器 | 把同一份安全数据稳定排版成不同文件格式的组件 | 同一份稿件交给 Markdown、纯文本和 JSON 三种印刷机 | HistoryExportRenderer 在 Core 生成确定性 UTF-8 字节，不选择目录也不写文件 | View 或数据库会掺入格式细节，测试与复用都会变难 | L2 | L3 |
| FileDocument | SwiftUI 交给 macOS 保存面板的文件信封 | 把已经排好版的文件装进可由系统投递的信封 | HistoryExportDocument 只包住 Core 已生成的 Data，FileExporter 决定用户选的保存位置 | Core 会被迫依赖 SwiftUI 或文件系统，取消和权限处理也会混在业务代码里 | L2 | L3 |
| Export Request Identity / 导出请求身份 | 只让仍属于当前配置、当前选择和当前请求的导出结果打开面板的标记 | 换了取件号后旧包裹不能送到新柜台 | HistoryViewModel 为导出复用 generation/request/task 三重检查 | 快速切换记录时，旧记录可能弹出错误内容或覆盖新选择 | L3 | L3 |

## 更新规则

- 新名词第一次进入开发任务时再添加，不提前堆满百科全书。
- `当前覆盖` 只在项目已经交付对应讲解或验证证据后提升，不以 Syc 答题为条件。
- 同一名词的解释如果越来越复杂，应优先改得更易懂，而不是继续添加术语。
- 架构决策写入 Project Brain；这里只解释词义和项目位置。
