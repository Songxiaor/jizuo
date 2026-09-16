import Foundation

/// 还在成型中的功能。
///
/// 默认全关。放在这里的东西有一个共同点:**它们的数据模型还会变**。
/// 提前开给所有人,等于给自己攒下一堆将来必须迁移的数据,
/// 而那些数据在功能成型前几乎没有价值。
///
/// 开关只控制入口是否出现,不删数据——自己打开测试过的人,
/// 下个版本回来时东西还在。
enum ExperimentalFeatures {
  /// 这一版对外提不提供工作台。
  ///
  /// 0.2.0 定为**不提供**:工作台的展示结构本身还要重做——阶段是写死的
  /// 枚举、选题板和方法库和创作列表挤在同一栏,而这两件事都要改。
  /// 现在发出去,收到的会是关于一个我们已经决定要推翻的形态的反馈,
  /// 那种反馈既帮不上忙,又要用户白花一次注意力。
  ///
  /// 只关**入口**:代码、数据和开关本身都留着,改回 true 就全部恢复。
  ///
  /// 0.2.1 收紧了一次:原来「已经打开过的人侧边栏照常有工作台」,结果是
  /// 开发机上它一直在,连带每天 12 点的选题定时也照跑,而这一版根本不打算
  /// 让任何人用这个形态。这一版的语义改成**这一版不提供就是谁都不显示**,
  /// 包括开过开关的人——`workbenchKey` 的值和全部数据仍然留着,
  /// 改回 true 的当天,开过的人还是原样回来。
  static let isOfferedToUsers = false

  /// 这一版对外提不提供「手机同步」。
  ///
  /// 0.2.x 定为**不提供**:同步本身还没做完,而它牵扯的是用户最私密的一批数据——
  /// 笔记正文会被写进 iCloud 私有库。
  ///
  /// 关的是两件事,缺一不可:
  ///
  /// 1. 设置里那一栏不出现。这一条原来是靠 `case .companionSync: false` 这个
  ///    裸字面量做到的——能用,但读代码的人看不出它是「这一版故意关的」还是
  ///    「谁调试时随手改的」,也没有任何地方拦得住第二处忘记判断。
  /// 2. **启动时不自动同步**。这一条原来根本没做:入口藏起来了,启动路径却仍然
  ///    照常调 `companionNoteSync.synchronize()`,而协调器的 enabled 默认值来自
  ///    `CloudKitCapability.isContainerEntitled()`——也就是说,哪天换成带 iCloud
  ///    能力的正式签名,笔记就会在用户毫不知情的情况下开始往 iCloud 上传。
  ///    一个「这一版不提供」的功能,不该由签名方式来决定它跑不跑。
  ///
  /// 收成一个命名常量,两处都读它:关的是同一件事,就只能有一个开关。
  static let isCompanionSyncOffered = false

  /// 手机同步:把「我的笔记」和链接卡经 iCloud 私有库同步到 iPhone。
  ///
  /// 默认关闭,而且**默认值就是 false,不看签名能力**。原来的默认值是
  /// `CloudKitCapability.isContainerEntitled()`——「这台机器的签名支持 iCloud」
  /// 被当成了「用户想同步」,而这两件事毫无关系。上传用户数据这种事只能由
  /// 用户自己按下,不能由构建配置替他决定。
  static let companionSyncKey = "experimental.companionSync.enabled"

  /// 启动时到底要不要同步:这一版对外提供,**并且**用户自己在设置里打开过。
  ///
  /// 与 `isWorkbenchVisible` 同一个形状、同一个理由:两处判断各写一遍 `&&`,
  /// 漏掉一处的表现是「设置里看不到手机同步,后台却在往 iCloud 传东西」——
  /// 那种 bug 自己不会喊。
  static func isCompanionSyncEnabled(userEnabled: Bool) -> Bool {
    isCompanionSyncOffered && userEnabled
  }

  /// 读用户偏好。没设过一律 false——`UserDefaults.bool(forKey:)` 对缺失键返回
  /// false,正是这里想要的默认。
  static func isCompanionSyncEnabled(defaults: UserDefaults = .standard) -> Bool {
    isCompanionSyncEnabled(userEnabled: defaults.bool(forKey: companionSyncKey))
  }

  /// 入口到底显不显示:这一版对外提供,**并且**用户自己打开过。
  ///
  /// 收口成一个函数而不是让各视图各写一遍 `&&`:侧边栏、中间列、详情列和
  /// 右键菜单是四处判断,漏掉一处的表现是「侧边栏没有工作台,右键却还能
  /// 加入工作台」,那种 bug 自己不会喊。
  static func isWorkbenchVisible(userEnabled: Bool) -> Bool {
    isOfferedToUsers && userEnabled
  }

  /// 工作台:一件创作从灵感到成品的加工区。
  ///
  /// 默认关闭的理由:它的数据模型还会变(阶段要从枚举改成用户可定义的
  /// 取值,选题候选和创作可能合并成同一张表)。提前开给所有人,
  /// 等于给自己攒下一堆将来必须迁移的数据。
  static let workbenchKey = "experimental.workbench.enabled"

  /// 爆款实验室:发布前盲预测，几天后拿真实结果对照。
  ///
  /// 单独一个开关而不是跟着工作台走:它有自己的门槛(要攒够几次结果
  /// 才有意义)，而且不是每个人都在意传播数据——写给自己看的人打开它
  /// 只会多一层噪音。
  ///
  /// 关掉时模块从界面消失，但**数据保留不删**:攒了三个月的预测记录，
  /// 因为手滑关了一次开关就没了，是不可接受的。
  static let hitLabKey = "experimental.hitLab.enabled"
}
