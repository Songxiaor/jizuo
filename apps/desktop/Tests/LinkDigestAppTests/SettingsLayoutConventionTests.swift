import XCTest
import LinkDigestCore

/// 设置页的跨页排版约定：相关的简单项合并进 `SettingsRowGroup`，复杂项仍走
/// `SettingsCard`；说明跟着控件走，不堆回卡片外的 footer。
///
/// 改这套之前，设置项普遍写成「Section header + 控件行 + 卡片外的长 footer」，
/// 全部设置页加起来 17 处。两个后果：说明离它控制的控件隔着一整块间距，读的时候
/// 对不上号；footer 一律展开，四五行密字把页面撑满，控件密度极低。
///
/// 行式重建之后，退化路径变成两种：一是又把简单项拆回「一项一张卡」，二是说明
/// 重新长成常驻 footer。这两种都不报错、不崩溃，所以必须由测试守住。
final class SettingsLayoutConventionTests: XCTestCase {
  private static let pages = [
    "ProviderSettingsView",
    "MediaStorageSettingsView",
    "BrowserSupportSettingsView",
    "SiteLoginSettingsView",
  ]

  /// `ProviderSettingsView` 的模型编辑子流程里仍有三处 footer，装的是**动态状态**
  /// （服务商文档提示、模型目录状态、测试连接结果），不是静态说明——状态紧贴控件
  /// 本来就合理，所以按页给出允许上限而不是一刀切归零。
  private static let allowedFooters = [
    "ProviderSettingsView": 3,
    "MediaStorageSettingsView": 0,
    "BrowserSupportSettingsView": 0,
    "SiteLoginSettingsView": 0,
  ]

  /// 去掉注释后的代码：本仓库把注释当设计文档写，旧文案和旧写法经常被留在注释里
  /// 解释「为什么改」。守住「界面上不再出现这句话」的断言必须只看代码，否则
  /// 注释一解释就报假红，最后只能把注释删掉，等于用测试惩罚写清楚。
  ///
  /// 行尾注释按 `//` 切，但跳过 `https://` 这种前面是冒号的假注释。
  private func codeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
      guard !trimmed.hasPrefix("//") else { return "" }
      var searchStart = line.startIndex
      while let range = line.range(of: "//", range: searchStart..<line.endIndex) {
        if range.lowerBound > line.startIndex, line[line.index(before: range.lowerBound)] == ":" {
          searchStart = range.upperBound
          continue
        }
        return String(line[line.startIndex..<range.lowerBound])
      }
      return String(line)
    }.joined(separator: "\n")
  }

  private func source(_ name: String) throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LinkDigestApp/\(name).swift"),
      encoding: .utf8)
  }

  private func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var index = text.startIndex
    while let range = text.range(of: needle, range: index..<text.endIndex) {
      count += 1
      index = range.upperBound
    }
    return count
  }

  func testSettingsPagesDoNotGrowNewFooterExplanations() throws {
    for page in Self.pages {
      let text = try source(page)
      // 设置页从 grouped Form 迁移到自绘卡之后，footer 不再是 Section 的
      // `} footer: { … }` 尾随闭包，而是 `SettingsCardGroup(footer:)` 的
      // 一个 String 参数——两种写法的语义一致（卡片外的补充说明），这里换成
      // 匹配新语法，允许上限不变。
      let footers = occurrences(of: "footer:", in: text)
      let allowed = Self.allowedFooters[page] ?? 0
      XCTAssertLessThanOrEqual(
        footers, allowed,
        "\(page) 的 footer 从 \(allowed) 涨到了 \(footers)。静态说明要放进 SettingsCard，"
          + "只有跟着状态变的提示才留在 footer")
    }
  }

  /// 卡片 / 行组构件必须是同一份。三处各写一份必然漂移，而漂移不报错。
  func testAllSettingsPagesUseTheSharedCard() throws {
    for page in Self.pages where page != "SiteLoginSettingsView" {
      let text = try source(page)
      XCTAssertTrue(
        text.contains("SettingsCard(") || text.contains("settingCard("),
        "\(page) 没有使用共享的设置卡片构件")
    }
    XCTAssertTrue(
      try source("ProviderSettingsView").contains("SettingsRowGroup"),
      "生成偏好 / 实验室的简单项要收进共享行组，不能再各写一套")
    XCTAssertTrue(
      try source("MediaStorageSettingsView").contains("SettingsRowGroup"),
      "视频存储的本地保存三项要收进共享行组")

    let shared = try source("SettingsCard")
    XCTAssertTrue(shared.contains("struct SettingsCard"))
    XCTAssertTrue(shared.contains("struct SettingsRow"))
    XCTAssertTrue(shared.contains("struct SettingsRowGroup"))
    XCTAssertTrue(shared.contains("struct SettingsPageHeader"))
    // 详细说明从 popover 改成了卡内可展开可收起的区域——同一张卡里点开就在原地
    // 长出一段，不用再在悬浮层里读。仍然是「按需展开」，不是常驻 footer。
    XCTAssertTrue(
      shared.contains("if isDetailsPresented, let details {"),
      "详细说明必须留在按需展开的卡内区域里，不能重新长成常驻 footer")
    XCTAssertFalse(
      shared.contains(".popover(isPresented: $isDetailsPresented"),
      "详细说明改成卡内展开之后，popover 不该回来")
    XCTAssertTrue(
      shared.contains("DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)"),
      "展开/收起要走统一的动效令牌，并遵守「减弱动态效果」")
    XCTAssertTrue(shared.contains("Image(systemName: \"info.circle\")"))
    XCTAssertFalse(shared.contains("DisclosureGroup(\"了解更多\")"))
  }

  /// 控件自带逐项解释时，卡片说明必须前置，否则读成倒的。
  ///
  /// 一组单选里每项下面都有一句话；说明再放控件后面，读者会先读到某一项的解释，
  /// 才读到整张卡在讲什么。
  func testChoiceCardsPlaceSummaryAboveTheOptions() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertEqual(
      occurrences(of: "summaryPlacement: .aboveControl", in: media), 2,
      "「历史在线播放」和「B 站清晰度」两张卡的控件都自带逐项解释，说明必须前置")

    let shared = try source("SettingsCard")
    XCTAssertTrue(
      shared.contains("case aboveControl"),
      "卡片必须支持说明前置，否则这类卡只能各自绕开构件重写一遍")
  }

  /// 单选要能在选之前比较，选择钮要贴着文字。
  func testChoiceListsShowEveryOptionsExplanation() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertTrue(
      media.contains("SettingsChoiceList("),
      "inline Picker 会把单选钮甩到行最右端，且只显示选中项的解释")
    XCTAssertFalse(
      media.contains(".pickerStyle(.inline)"),
      "inline Picker 的写法回来了，就又要点一次才能看到另一项在说什么")

    let shared = try source("SettingsCard")
    XCTAssertTrue(shared.contains("struct SettingsChoiceList"))
    XCTAssertTrue(
      shared.contains("Text(choice.explanation)"),
      "每一项都要带自己的解释，不能只显示选中的那条")
  }

  /// 控件不能横跨整个详情区。
  ///
  /// Form 行会撑满整行，于是 Toggle 的开关、LabeledContent 的值、Picker 的下拉
  /// 全被推到最右端，和自己的标题隔着大半个窗口，看的时候要来回扫。卡片默认给
  /// 控件设上限宽度；`full` 只留给本来就需要整行的控件。
  func testCardsCapControlWidthByDefault() throws {
    let shared = try source("SettingsCard")
    XCTAssertTrue(
      shared.contains("var controlWidth: SettingsControlWidth = .compact"),
      "默认必须是收窄的；默认放开等于这个问题没修")
    XCTAssertTrue(
      shared.contains("frame(maxWidth: controlWidth.maximum, alignment: .leading)"),
      "上限宽度要真的作用到控件上")
    XCTAssertTrue(
      shared.contains("case .compact: 440"),
      "收窄档要有具体数值，不能是 .infinity 换个名字")
  }

  /// 上一条只解决了一半：控件不再横跨整行，但还是停在 440pt 的右边缘。
  ///
  /// `compact` 管的是控件能占多宽，管不了 `Toggle`／`LabeledContent` 在这个宽度里
  /// 把自己的开关推向哪边——它们一律推到右边缘。于是开关停在卡片正中偏右，
  /// 既不贴着标签，也不与任何东西对齐，比横跨整行更难读。
  ///
  /// 一张卡只有一个主控件时，答案是让它和卡片标题同一行、右对齐：
  /// 整页卡片的控件因此排成一列。这也顺带消掉「翻译模型 / 翻译使用不同模型」这类重复标签。
  ///
  /// 文件里现在有多个 `var body`（SettingsRow、页头、行组），不能再取「第一个
  /// body 的前 400 字」——那会切到 SettingsRow 而不是 SettingsCard。
  func testPrimaryControlCanSitOnTheTitleRow() throws {
    let shared = try source("SettingsCard")
    XCTAssertTrue(
      shared.contains("var titleAccessory: () -> TitleAccessory"),
      "卡片要能把主控件放到标题行")
    guard let start = shared.range(of: "struct SettingsCard<Control: View, TitleAccessory: View>: View") else {
      return XCTFail("SettingsCard 的类型声明不见了")
    }
    let card = String(shared[start.lowerBound...].prefix(6000))
    // 字体修饰符写成正则而不是字面量：这条断言被 `.font(.headline)` →
    // `.themedFont(.headline)`（主题带上界面字体那一轮）打红过一次，而布局
    // 一个像素都没动。这里要锁的不变量是「标题用 headline 字号、和主控件同行」，
    // 不是标题走的哪一套字体管线。
    XCTAssertTrue(
      card.range(of: #"Text\(title\)\.\w*[Ff]ont\(\.headline\)"#, options: .regularExpression) != nil
        && card.contains("titleAccessory()"),
      "标题和主控件要在同一行，中间靠 Spacer 撑开成右对齐一列")
    XCTAssertTrue(
      card.contains("Spacer(minLength:"),
      "靠 Spacer 右对齐，而不是给控件写死一个偏移量")
  }

  /// 单选各项的解释必须写清「你要多做什么」和「代价落在哪」，不能只堆形容词。
  ///
  /// 原来写的是「更省流量，也更可预期」，用户看完的反馈是「主要是没清楚两个
  /// 功能的区别」——那是文案没写好，不是他没读。形容词不构成可比较的信息。
  func testRestoreModeExplanationsStateBehaviourAndCost() throws {
    let automatic = SessionMediaRestoreMode.automatic.settingsExplanation
    let manual = SessionMediaRestoreMode.manual.settingsExplanation

    // 自动：说清代价按「每打开一条」计，并点名最重的那个平台。
    XCTAssertTrue(automatic.contains("每打开一条"), "自动的代价要写成可计量的频次")
    XCTAssertTrue(automatic.contains("抖音"), "平台间开销差很多，最重的那个要点名")

    // 手动：说清多做的那个动作，以及不发请求的范围。
    XCTAssertTrue(manual.contains("重新获取播放"), "手动要写明多点的是哪个按钮")
    XCTAssertTrue(manual.contains("路过的不发"), "要写明什么情况下不发请求")

    for text in [automatic, manual] {
      XCTAssertFalse(
        text.contains("更省流量") || text.contains("更可预期"),
        "形容词不构成可比较的信息")
    }
  }

  /// 跨页依赖要给出去处，而不是只说一句「依赖某某」。
  func testCrossPageDependencyPointsSomewhere() throws {
    let media = try source("MediaStorageSettingsView")
    XCTAssertTrue(
      media.contains("SettingsCrossReference("),
      "B 站清晰度依赖站点登录，必须指明去哪一页")
    XCTAssertTrue(media.contains("站点登录 → B 站"))
  }

  // MARK: - 危险动作

  /// 设置窗口里会删东西、抹记录、把设置推回默认的那几个按钮。
  ///
  /// 它们和「重新检查」「了解更多」长得一样低调，误点的代价却完全不同：登录被抹掉、
  /// 磁盘上的视频消失、自己写了很久的提示词被覆盖。少一个确认框不报错、不崩溃，
  /// 只有用户点下去之后才发现，所以在这里逐个钉住。
  private static let destructiveActions: [(page: String, confirmIdentifier: String)] = [
    ("SiteLoginSettingsView", "site-login-clear-confirm"),
    ("MediaStorageSettingsView", "media-storage-delete-orphans-confirm"),
    ("MediaStorageSettingsView", "media-storage-default-confirm"),
    ("ProviderSettingsView", "revoke-remembered-consents-confirm"),
    ("ProviderSettingsView", "reset-summary-prompt-confirm"),
    ("BrowserSupportSettingsView", "browser-support-disconnect-confirm"),
  ]

  func testDestructiveSettingsActionsAskBeforeActing() throws {
    for action in Self.destructiveActions {
      let text = try source(action.page)
      guard let range = text.range(of: action.confirmIdentifier) else {
        XCTFail("\(action.page) 里没有 \(action.confirmIdentifier)：这个危险动作的确认框不见了")
        continue
      }
      // 确认按钮必须是 destructive 角色：macOS 会把它画成红字并放在惯例位置，
      // 用户靠这个区分「这一下会删东西」和「这一下只是关掉」。
      let before = String(text[text.startIndex..<range.lowerBound].suffix(400))
      XCTAssertTrue(
        before.contains("role: .destructive"),
        "\(action.confirmIdentifier) 不是 destructive 角色，看起来和普通确认一样")
      XCTAssertTrue(
        text.contains(".confirmationDialog("),
        "\(action.page) 没有确认框")
    }
  }

  /// 删除 / 清除 / 重置类按钮一律用主题的危险色，不能和「了解更多」同一个语气。
  ///
  /// 走 `appDestructive`（文字按钮 + 危险色）而不是各页各写一个红色：颜色本身要跟着
  /// 主题走，暖褐主题和高对比主题的红不是同一个红。
  func testDestructiveSettingsButtonsCarryTheDangerColour() throws {
    let minimum = [
      "MediaStorageSettingsView": 2,  // 删除这 N 个文件、恢复默认
      "ProviderSettingsView": 2,      // 清除授权记录、重置为默认提示词
      "BrowserSupportSettingsView": 1,  // 断开
      "KnowledgeVaultSettingsView": 1,  // 清除知识库文件夹
    ]
    for (page, count) in minimum {
      let text = try source(page)
      XCTAssertGreaterThanOrEqual(
        occurrences(of: ".appDestructive(", in: text), count,
        "\(page) 的删除/清除/重置按钮没有全部走危险色")
    }
    XCTAssertTrue(
      try source("AppButtonStyles").contains("case destructive"),
      "危险动作要有自己的按钮层级，不能各页各写一个红色")
  }

  // MARK: - 文案

  /// 用户文案里不出现工程词。
  ///
  /// 这类词不报错，只是让人读不懂自己在设置什么：`Base URL` 是「服务地址」，
  /// `API Key` 是「密钥」，「孤儿文件」是「没被任何内容用到的视频」。
  /// 只扫字符串字面量，注释里解释设计时提到这些词是正常的。
  func testSettingsCopyIsFreeOfEngineeringJargon() throws {
    let pages = [
      "ProviderSettingsView", "ProviderSettingsViewModel", "UISettingsPresentation",
      "SettingsCard", "BrowserSupportSettingsView", "BrowserSupportViewModel",
      "SiteLoginSettingsView", "MCPSettingsView", "KnowledgeVaultSettingsView",
      "MediaStorageSettingsView", "MediaStorageSettingsViewModel",
      "CompanionNoteSyncSettingsView", "V02ErrorPresentation",
    ]
    let banned = [
      "reasoning_effort", "SQLite", "vacuum", "schema", "WAL",
      "併入", "孤儿", "jizuo_", "工件", "Base URL", "API Key",
    ]
    for page in pages {
      for literal in userFacingLiterals(in: try source(page)) {
        for word in banned {
          XCTAssertFalse(
            literal.contains(word),
            "\(page) 的用户文案里还留着工程词「\(word)」：\(literal)")
        }
      }
    }
  }

  /// 「MCP 连接」对用户来说是三个字母加两个汉字，说不出它能干什么。
  func testAgentIntegrationPageIsNamedForWhatItDoes() throws {
    XCTAssertTrue(
      try source("ProviderSettingsView").contains("case .mcp: \"AI 助手接入\""),
      "侧栏分类名要说清这一页是给谁用的")
    let page = try source("MCPSettingsView")
    XCTAssertTrue(page.contains("title: \"AI 助手接入\""))
    XCTAssertTrue(
      page.contains("Claude Code"),
      "页头要举出用户认得的助手，否则「AI 助手」仍然是个抽象词")
    XCTAssertFalse(
      page.contains("jizuo_status"),
      "函数名不该出现在正文里，用户没法把它和界面上的任何东西对上")
  }

  /// 「装没装扩展」和「收没收到内容」是两件事，页面上不能互相打脸。
  ///
  /// 改之前：浏览器那一行写「最近同步 14:03」，同一屏下面的接收状态行写
  /// 「还没收到过同步」——两句读的根本不是一个数据源（一个是落盘的送达记录，
  /// 一个只记本次运行），但用户看到的就是两句矛盾的话。
  func testBrowserSupportNeverContradictsItselfAboutDeliveries() throws {
    let code = codeOnly(try source("BrowserSupportSettingsView"))
    XCTAssertTrue(code.contains("最近一次收到内容"), "送达事实由浏览器那一行报")
    XCTAssertTrue(code.contains("还没收到过内容"))
    XCTAssertFalse(
      code.contains("还没收到过同步"),
      "接收状态行不该再报「收没收到过」——它读的是只活一次运行的计时")
    XCTAssertTrue(
      code.contains("接收服务已就绪"),
      "接收状态行只回答「现在能不能收」")
  }

  /// 说不清的浏览器状态必须带着原因和一个真能点的下一步。
  ///
  /// 「安装记录无效」「缺少安装工件」这两行原来既没有解释也没有按钮——用户读完
  /// 只知道坏了，不知道坏在哪、也不知道该干什么。
  func testUnresolvedBrowserStatesOfferAnExplanationAndAnAction() throws {
    let code = codeOnly(try source("BrowserSupportSettingsView"))
    XCTAssertTrue(code.contains("private func unresolvedStateAdvice("))
    XCTAssertTrue(code.contains("browser-support-advice-action-"), "说明旁边要有一个能点的按钮")
    for stale in ["安装记录无效", "缺少安装工件"] {
      XCTAssertFalse(code.contains(stale), "「\(stale)」说的是内部状态，用户看不懂")
    }
  }

  /// 字体预览不能用写死的假数据冒充真实状态。
  ///
  /// 「待总结 149」长得和主界面侧栏的计数一模一样，用户会当成自己真有 149 条没总结，
  /// 而那个数字是死的、永远不变。预览要验证的是字形在 10pt 上立不立得住，
  /// 中性示例词同样能验证。
  func testAppearancePreviewUsesNeutralSampleText() throws {
    let code = codeOnly(try source("ProviderSettingsView"))
    XCTAssertFalse(code.contains("待总结 149"), "预览里的假计数会被当成真实状态读")
    XCTAssertTrue(code.contains("示例标题"))
  }

  /// 设置页标题跟随系统字号。
  ///
  /// 写死 18pt 时，把界面字号调大之后正文涨了、页头没涨，标题反而比它下面的说明还小。
  func testSettingsPageTitleScalesWithTheUsersFontSize() throws {
    let shared = codeOnly(try source("SettingsCard"))
    XCTAssertFalse(
      shared.contains(".font(.system(size: 18, weight: .semibold))"),
      "页头标题写死字号，放大字号后会比正文还小")
    XCTAssertTrue(shared.contains(".themedFont(.title3, weight: .semibold)"))
  }

  /// 主题色不能被 `Color.accentColor` 顶掉。
  ///
  /// `Color.accentColor` 读的是 App 级强调色（默认系统蓝），不受窗口根部
  /// `.tint(theme.accent)` 影响——于是暖褐主题下的单选钮、用途徽标、管线编号
  /// 全是蓝的，和整页格格不入。
  func testSettingsControlsFollowTheThemeAccentNotTheSystemBlue() throws {
    for page in ["ProviderSettingsView", "SettingsCard"] {
      let code = codeOnly(try source(page))
      XCTAssertEqual(
        occurrences(of: "Color.accentColor", in: code), 0,
        "\(page) 里还有控件用着 App 级强调色（默认系统蓝），换主题时不会跟着变")
    }
  }

  /// 只取字符串字面量：注释里为了解释设计而提到工程词是正常的，界面上出现才是问题。
  ///
  /// 顺带排掉两类不是文案的字面量：`accessibilityIdentifier` 那种全小写连字符的
  /// 标识，和 http(s) 开头的网址。
  private func userFacingLiterals(in source: String) -> [String] {
    var literals: [String] = []
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
      var rest = Substring(line)
      while let open = rest.firstIndex(of: "\"") {
        let afterOpen = rest.index(after: open)
        guard afterOpen < rest.endIndex, let close = rest[afterOpen...].firstIndex(of: "\"") else { break }
        let literal = String(rest[afterOpen..<close])
        rest = rest[rest.index(after: close)...]
        guard !literal.isEmpty, !literal.hasPrefix("http") else { continue }
        // 纯 ascii 小写连字符 = 无障碍标识 / 偏好键，不是给人读的文案。
        let isIdentifier = literal.allSatisfy {
          $0.isLowercase && $0.isASCII || $0 == "-" || $0 == "." || $0.isNumber
        }
        if isIdentifier { continue }
        literals.append(literal)
      }
    }
    return literals
  }
}
