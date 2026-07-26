# LinkDigest 名词词典（历史归档）

> 自 2026-07-24 起，本文件不再要求维护，也不构成任务完成条件，仅保留为历史参考。

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
| Local Event Monitor / 本地事件监视器 | 在 AppKit 把鼠标或滚轮事件交给最深视图前，先做一次本窗口判断的入口 | 商场入口的分流员：只把特定方向的客流导向楼梯，不接管店铺内部服务 | `VideoScrollWheelBroker` 在 History 三个 `VideoPlayer` 的无命中锚点范围内，把纵向滚轮交给外层页面滚动视图 | AVKit 会先消费播放器上的纵向滚轮并把它当作进度擦洗；若错误拦截横向滚轮又会损失原生擦洗 | L3 | L3 |
| Native Host | 接收 Chromium Native Messaging 并交给本机 APP 的程序入口 | 浏览器传送带在电脑这一端的收货员 | 校验 framing、版本、大小并把消息交给 Swift | 扩展与 APP 无法可靠通信 | L3 | L3 |
| Unix Domain Socket / 本机套接字 | 同一台 Mac 上两个进程使用的私有通信通道 | 同一栋楼里的内部传送管 | V0.1 让独立 Native Host 把已校验消息交给正在运行的 APP | Host 只能知道浏览器消息，无法更新 SwiftUI | L3 | L3 |
| CaptureEnvelopeV1 | 扩展交给 APP 的第一版页面捕获包 | 带版本号和内容清单的标准包裹 | 固定标题、URL、正文、字符数、捕获证据与版本；Loop V 起可带可选 media | Swift 和 TypeScript 会各自猜字段，升级时静默断裂 | L3 | L3 |
| media 块 | CaptureEnvelope 上可选的视频元数据 | 包裹里多放的一张「媒体清单」 | 声明 platform/videoURL/封面/时长/作者；旧 envelope 可缺省 | 视频捕获无法与纯文本捕获共用海关单 | L3 | L3 |
| 签名 URL 立即下载 | 播放地址带时效签名，解析后马上存成本机文件 | 限时提货单——当场取走，不当作长期存根 | `VideoMediaDownloader` 在同一流程下载，不把裸 URL 入库复用 | 稍后重放会 403/过期，用户以为已保存却播不了 | L3 | L3 |
| media_assets | SQLite 中记录本机视频文件的表 | 仓库货架上的媒体索引卡 | Migration003：task 外键、相对路径、SHA-256、字节数、时长、转写状态 | 详情页不知道本地视频在哪，删除会留孤儿文件 | L3 | L3 |
| AVKit 本地播放卡 | 详情顶部用系统播放器播本机文件 | 相册里点开一段已下载的录像 | `HistoryVideoPlayerCard` 只播 `Media/` 下文件，不拉远程流 | 只能导出后用外部播放器，无法在 History 内核对内容 | L2 | L2 |
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
| Source Snapshot / 源码快照 | 不经过 Git，把 live dirty worktree 的允许文件逐项安全复制并冻结 | 装箱前给工作台每件零件编号封箱 | r4b 的 live source 与 GRDB 两份 tar.gz | 未提交修改是否进入 DMG 无法证明，构建还可能读到变化中的文件 | L3 | L3 |
| Inside-out Signing / 从内到外签名 | 先签 Host、再生成 checksum package、最后签外层 App | 先封零件袋，再封内箱，最后封外箱 | r4b Host codesign → r1 package → App codesign | 外层封口后修改 Host 会同时破坏 App seal 与 package checksum | L3 | L3 |
| Local-test Unit / 本机测试单元 | DMG 内绑定源码、依赖、工具、App、Host、package 与签名事实的 canonical JSON | 随箱装箱单 | `local-test-unit.json` | 不同构建批次的 App、Host、源码和签名可能被混搭 | L3 | L3 |
| Handoff Tree / 交付树 | 把 DMG、源码、清单、限制与恢复说明放在同一个 exact 目录 | 产品、说明书和质检报告装在同一交付箱 | audit 内 `LinkDigest-0.2.0-local-test/` | Syc 无法核对来源、限制和复现入口 | L3 | L3 |
| Integrated Full Delivery / 集成交付 | 在一份候选中把 App、嵌入 Host/模板、扩展 zip、源码归档、evidence 和总检指南一起按 hash 绑定 | 交付箱里同时有产品、配件、说明书和质检单 | Loop 9 `local_test_release.py` / `local_test_release_check.py` | 分别验证过的零件可能被混搭，Syc 也缺少可执行总检入口 | L3 | L3 |
| Acceptance Guide / 总检指南 | 给人工总检按顺序执行并记录预期、失败反馈和价值指标的方法文档 | 新设备开箱后的检查清单，而不是自动化测试替身 | `docs/ACCEPTANCE_GUIDE.md`，冻结时复制到候选根目录 | 人工测试只留下零散截图，无法判断缺哪一步或如何测量 PRD 价值 | L2 | L3 |
| Dependency / 依赖 | 项目复用的外部标准代码包 | 购买合规标准零件而不是自己炼钢 | 提供类型检查、测试、lint 和运行时 Schema | 需要重复造轮子，或无法使用成熟验证能力 | L2 | L2 |
| Lockfile / 锁文件 | 记录完整依赖树的精确版本和校验信息 | 经过确认的采购清单 | `pnpm-lock.yaml` 让本机和 CI 安装同一套零件 | 不同机器可能得到不同版本和行为 | L3 | L3 |
| JSON Schema | 与编程语言无关、可在运行时执行的数据合同 | Swift 和 TypeScript 共用的一张海关申报表 | `contracts/capture-envelope-v1.schema.json` 是 V0.1 跨语言唯一真相源 | 两端只能靠复制类型维持，字段和失败语义会漂移 | L3 | L3 |
| Type Check / 类型检查 | 不运行程序就检查代码和数据形状能否连接 | 开工前审查施工图 | 编译阶段发现 TypeScript 接口错误 | 许多交接错误要运行到特定路径才暴露 | L3 | L3 |
| Contract Test / 协议测试 | 验证发送方与接收方仍遵守同一版本和失败语义 | 测试插头与插座是否真的匹配 | 覆盖成功、版本不兼容、字段不一致和秘密字段 | 升级一端可能静默破坏另一端 | L3 | L3 |
| Export Projection / 导出投影 | 为拿走一条历史而准备的、只留下用户需要内容的安全快照 | 档案馆给外借文件准备的脱敏复印件 | Loop 2 的 HistoryExportProjection 是 Core renderer 的唯一输入，排除 provider、idempotency、cookie-use 与 raw error | 导出可能带出 Keychain 引用、内部路径或失败细节 | L3 | L3 |
| Renderer / 渲染器 | 把同一份安全数据稳定排版成不同文件格式的组件 | 同一份稿件交给 Markdown、纯文本和 JSON 三种印刷机 | HistoryExportRenderer 在 Core 生成确定性 UTF-8 字节，不选择目录也不写文件 | View 或数据库会掺入格式细节，测试与复用都会变难 | L2 | L3 |
| FileDocument | SwiftUI 交给 macOS 保存面板的文件信封 | 把已经排好版的文件装进可由系统投递的信封 | HistoryExportDocument 只包住 Core 已生成的 Data，FileExporter 决定用户选的保存位置 | Core 会被迫依赖 SwiftUI 或文件系统，取消和权限处理也会混在业务代码里 | L2 | L3 |
| Export Request Identity / 导出请求身份 | 只让仍属于当前配置、当前选择和当前请求的导出结果打开面板的标记 | 换了取件号后旧包裹不能送到新柜台 | HistoryViewModel 为导出复用 generation/request/task 三重检查 | 快速切换记录时，旧记录可能弹出错误内容或覆盖新选择 | L3 | L3 |
| Data Destination Identity / 数据去向身份 | 不含 API Key 的“这次正文会发给谁”的稳定标签 | 快递单上的收件公司、地址和服务类型，但没有保险柜密码 | `DataDestinationIdentity` 由规范化 Base URL、host、模型和 API 模式组成，用于确认和本机记忆 | 用户确认 A 后，设置变化可能悄悄把正文发到 B | L3 | L3 |
| Consent Gate / 发送确认闸门 | 在正文离开本机前先让用户确认去向的门 | 寄件柜台先核对收件地址再放包裹上车 | `AppViewModel` 在创建 `PersistentRunRequest` 前冻结 Capture、intent 和目的地身份；`ConsentStore` 只记忆非敏感身份 | 取消或配置变化时仍可能创建 Run、读取 Keychain 或调用 Provider | L3 | L3 |
| Connection Test / 连接测试 | 用很短的一句话验证当前模型配置能否完成一次协议往返 | 先按门铃听到回应，再搬整箱资料 | 设置页以 `RunIntent.connectionTest` 发出 `Reply with OK.`，只展示安全成功/失败状态 | 用户只能拿真实正文做试错，还会意外产生历史和保存回复 | L2 | L3 |
| Preparation Attempt / 准备尝试 | 把一次点击到 sheet 或 launch 的所有身份放在同一个所有权单元里 | 每次寄件只有一张不能混用的受理单 | `AppViewModel` 同时冻结 token、Capture、intent、identity 和 disclosure | 旧异步结果可能替新点击弹窗、发请求或留下永久禁用状态 | L3 | L3 |
| Owner-checked Defer / 所有者校验释放 | 异步工作结束时只有当前号码牌持有者能清理状态 | 只有领到柜门钥匙的人能归还自己的钥匙 | attempt、connection test 和 configuration mutation 的所有终点 | 迟到 A 可能误清正在工作的 B，或失败后永远不释放 | L3 | L3 |
| Draft Generation / 草稿代际 | 每次设置草稿真实编辑都会变化的非敏感版本号 | 文档每次修改都换一个修订号 | `ProviderSettingsViewModel` 将测试结果绑定 request ID、generation 和 saved identity | A 的测试成功可能显示在未保存的 B 旁边 | L3 | L3 |
| Configuration Revision / 配置修订号 | 配置保存一开始就变化、供授权检查是否跨越保存窗口的计数 | 保险柜换锁时立即更新门口编号 | `ProviderConfigurationService` 在每个 profile/secret await 后复核 | authorize 可能把保存前后的 profile 与 Key 拼在一起 | L3 | L3 |
| Barrier Fake / 闸门测试替身 | 在指定 await 精确暂停并由测试主动放行的假实现 | 在传送带装一道可控闸门观察两批货是否串单 | App、Settings、ProviderConfiguration 和 Consent 并发测试 | 用 sleep 只能猜竞争窗口，绿灯不能证明时序安全 | L2 | L3 |
| Host Package / Host 交付包 | 把 Native Host executable、运行资源、metadata 和 checksums 放在同一可搬迁目录 | 有箱单和封条的完整搬家箱 | Loop 4 的 `LinkDigestNativeHost-0.1.0-macos-arm64/` | 单独复制 Host 可能缺资源，无法知道包是否被篡改 | L3 | L3 |
| Resource Bundle / 资源包 | SwiftPM 随 Core 交付、供 executable 运行时读取的 Schema 与 fixtures 目录 | 搬家箱内不能漏掉的说明书包 | Host 同级 `LinkDigest_LinkDigestCore.bundle` | `Bundle.module` 会失败，或测试时偷偷回退开发机 `.build` | L3 | L3 |
| Package Verifier / 包校验器 | 安装前核对包的树结构、权限、hash、合同、metadata 和机器架构 | 收货时逐件验型号和封条 | `stable_host.py verify-package` | 篡改、缺件、错误 Host 或开发副本可能进入安装 | L3 | L3 |
| Clean-room Install / 隔离初装 | 只允许在带 sentinel 的系统临时 HOME 演练首次安装 | 在模型屋试装，不装修真实住家 | `clean-room-install.sh` 与 `check-stable-package.sh` | 自动测试可能写真实浏览器 manifest 或用户 Application Support | L3 | L3 |
| Receipt Ownership / 收据归属 | 用 canonical receipt 精确声明 LinkDigest 拥有的版本树、文件 hash/mode 和 manifest，而不是按目录名猜归属 | 搬家清单逐件写清“这是我的”，退房时只拿清单内物品 | r2 `receipt-v2.json` 的 `current`、`lineage` 与 `ownedManifests`；v1 receipt 可迁移 | 升级/卸载可能误删用户文件，或无法安全恢复自有文件 | L3 | L3 |
| Cross-process Lock / 跨进程锁 | 让多个协作进程同一时间只能有一个修改 clean-room 安装状态 | 仓库只有一把施工钥匙，拿不到就等待 | session 根预置、永久保留的 `.transaction.lock`；`apply`/`recover` 用非阻塞排他 `flock` | 两次升级、卸载或恢复可能交叉写 receipt、manifest 和版本树 | L3 | L3 |
| Transaction Journal / 事务日志 | 变更前先把完整计划落盘，并在每个可恢复阶段更新的操作流水 | 搬家每移动一箱就签一笔，停电后可从清单继续 | `NativeMessagingHost/transactions/<txid>/journal.json` 与 staged/backups | 崩溃后不知道哪些文件已移动、该回滚还是收尾 | L3 | L3 |
| Crash Recovery / 崩溃恢复 | 进程重启后依据 durable journal 和 live receipt 的 commit point，确定回滚旧状态或完成新状态 | 收银机重启后先查正式账本，未记账撤销、已记账补完收尾 | `transaction_host.py recover`；覆盖 journal/scaffold、SIGKILL 前后窗口 | 半升级状态可能被当成成功、重复安装或误删；只能人工猜测 | L3 | L3 |
| 安装画像 | 一份固定的当前用户范围、浏览器目标和分发候选清单，不读取用户 profile 内容 | 装修前确认房号和施工边界 | `config/native-host-release-policy.json` | Chrome、Brave、Edge 或用户 profile 可能被混写 | L3 | L3 |
| 预检门禁 | 只核对材料是否齐全并列 blocker 的只读入口 | 登机前核验材料，不替你登机 | `release_preflight.py report|plan` | 缺签名、公证或 Team ID 时仍可能凭猜测推进 | L3 | L3 |
| 故障注入 | 故意提供坏路径、坏 receipt 或假签名文字来验证拒绝动作 | 消防演习故意拉响警报 | `release_preflight_check.py` 的离线 fixture | 普通路径通过却无法证明危险输入被拒绝 | L3 | L3 |
| 回滚不变量 | 无论成功或失败都不能被破坏的安全事实 | 演练不能改变真实房屋 | r3 无 mutation 的 preflight 合同 | 失败的检查可能留下真实安装残留 | L3 | L3 |
| Release-unit Binding / 发布单元绑定 | 证明 `.app`、DMG、签名和公证确实属于同一次交付，而不是分别拿来凑材料 | 同一件行李的登机牌、行李牌和封签要能对应 | r3 只报告未验证；r4 授权 spike 才可从真实交付单元验证 | 无关已签名 App 与无关 DMG 可能被误拼成“可发布” | L3 | L3 |
| Evidence Parser / 证据解析器 | 只承认在固定位置、固定格式出现的签名或公证结论 | 只接收盖在指定栏位的原件章，不读纸张角落的相同字样 | r3 的 codesign/spctl pure parser | 文件名、路径或伪造重复文字会被误当成公证/签名 | L3 | L3 |
| Audit Root / 审计构建根 | 一次发布候选唯一允许写入的隔离目录 | 封闭实验台，组装物不能散落到家里 | r4a 的 `/private/tmp/linkdigest-r4a-release.*` | SwiftPM cache 或构建物可能污染 workspace/真实 HOME | L3 | L3 |
| Tree Digest / 目录树指纹 | 对 byte-sorted path/type/mode/size/hash 清单再做的整体 SHA-256 | 按货架位置核对整箱物品的总封条 | r4a App/release-unit verifier | 多出、替换或改权限的文件可能漏过 | L3 | L3 |
| Fail Closed / 证据不足即拒绝 | 路径、格式、身份或绑定不确定时停止而不是猜测通过 | 行李牌看不清就不上飞机 | Schema locator、DMG verifier、target probe | 未知状态会被误报为安全或 release ready | L3 | L3 |
| Directory FD / 目录描述符 | 先打开并锚定一个目录，再相对这个锚点逐级打开子项 | 先拿住楼层钥匙，再逐门核对，不重新相信街道地址 | r4a copier 与真实 target probe 的 `openat + O_NOFOLLOW` | 路径字符串检查后仍可能被 symlink 或并发替换绕过 | L3 | L3 |
| Review Root / 复审根 | 与候选 audit 分开的、一次性保存 tamper fixture、Swift scratch 和 gate result 的目录 | 检验台不能在待检商品箱里钻孔 | `/private/tmp/linkdigest-r4a-review.*` | “验证”本身会修改候选 audit，破坏证据可信度 | L3 | L3 |
| CapturedDocument / 本地捕获文档 | APP 内部保存和运行模型所需的来源、标题、正文与时间，不是浏览器 JSON 合同 | 入库后的货物单，不是跨境海关单 | `LinkDigestCore/CapturedDocument.swift`，由 browser wire 或 manual HTML 映射而来 | 手动链接会被伪装为浏览器来源，或数据库/模型逻辑被 wire 协议绑死 | L3 | L3 |
| WebPageFetcher / 公开网页读取器 | 在明确安全规则内读取一条用户主动提交的公开 HTML 的 Port | 只接收指定地址和尺寸包裹的收发室 | Core port + production `PeerBoundNetworkWebPageFetcher` / `Network.framework`；`URLSessionWebPageFetcher` 是首次复审推翻的 test-only legacy | View 会直接联网，Cookie、redirect 和错误边界无处统一控制 | L3 | L3 |
| Redirect Policy / 重定向策略 | 每次网页跳转前重新检查目标 URL、DNS/IP 结果与 numeric connection endpoint，并拒绝 allowlist 外或 HTTPS 降级目标 | 快递每次转运都重新核对禁运地址 | `PublicWebURLPolicy` 与 PeerBound transport | 初始公网 URL 可能把请求带进内网、保留地址或不安全跳转 | L3 | L3 |
| Storage Write Gate / 存储写入闸门 | 让 Capture 写入串行化，并确保提交失败时不发布成功状态 | 收银成功后才给顾客出小票 | `StorageWriteGate`、`CaptureIngestService` | 并发输入或写盘失败会让 History/UI 显示不存在的记录 | L3 | L3 |
| Peer-bound Transport / 对端绑定传输 | 解析后以 `Network.framework` 连接已校验的 numeric IP，同时保留 HTTPS 原 hostname 的 SNI、`SecPolicyCreateSSL` 和 system trust；trust 禁止未绑定网络补取 | 快递真正交给司机前再核对车牌，不只看调度单 | Loop 5 `PeerBoundNetworkWebPageFetcher` | DNS 之后地址变化、证书名错配或 trust 经旁路补取时，请求可能失去原有边界 | L3 | L2 |
| Fake-IP DNS | 代理把域名临时解析到 `198.18.0.0/15` 等保留地址，再由自己的通道按原域名寻找真实站点 | 先给取件号，再由代理柜台找真实包裹 | Loop 6 `PublicWebURLPolicy.routingDecision` 只把“全 fake-ip 的域名”交给系统代理路径 | 被误当公网会绕过安全语义；被误当普通私网会让代理用户永远无法抓取 | L3 | L3 |
| HTTP CONNECT / 系统代理隧道 | HTTPS 请求先让系统 HTTP(S) 代理按原 hostname 建立隧道，TLS 仍由 App 核对目标网站身份；HTTP 在此路径被拒绝 | 中转站只搬封好的箱子，不能替目标站签收 | `SystemProxyWebPageFetcher` 与 system proxy/VPN 路由 | fake-ip 环境无法连接，代理层错误地替代网站证书校验，或 HTTP 明文失去身份门禁 | L3 | L3 |
| System Proxy Trust Boundary / 系统代理信任边界 | 代理/VPN 会自行解析 hostname，因此本机通过 URL/DNS 的 admission 不等于代理真正连接的 IP | 调度单验过地址，但中转站会自己再选一辆车 | `ProxyAwareWebPageFetcher` 的显式代理和 fake-ip 分支 | 把它误写成 PeerBound numeric peer 校验，会低估 proxy-resolution SSRF 风险 | L3 | L3 |
| Model Preferences / 生成偏好 | 本次总结模板与翻译目标语言的非秘密设置 | 写在工作单上的加工要求，不是保险柜密码 | `ModelPreferences` + UserDefaults；每次 Run 在确认前冻结 | 只能用固定模板/固定英译中，或设置中途变化污染已开始任务 | L3 | L3 |
| App Bundle Icon / 应用包图标 | 放在 macOS `.app/Contents/Resources` 根目录、由 Info.plist 指向的 Finder/Dock 图标 | 装在产品外箱上的识别贴纸，不是箱内 Core 资源包的说明书 | `AppIcon.icns`、`CFBundleIconFile = AppIcon` 与 r4b exact Resources/hash gate | 图标文件可能只留在源码或被签名后补入，导致开发机看似正常、DMG 内没有图标或签名失效 | L2 | L3 |
| Action Entry Gate / 动作入口门禁 | 在 ViewModel 的每个会造成写入、读秘密或外发请求的方法入口执行与 UI 相同的状态检查 | 灰色门牌提示“别进”，门锁才真的拦住所有入口 | `ProviderSettingsViewModel` 的 `save`、`testConnection`、`beginAPIKeyReplacement` 与 `canUseSavedConfiguration` | 测试、快捷路径或已经排队的异步任务可绕过 `.disabled`，覆盖配置、读取旧 Key 或发出旧 intent | L3 | L3 |
| Provider Preset / 厂商预设 | 一组不含秘密、可继续编辑的 Base URL 起始值与帮助文案 | 新设备上的地址簿模板，不是登录凭据 | `ProviderPreset` 与“模型服务”设置页 | 用户要反复手填常见端点，或误以为预设暗含 Key | L2 | L3 |
| Model Catalog / 模型目录 | 从已保存 OpenAI-compatible 端点读取、只保留模型 id 的受限列表 | 只抄写菜单菜名，不保存整张服务商传单 | `ModelCatalogLoading` / `OpenAICompatibleProvider.listModels` | View 直接开新网络面或保留 response body，破坏既有传输/错误边界 | L3 | L3 |
| Output Language / 输出语言 | 同时约束总结最终写作语言和翻译目标语言的非秘密偏好 | 写在同一张加工单上的成品语言要求 | `ModelPreferences.outputLanguage`，旧 `targetLanguage` 兼容读取 | 自定义总结 prompt 会绕开语言选择，或总结/翻译语言各自漂移 | L2 | L3 |
| Temporary Model Override / 临时模型 | 只作用于一条历史重新生成、不会改写保存设置的模型选择 | 临时借用另一台机器完成一单，不搬走原机器 | `PersistentRunRequest.modelOverride` 与 History 重新生成 popover | 为一次试跑改写长期偏好，或实际发送模型与确认卡不一致 | L2 | L3 |
| Tag Normalization / 标签规范化 | 将用户或模型给出的标签 trim、限长并按大小写无关的稳定键去重 | 图书馆先把“Swift”“ swift ”归到同一张索引卡 | `HistoryTagNormalizer`，持久化前与自动标签解析后 | 同一个概念会出现多张标签卡，筛选和上限都不可靠 | L2 | L3 |
| Task-tag Association / 任务标签关联 | 用独立关联表把一个本地 History Task 与多个可复用标签连接 | 书和主题索引卡之间的借阅登记，而不是把主题写死在书封面 | SQLite `tags` / `task_tags`，`Migration002` | 删除 Task 后残留关系、同标签无法复用，或无法做 SQL 交集查询 | L3 | L3 |
| SQL Intersection Filter / SQL 交集筛选 | 多个已选标签必须同时属于同一 Task，且和搜索词一起在数据库查询中收窄结果 | 同时拿“Swift”和“AI”两张索引卡找同一本书 | `GRDBHistoryRepository.historyPage(...filter:)` | 把已加载列表在内存里做并集/误筛，分页和搜索结果会不一致 | L3 | L3 |
| Extension Identity / 扩展技术身份 | 由公开 RSA key 稳定推导、供浏览器和 Native Host 识别扩展的一串固定 ID | 机器刻在金属件上的序列号，不是包装上的商品名 | `config/extension-identity.json`、MV3 manifest key、`config/native-host.json` | 改名或重装会得到不同 ID，Host 无法精确只信任正确扩展 | L2 | L3 |
| Deterministic Artifact / 确定性工件 | 相同输入每次都得到字节完全相同的 zip | 同一份模具压出的两枚印章 | `scripts/extension_identity_artifact.py` 与 `identity-artifact/` | 不能用 hash 判断候选里的扩展是否正是已验证输入 | L2 | L3 |
| Display Name Boundary / 显示名边界 | 把用户看到的名称从技术 ID 和签名身份中分离 | 商品标签可换，机器序列号不动 | `product-display.json`、WXT manifest、`ProductDisplay` | 改名时误改 ID，或不同 UI 出现不一致名称 | L2 | L3 |
| Browser Support Receipt / 浏览器支持收据 | 记录 LinkDigest 已写入的 manifest 内容 hash、嵌入 Host hash 与版本的本机所有权凭证 | 家具搬入时的逐件签收单 | `BrowserSupportInstaller` 的 `receipt-v1.json`，只在用户 Application Support 的 LinkDigest 自有目录 | 卸载或修复只能猜文件名，可能覆盖或删除第三方同名 manifest | L3 | L3 |
| Atomic Publish / 原子发布 | 先写完整临时文件并同步，再用一次目录内发布让读者只见旧完整文件或新完整文件 | 把写好的新通知塞进信封后一次贴到公告栏，不让人读到半张纸 | `BrowserSupportInstaller.atomicWrite` 的 temporary file、`fsync`、link/rename | 浏览器可能读取到半写 JSON，失败时也难以判断该恢复哪一版 | L2 | L3 |
| Frozen Template Binding / 冻结模板绑定 | 让 App 内安装模板、Loop 7 extension handoff 与其 SHA-256 同时对齐 | 三份复印件都要有同一枚封条 | `manifest-integrity.json`、`extension_identity_artifact.py` 与 local-test gate | App 可能安装与候选扩展 ID 不匹配的 origin，即使各自看起来格式正确 | L3 | L3 |
| Capture Platform / 来源平台 | 扩展在采集时根据当前 URL 写入的稳定来源分类，不让桌面端重新猜 URL | 快递在出库时贴上的来源标签 | 浏览器扩展 `platform.ts` → Capture JSON → Swift 合同与 History | 所有来源都变成 generic，图标、筛选和来源标签会失去可靠输入 | L2 | L3 |
| Atomic Local Deployment / 原子本机部署 | 先在隔离目录完成构建与校验，再一次替换日用 App 和扩展目录 | 新家具全部验收后才把旧家具整体换出 | `scripts/build-and-deploy-local.py` | 构建半途失败会留下混合版本，或误写浏览器与用户数据 | L2 | L3 |
| Natural Size / 原始轨道尺寸 | 视频轨道写入文件的原始像素宽高，还没有应用拍摄方向 | 照片冲洗前底片上记录的长和宽 | `AVAssetTrack.naturalSize` 是播放器比例计算的第一个输入 | 竖拍视频可能被误当成横屏，播放器只能靠固定高度猜测 | L3 | L3 |
| Aspect Ratio / 宽高比 | 画面宽与高的固定比例，缩放时两边一起变化 | 相框可以变大变小，但不能只拉宽人物 | `VideoDisplayGeometry` 把 natural size 与 preferred transform 合成显示比例，AVKit 用 `.fit` 播放 | 视频会被裁切、压扁或拉伸，4:3、横屏与竖屏看起来失真 | L3 | L3 |
| On-device Recognition / 本机识别 | 音频只在用户这台设备上交给系统语音模型处理 | 请身边的听写员记录，不把录音寄到外地 | macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`，输入来自本机临时 M4A | 若改走云端，音频会离开本机并新增凭据、网络和数据去向边界 | L3 | L3 |
| Partial Result / 临时转写结果 | 识别尚未结束时持续更新、可被后续语音修正的文字 | 听写员边听边写的草稿，听完整段后才定稿 | `LocalVideoTranscriptionEvent.partial` 驱动 History 视频卡实时文本，`final` 才允许入库 | 长视频只能等到最后才看到反馈，用户难以判断是否仍在工作 | L2 | L3 |
| CaptureEnvelopeV2 / 第二版捕获合同 | 有目标视频时使用的独立 wire 包，保留 V1 页面事实并新增媒体能力描述 | 新版海关单另起表格，不在旧表上涂改 | `capture-envelope-v2.schema.json`、TS/Swift 判别联合与 V2 fixtures | 把新字段塞进 V1 会破坏冻结兼容和跨语言版本判断 | L3 | L3 |
| MediaDescriptor / 媒体能力描述 | 说明当前视频属于哪类、能否移交/转写及为何降级，不等同于永久媒体文件 | 随货能力卡，不是仓库里的货物 | 扩展 `media-detection.ts` → V2 → `CurrentCapture` | APP 会把 blob 当 URL、把 DRM 当普通文件，或用含糊“失败”掩盖边界 | L3 | L3 |
| Ephemeral Playback URL / 临时播放地址 | 只在当前进程交接中短时使用、禁止持久化的 HTTPS 播放地址 | 一次性取货码，用完不抄进账本 | `MediaDescriptor.ephemeralPlaybackURL`；fingerprint/SQLite/export/error 均排除 | 签名地址可能泄漏、过期后误重用，或进入历史与导出 | L3 | L3 |
| Deterministic Media Selection / 确定性媒体选择 | 多视频页按 playing→交互证据→面积→中心距离选择，完全并列就明确歧义 | 监控墙按公开规则选主画面，平局就请人确认 | `selectMediaCandidate` / `detectMediaInPage` 与 `multiple_candidates` | DOM 顺序变化会静默选错视频，正文与媒体身份错配 | L3 | L3 |
| OCR / 图片文字识别 | 从图片像素中找出可复制、可搜索的文字 | 用扫描笔把海报上的字抄到记事本 | `AppleVisionTextRecognizer` 在本机读取正文图片缓存，结果显示在 History 图片文字卡 | 图片能看但不能搜索、复制，也无法把图中关键信息交给总结流程 | L2 | L3 |
| ASR / 语音转文字 | 把音频中的人声识别成文字 | 听写员把录音逐句写下来 | Apple Speech 本机转写；`OpenAICompatibleAudioTranscriber` 把本机提取的 M4A 分片交给 `/audio/transcriptions` | 视频只有画面和声音，不能进入搜索、总结或翻译 | L3 | L3 |
| Negative Cache / 负缓存 | 记住某 host 暂时没有安全可用的 favicon | 快递站记录今天这个地址无人签收 | `WebsiteFaviconCache` 的 `<hash>.miss` 标记，24 小时后允许重试 | 每次打开列表都重复等待同一站点的超时 | L2 | L3 |
| SQLite Aggregation / SQLite 聚合 | 让数据库直接统计导航所需数量，而非先把所有历史加载进 App | 仓库管理员直接报库存 | `GRDBHistoryRepository.navigationCounts()` 的平台、标签与未总结 SQL | 历史越多，切换导航越慢且内存占用越高 | L2 | L3 |
| Selection Set / 选择集 | 用一个集合同时表达 0 条、1 条或多条被选中的 History Task | 文件管理器里被蓝框选中的一组文件 | `HistoryViewModel.selectedTaskIDs` 与 `List(selection:)` | 单个可选 ID 无法支持 Cmd/Shift/Cmd+A，也容易把多条能力误当成单条能力 | L2 | L3 |
| Task Ownership / 任务归属 | 长任务启动时记住它服务的 Task，让进度和结果始终回到该 Task，而不是跟随当前界面选择 | 洗衣单写着衣物主人的名字，顾客走到别处也不会领错 | `HistoryViewModel` 的转写与 OCR owner TaskID | 切换条目或重建视图会取消任务、清空文本，或把结果显示到另一条记录 | L3 | L3 |
| Batch Delete Transaction / 批量删除事务 | 一组删除在同一个数据库事务内提交；任一步抛错时整组回滚 | 搬家清单全部核对后一次交钥匙，中途出错就原样退回 | `HistoryRepository.deleteTasks` 与 `GRDBHistoryRepository` 的单次 `database.write` | 可能出现主记录删了但媒体、标签、快照或 Run 留成孤儿，UI 还误报全部成功 | L3 | L3 |
| Typography Token / 排版常量 | 多个阅读区域共同引用的字号和行距常量 | 同一本书所有章节共用一套排版尺 | `MarkdownPresentation.bodyFontSize/bodyLineSpacing`，供最终正文、流式转写和 OCR 结果复用 | 流式文字会比最终正文忽大忽小，后续修改也容易只改一处 | L2 | L3 |
| Design Token / 设计令牌 | 集中保存背景、文字、边线和强调色的命名色卡 | 全屋装修共用一张带编号的油漆表 | `AppearanceTheme.tokens` 为系统、浅色 Claude 风格和深色主题统一交接颜色 | 每个视图会自行写近似颜色，主题切换时出现漏网和色彩漂移 | L2 | L2 |
| WKWebView | App 内可加载并渲染网页的系统组件；本轮只作为不可见、一次性的公众号读取器 | 临时请来的网页抄录员，用完立即离场 | `WeChatWKWebViewCaptureService`，位于手动 URL 输入与现有 `CaptureIngestService` 之间 | 只能读取服务器原始 HTML，可能拿不到页面 JS 补全后的正文 | L3 | L3 |
| Navigation Allowlist / 导航允许清单 | 每次页面跳转前都重新核对协议与目标 host，只允许明确列出的地址 | 每过一道门都重新查一次访客名单 | `WeChatWebCapturePolicy` 同时检查初始 URL、navigation action/response 和最终 URL | 页面可把隐藏 WebView 带到任意网站，扩大远程内容执行边界 | L3 | L3 |
| Non-persistent Website Data Store / 非持久化网页数据仓 | WebView 会话结束后不保留 Cookie、缓存等站点状态的临时存储 | 访客使用一次性储物柜，离开即清空 | 每次 WebView 配置的 `WKWebsiteDataStore.nonPersistent()` | 多次抓取可能共享登录或追踪状态，触碰其它会话数据 | L2 | L3 |
| Return Shape Validation / 返回形状校验 | 把页面 JS 返回值当不可信包裹，只复制类型正确的 title/text 并限制总长度 | 收货员只收清单上的两件货，多余物品原样丢弃 | `WeChatWebCapturePolicy.validateJavaScriptResult`，在页面与 `CapturedDocument` 之间 | 异常字段、错误类型或超大正文可能进入入库流程 | L3 | L3 |
| Fake-IP | 代理软件为域名临时分配的保留网段地址；它不是图片服务器的真实公网地址 | 前台发的取餐号，只有店内叫号系统知道对应哪桌 | `PublicWebURLPolicy` 识别 `198.18.0.0/15`，`ProxyAwareWebPageFetcher` 决定请求交给哪条网络通道 | App 把取餐号当真实门牌直连，网页在浏览器能开，图片下载却报网络失败 | L2 | L3 |
| Hostname Transport / 保留域名的系统网络通道 | 仍用原始 HTTPS 域名发请求，让 macOS 的系统代理或 Network Extension/TUN 接管解析和连接 | 把写着完整收件地址的包裹交给本地快递网点，而不是自己按临时编号找路 | `ProxyAwareWebPageFetcher` 对 fake-IP 判定优先使用 `SystemProxyWebPageFetcher` | 只绑定数字 fake-IP 会绕开 TUN 的域名接管，Medium CDN 等资源无法落盘 | L3 | L3 |
| Image Cache Backfill / 图片缓存补抓 | 历史正文已有远程图片引用、但本地文件缺失时，在打开详情时补下载一次并刷新展示 | 书目已经登记，发现插图页漏装后只补装缺页，不重抄整本书 | `HistoryViewModel.backfillRemoteImagesIfNeeded` → `GitHubREADMEImageCache` | 短时网络失败会永久留下空白图片，升级网络修复后旧记录仍无法自愈 | L2 | L3 |

## 更新规则

- 新名词第一次进入开发任务时再添加，不提前堆满百科全书。
- `当前覆盖` 只在项目已经交付对应讲解或验证证据后提升，不以 Syc 答题为条件。
- 同一名词的解释如果越来越复杂，应优先改得更易懂，而不是继续添加术语。
- 架构决策写入 Project Brain；这里只解释词义和项目位置。
