import LinkDigestCore
import SwiftUI

/// Dedicated settings page for App-owned platform login sessions used by
/// high-quality streaming recovery. Kept separate from “视频存储” so disk
/// preferences do not grow into a multi-site account hub.
///
/// 排版约定：**三个站点收进一张自绘行组卡，一站一行。**
///
/// 原来一个站点独占一张大卡，卡内容却稀薄（一行状态 + 一行按钮），三张卡叠起来
/// 全是空白，真正有用的信息密度很低。现在改成系统设置那种「行组卡」的样子：
/// 图标 + 站名 + 一句 caption 说明差异，状态徽标和操作贴右边缘；诊断细节
/// （cookie 读取记录、UID、B 站的校验会话）收进每行自己的 ⓘ 展开区，默认不占地方。
///
/// 这一页仍然整体走 `ScrollView + LazyVStack` 手排，不是 `Form`：行组卡自带主题
/// 卡面（`SettingsThemedCardChrome`），放进 grouped Form 的 Section 会被 Section
/// 自己的默认容器卡再包一层，叠成「卡中卡」。
///
/// 文案约定：**每行一句 caption 说清「登录起什么作用」，技术细节收进 ⓘ。**
///
/// 原来的分组标题（「登录可选：影响清晰度」「登录才能抓到正文」）说的就是这句话，
/// 合并成一张卡之后不再有单独的分组标题槎位，这句话改由每行自己的 caption 携带，
/// 信息没有丢，只是从卡外的组标题挪进了卡内的行标题下面。
///
/// 抖音是这一组里唯一的例外——同在「登录才能抓到正文」，但它登录了手动粘链接
/// 也常失败，所以它的 caption 比另外两行多带一句「建议用扩展抓」。
struct SiteLoginSettingsView: View {
  @Environment(\.appTheme) private var appTheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject var browserSupport: BrowserSupportViewModel
  var openBrowserSupport: () -> Void
  @State private var browserOpenError: String?
  @ObservedObject private var xSession = SiteSessionController.x
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  /// 哪个站点的登录窗口正开着。用 profile 的 platform 当身份，避免再加一堆布尔量。
  @State private var presentedLogin: SiteSessionPlatform?
  /// 每行自己的 ⓘ 展开区独立收起/展开——点开 B 站的校验会话不该带着关掉
  /// 小红书那行的诊断细节。
  @State private var expandedDetailSites: Set<SiteSessionPlatform> = []

  // 这一页的行组卡自带主题卡面（`SettingsThemedCardChrome`：底色 + hairline
  // 描边 + 浅色主题下的轻投影），原来却又挂在 grouped Form 的 Section 里——
  // macOS 给 Section 画的默认容器卡不受行内 `.listRowBackground` 控制，两层卡
  // 叠在一起就发灰发闷。这页每一屏都是自绘卡面，本来就不依赖 Form 的行为
  // （分组标题、跨 Section 的系统分隔线都没用上），所以整页从 `Form` 换成
  // `ScrollView + LazyVStack` 手排，卡面只画这一层。
  //
  // `ScrollView` 本身没有画布底色：这里显式补上 `theme.canvas`（非原生主题），
  // 否则卡和窗口背景融成一片，看不出分层。原生（系统）主题交还系统 material，
  // 不再自己画。
  //
  // `.settingsDetailContentMargins()` 是对 `ScrollView` 生效的通用 API，语义
  // 和其它 Form 页完全一致；水平内距手动钉在 20pt，和 grouped Form 的默认
  // 水平内缩对齐（项目里没有专门收拢这个数值的令牌，`PieceDeskView` 里非
  // Form 的手排页也是同一个数）。
  private static let horizontalInset: CGFloat = 20

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
        // 这一页只管「手动粘贴链接」这条入口。扩展是另一条完全独立的路，
        // 不写清楚会被当成所有抓取路径的总开关。
        //
        // 放在页首而不是页尾：这是「这一页管什么」的前提。
        SettingsPageHeader(
          title: "站点登录",
          symbol: "person.crop.circle.badge.checkmark",
          caption: "在这里登录一次，后续添加链接和博主主页会自动复用；登录失效时再重新登录。",
          fill: SettingsCategoryChip.fill(for: "siteLogin", theme: appTheme),
          captionIdentifier: "site-login-scope-note"
        )

        sitesCard
        browserConnectionCard

        // 原来「无需登录」单独占一张列着 YouTube/X 的整卡——这两个站在这页没有
        // 任何可操作项，状态也永远不会变，一整张卡的视觉重量和信息量完全不匹配。
        // 收成页尾一行说明，原因还在，只是不再占一张卡的地方。
        Text("YouTube 和 X 单条公开链接无需登录；四个平台的博主主页都可以在上面登录一次后复用。")
          .themedFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("site-login-no-login-card")
      }
      .padding(.horizontal, Self.horizontalInset)
    }
    .background(appTheme.isNative ? Color.clear : appTheme.canvas)
    .settingsDetailContentMargins()
    .onAppear {
      browserSupport.refreshDeliveries()
      Task { await xSession.refreshStatus() }
      Task { await bilibiliSession.refreshStatus() }
      Task { await douyinSession.refreshStatus() }
      Task { await xiaohongshuSession.refreshStatus() }
    }
    .sheet(isPresented: $mediaStorage.isBilibiliLoginPresented) {
      SiteLoginSheet(session: bilibiliSession)
    }
    .sheet(item: $presentedLogin) { platform in
      SiteLoginSheet(session: controller(for: platform))
    }
    .accessibilityIdentifier("site-login-settings")
  }

  private var browserConnectionCard: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
      Text("通过本机浏览器读取 X")
        .themedFont(.headline)
      Text("在浏览器中使用 Google、Apple 或已有 X 登录。打开博主主页后，点击汲作扩展读取作品，再回到汲作勾选保存。")
        .themedFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let recent = browserSupport.lastDeliveries.max(by: { $0.value < $1.value }) {
        Text("最近收到 \(recent.key.displayName) 的内容：\(recent.value.formatted(date: .abbreviated, time: .shortened))")
          .themedFont(.caption)
      } else {
        Text("尚无浏览器送达记录。请先连接扩展，再从 X 主页发送一次作品清单。")
          .themedFont(.caption)
      }
      Text("送达记录不代表浏览器当前在线，也不代表 X 登录仍有效；与上方 App 内登录分别保存。")
        .themedFont(.caption2)
        .foregroundStyle(.secondary)
      HStack {
        Button("在浏览器中登录 X") {
          browserOpenError = NSWorkspace.shared.open(XExternalLoginPolicy.loginURL)
            ? nil : "未能打开默认浏览器，请检查系统设置后重试。"
        }
        .accessibilityIdentifier("site-login-x-browser")
        Button("连接浏览器扩展") { openBrowserSupport() }
          .accessibilityIdentifier("site-login-browser-support")
        Button("刷新状态") { browserSupport.refreshDeliveries() }
      }
      if let browserOpenError { Text(browserOpenError).themedFont(.caption) }
    }
    .padding(16)
    .accessibilityIdentifier("site-login-browser-connection")
  }

  // MARK: - 三站合一的行组卡

  /// 三个站点收进一张卡，一站一行、hairline 分隔——排布上是 `SettingsRowGroup`
  /// 的样子，只是这页不在 Form 里，卡面自己画（见文件头注释）。
  @ViewBuilder
  private var sitesCard: some View {
    VStack(spacing: 0) {
      siteRow(platform: .x, session: xSession, caption: "博主主页；与浏览器登录独立")
      siteRowDivider
      siteRow(
        platform: .bilibili,
        session: bilibiliSession,
        caption: "登录可选，也影响高清档位"
      )
      siteRowDivider
      siteRow(
        platform: .xiaohongshu,
        session: xiaohongshuSession,
        caption: "博主主页"
      )
      siteRowDivider
      siteRow(
        platform: .douyin,
        session: douyinSession,
        caption: "建议用扩展抓单条"
      )
    }
    .modifier(SettingsThemedCardChrome())
  }

  private var siteRowDivider: some View {
    Rectangle()
      .fill(appTheme.hairline)
      .frame(height: 1)
      .padding(.leading, DesignTokens.Space.lg + 20 + DesignTokens.Space.md)
  }

  private func controller(for platform: SiteSessionPlatform) -> SiteSessionController {
    switch platform {
    case .x: xSession
    case .bilibili: bilibiliSession
    case .douyin: douyinSession
    case .xiaohongshu: xiaohongshuSession
    }
  }

  private func host(for platform: SiteSessionPlatform) -> String {
    switch platform {
    case .x: "x.com"
    case .bilibili: "bilibili.com"
    case .douyin: "douyin.com"
    case .xiaohongshu: "xiaohongshu.com"
    }
  }

  // MARK: - 一站一行

  /// 一站一行：图标 + 站名 + caption 说明；右侧状态徽标 + 登录/重新登录 +
  /// 清除登录；点 ⓘ 展开这一行自己的技术细节（cookie 诊断、UID，B 站还有
  /// 校验会话）。
  @ViewBuilder
  private func siteRow(
    platform: SiteSessionPlatform,
    session: SiteSessionController,
    caption: String
  ) -> some View {
    let id = platform.rawValue
    let isExpanded = expandedDetailSites.contains(platform)
    let hasDetails = session.isLoggedIn || session.accountDetail != nil || session.sessionDiagnostic != nil || platform == .bilibili

    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      HStack(alignment: .center, spacing: DesignTokens.Space.md) {
        siteIcon(host: host(for: platform))

        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
          HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
            Text(platform.displayName)
              .themedFont(.body, weight: .semibold)
            if hasDetails {
              detailsToggle(platform: platform, isExpanded: isExpanded)
            }
          }
          Text(caption)
            .themedFont(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("site-login-\(id)-caption")
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        statusBadge(
          isLoggedIn: session.isLoggedIn,
          text: session.isLoggedIn ? "登录已保存" : "未登录",
          tone: session.isLoggedIn ? .active : .neutral
        )
        .accessibilityIdentifier("site-login-\(id)-status")

        Button(session.isLoggedIn ? "重新登录…" : "登录…") {
          presentLogin(platform)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.secondary)
        .accessibilityIdentifier("site-login-\(id)-login")

        Button("清除登录") {
          Task { await clearSession(platform, session: session) }
        }
        .themedFont(.body)
        .buttonStyle(.plain)
        .controlSize(.small)
        .foregroundStyle(appTheme.danger)
        .disabled(!session.isLoggedIn)
        .accessibilityIdentifier("site-login-\(id)-clear")
      }

      if isExpanded {
        detailsContent(platform: platform, session: session)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, DesignTokens.Space.sm)
    .padding(.horizontal, DesignTokens.Space.lg)
    .accessibilityElement(children: .contain)
  }

  /// B 站的登录走 `mediaStorage`（复用「重新获取播放」那条 sheet 呈现路径），
  /// 其余两站走这页自己的 `presentedLogin`。这一分支原来分别散落在两张卡各自的
  /// 按钮 action 里，合并成一行后收进一个函数，不用在 `siteRow` 里再重复 switch。
  private func presentLogin(_ platform: SiteSessionPlatform) {
    if platform == .bilibili {
      mediaStorage.presentBilibiliLogin()
    } else {
      presentedLogin = platform
    }
  }

  private func clearSession(_ platform: SiteSessionPlatform, session: SiteSessionController) async {
    if platform == .bilibili {
      mediaStorage.clearBilibiliSession()
    } else {
      await session.clear()
    }
  }

  /// ⓘ 展开按钮：样式与 `SettingsCard`/`SettingsRow` 的 details 入口一致
  /// （info.circle + borderless + 统一动效令牌），只是状态按站点分别记，不是
  /// 单个 `@State Bool`。
  @ViewBuilder
  private func detailsToggle(platform: SiteSessionPlatform, isExpanded: Bool) -> some View {
    Button {
      withAnimation(DesignTokens.Motion.resolved(DesignTokens.Motion.standard, reduceMotion: reduceMotion)) {
        if isExpanded {
          expandedDetailSites.remove(platform)
        } else {
          expandedDetailSites.insert(platform)
        }
      }
    } label: {
      Image(systemName: "info.circle")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("查看\(platform.displayName)详细信息")
    .accessibilityLabel("\(platform.displayName)详细信息")
  }

  /// ⓘ 展开区：读 cookie 的诊断细节、账号标识（UID），B 站还多一个「校验会话」
  /// 按钮和它的结果回音——这是交互，不是说明文字，必须留在这里而不是文档。
  @ViewBuilder
  private func detailsContent(platform: SiteSessionPlatform, session: SiteSessionController) -> some View {
    let id = platform.rawValue
    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
      if let detail = session.accountDetail {
        Text(detail)
          .themedFont(.caption2, monospacedDigit: true)
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
      if let diagnostic = session.sessionDiagnostic {
        Text(diagnostic)
          .themedFont(.caption)
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("site-login-\(id)-diagnostic")
      }
      if session.isLoggedIn, session.verificationLabel == nil {
        Text("登录已保存只表示本机还有会话，不表示一定有效。失效时再重新登录。")
          .themedFont(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if platform == .bilibili {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.sm) {
          Button(bilibiliSession.isVerifying ? "校验中…" : "校验会话") {
            Task { await bilibiliSession.verifySession() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(Color.secondary)
          .disabled(bilibiliSession.isVerifying)
          .accessibilityIdentifier("site-login-bilibili-verify")

          // 校验结果是点了按钮之后的真实反馈，不是说明文字——它必须留着，
          // 否则「校验会话」点完没有任何回音。
          if let verification = bilibiliSession.verificationLabel {
            Label(verification, systemImage: "checkmark.seal")
              .themedFont(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("site-login-bilibili-verification")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 20 + DesignTokens.Space.md)
  }

  // MARK: - 卡片零件

  private enum BadgeTone { case active, neutral }

  /// 状态必须能扫视到。纯文字「已登录 / 未登录」混在一行里读不出差别，
  /// 而这一页最常被打开的原因就是「我到底登没登」。
  @ViewBuilder
  private func statusBadge(isLoggedIn: Bool, text: String, tone: BadgeTone) -> some View {
    let color: Color = tone == .active ? appTheme.success : .secondary
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      Text(text)
        .themedFont(.caption, weight: .medium)
        .foregroundStyle(tone == .active ? color : Color.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(tone == .active ? 0.12 : 0.08), in: Capsule())
  }

  @ViewBuilder
  private func siteIcon(host: String) -> some View {
    if let image = PlatformIconCatalog.image(for: host) {
      Image(nsImage: image)
        .resizable()
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill(PlatformIconCatalog.fallbackColor(for: host))
        .frame(width: 20, height: 20)
        .overlay(
          Text(PlatformIconCatalog.fallbackInitial(for: host))
            .themedFont(.caption2, weight: .semibold)
            .foregroundStyle(.white)
        )
    }
  }
}

extension SiteSessionPlatform: Identifiable {
  public var id: String { rawValue }
}
