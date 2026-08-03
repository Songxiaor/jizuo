import LinkDigestCore
import SwiftUI

/// Dedicated settings page for App-owned platform login sessions used by
/// high-quality streaming recovery. Kept separate from “视频存储” so disk
/// preferences do not grow into a multi-site account hub.
///
/// 排版约定：**一个站点 = 一个 Section = 一张卡片**。
///
/// 原来一个站点被拆成「状态行 / 说明行 / 按钮行」三个 Form 行，而 grouped Form
/// 会给每一行画分隔线——同一个站点的三段信息被切成三条看似不相干的记录，页面
/// 因此显得乱。整张卡片必须是 Section 里的**单个** View，内部才不会再被切开。
///
/// 文案约定：**分组标题说清「登录起什么作用」，卡片里默认不写说明。**
///
/// 这页曾经每张卡都带副标题 + 一段正文 + 「了解更多」，讲的是机制——登录墙长什么样、
/// 正文由谁渲染、Cookie 存在哪里。那是写给实现者看的：同一件事被分组标题、副标题、
/// 正文说了三遍，而用的人只需要知道「登不登录有什么区别」，分组标题已经答完了。
///
/// 同类产品的做法一致：Downie 的偏好设置只有站点清单，Readwise 界面里一个字不写，
/// 登录墙那套解释全在各自的 help 站点。机制解释属于官方文档，不属于设置页。
///
/// 因此卡片里只保留**例外**：某个站点的行为和同组其他站点不同，不说会让人踩坑。
/// 目前只有抖音符合——同在「登录才能抓到正文」，但它登录了手动粘链接也常失败。
struct SiteLoginSettingsView: View {
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  /// 哪个站点的登录窗口正开着。用 profile 的 platform 当身份，避免再加一堆布尔量。
  @State private var presentedLogin: SiteSessionPlatform?

  var body: some View {
    Form {
      // 这一页只管「手动粘贴链接」这条入口。扩展是另一条完全独立的路，
      // 不写清楚会被当成所有抓取路径的总开关。
      //
      // 放在页首而不是页尾：这是「这一页管什么」的前提。原来它在最后一个
      // Section，用户已经逐个站点读完、甚至白登录了一遍，才看到「用扩展的话
      // 这页你根本不用来」。
      Section {
        Label {
          Text("这一页只管手动粘链接；用扩展抓不需要在这里登录。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("site-login-scope-note")
      }

      // 原来叫「已支持」——那既没说清 B 站要不要登录，也让人以为另外两组「不支持」。
      // 分组判据统一成「登录对这个站点起什么作用」。
      Section {
        bilibiliCard
      } header: {
        Text("登录可选：影响清晰度")
      }

      // 抖音与小红书的用途和 B 站不同：B 站是「刷新会过期的高清地址」，
      // 这两个是「未登录看不到正文」。同一套隔离会话机制，两种消费端。
      Section {
        captureSessionCard(session: xiaohongshuSession, platform: .xiaohongshu)
      } header: {
        Text("登录才能抓到正文")
      }

      // 抖音单独一张卡并带自己的限制说明：同在这一组是因为登录机制相同，但它是
      // 「登录了也常常不够」，不能让人以为登录完粘链接就能用。这是这页唯一还留着
      // 说明文字的地方——不写就会踩坑，写「为什么」则是文档的事。
      Section {
        captureSessionCard(
          session: douyinSession,
          platform: .douyin,
          note: "抖音建议用扩展抓，粘链接常失败。"
        )
      }

      Section {
        noLoginCard
      } header: {
        Text("无需登录")
      }
    }
    .formStyle(.grouped)
    .settingsDetailContentMargins()
    .onAppear {
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

  private func controller(for platform: SiteSessionPlatform) -> SiteSessionController {
    switch platform {
    case .bilibili: bilibiliSession
    case .douyin: douyinSession
    case .xiaohongshu: xiaohongshuSession
    }
  }

  private func host(for platform: SiteSessionPlatform) -> String {
    switch platform {
    case .bilibili: "bilibili.com"
    case .douyin: "douyin.com"
    case .xiaohongshu: "xiaohongshu.com"
    }
  }

  // MARK: - B 站

  /// B 站独有「校验会话」：只有它有稳定的公开登录态接口。
  @ViewBuilder private var bilibiliCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      cardHeader(
        host: "bilibili.com",
        name: SiteSessionPlatform.bilibili.displayName,
        isLoggedIn: bilibiliSession.isLoggedIn,
        detail: bilibiliSession.accountDetail,
        statusIdentifier: "site-login-bilibili-status"
      )

      // 校验结果是点了按钮之后的真实反馈，不是说明文字——它必须留着，
      // 否则「校验会话」点完没有任何回音。
      if let verification = bilibiliSession.verificationLabel {
        Label(verification, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("site-login-bilibili-verification")
      }

      diagnosticLabel(session: bilibiliSession, id: "bilibili")

      cardActions(
        primary: {
          Button(bilibiliSession.isLoggedIn ? "重新登录…" : "登录…") {
            mediaStorage.presentBilibiliLogin()
          }
          .accessibilityIdentifier("site-login-bilibili-login")
          Button(bilibiliSession.isVerifying ? "校验中…" : "校验会话") {
            Task { await bilibiliSession.verifySession() }
          }
          .disabled(bilibiliSession.isVerifying)
          .accessibilityIdentifier("site-login-bilibili-verify")
        },
        destructive: {
          Button("清除登录", role: .destructive, action: mediaStorage.clearBilibiliSession)
            .disabled(!bilibiliSession.isLoggedIn)
            .accessibilityIdentifier("site-login-bilibili-clear")
        }
      )
    }
    .padding(.vertical, 4)
  }

  // MARK: - 抓取型会话

  /// 抓取型会话卡片：状态 + 登录 + 清除。
  ///
  /// 没有「校验会话」——这两个站没有稳定的公开登录态接口，硬找就要 replay 私有
  /// 签名接口。会话失效的表现是抓取回落到明确报错，不会静默出坏结果，所以不需要
  /// 一个只能靠猜实现的校验按钮。
  /// - Parameter note: 只属于这一站的例外。默认没有——分组标题「登录才能抓到正文」
  ///   已经把这一组说完了，再在卡里重复一遍只是把同一句话说第三遍。只有行为与同组
  ///   其他站点不同、不说会踩坑的站点才传（目前只有抖音）。
  @ViewBuilder
  private func captureSessionCard(
    session: SiteSessionController,
    platform: SiteSessionPlatform,
    note: String? = nil
  ) -> some View {
    let id = platform.rawValue
    VStack(alignment: .leading, spacing: 12) {
      cardHeader(
        host: host(for: platform),
        name: platform.displayName,
        isLoggedIn: session.isLoggedIn,
        detail: session.accountDetail,
        statusIdentifier: "site-login-\(id)-status"
      )

      if let note {
        Label(note, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("site-login-\(id)-note")
      }

      diagnosticLabel(session: session, id: id)

      cardActions(
        primary: {
          Button(session.isLoggedIn ? "重新登录…" : "登录…") { presentedLogin = platform }
            .accessibilityIdentifier("site-login-\(id)-login")
        },
        destructive: {
          Button("清除登录", role: .destructive) {
            Task { await session.clear() }
          }
          .disabled(!session.isLoggedIn)
          .accessibilityIdentifier("site-login-\(id)-clear")
        }
      )
    }
    .padding(.vertical, 4)
  }

  // MARK: - 无需登录

  /// 无需登录的站点合成一张只读卡片。
  ///
  /// 这些站在这一页没有任何可操作项：没有按钮，状态也永远不会变。让它们各占一张
  /// 带状态胶囊和「了解更多」的整卡，视觉重量和信息量完全不匹配——而分组标题已经
  /// 写了「无需登录」，胶囊只是把同一句话再说一遍。
  ///
  /// 保留的只有图标、名字和一句「为什么不用登录」：前两者是扫视锚点，后者是这张卡
  /// 存在的唯一理由——不写原因，读者会怀疑是不是漏配了什么。
  @ViewBuilder private var noLoginCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Grid 而不是逐行 HStack：原因那一列要对齐，否则两行读起来像两条不相干的记录。
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        noLoginRow(name: "YouTube", host: "youtube.com", reason: "官方嵌入播放")
        noLoginRow(name: "X", host: "x.com", reason: "走公开嵌入接口")
      }
      Text("这两个站不认账号，登录不会改变抓取结果，直接粘链接就行。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("site-login-no-login-card")
  }

  private func noLoginRow(name: String, host: String, reason: String) -> some View {
    GridRow {
      siteIcon(host: host)
      Text(name).font(.headline)
      Text(reason)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - 卡片零件

  @ViewBuilder
  private func cardHeader(
    host: String,
    name: String,
    isLoggedIn: Bool,
    detail: String?,
    statusIdentifier: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      siteIcon(host: host)
      // 站名下面原来还有一行「影响清晰度上限」「登录才能抓到正文」——那正是分组
      // 标题的原话。分组标题就在上方几十点的地方，重复一遍不增加任何信息。
      Text(name).font(.headline)
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 3) {
        statusBadge(
          isLoggedIn: isLoggedIn,
          text: isLoggedIn ? "已登录" : "未登录",
          tone: isLoggedIn ? .active : .neutral
        )
        .accessibilityIdentifier(statusIdentifier)
        if let detail {
          Text(detail)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
      }
    }
  }

  /// 上一次读取 cookie 的实测结果。
  ///
  /// 放在这一页是因为「显示未登录」正是在这里被看到的：判断到底是一条都没读到、
  /// 还是读到了但少一个名字，必须和状态胶囊在同一屏，否则对不上号。
  @ViewBuilder
  private func diagnosticLabel(session: SiteSessionController, id: String) -> some View {
    if let diagnostic = session.sessionDiagnostic {
      Label(diagnostic, systemImage: "stethoscope")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("site-login-\(id)-diagnostic")
    }
  }

  private enum BadgeTone { case active, neutral }

  /// 状态必须能扫视到。纯文字「已登录 / 未登录」混在一行里读不出差别，
  /// 而这一页最常被打开的原因就是「我到底登没登」。
  @ViewBuilder
  private func statusBadge(isLoggedIn: Bool, text: String, tone: BadgeTone) -> some View {
    let color: Color = tone == .active ? .green : .secondary
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(text)
        .font(.caption.weight(.medium))
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
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(PlatformIconCatalog.fallbackColor(for: host))
        .frame(width: 20, height: 20)
        .overlay(
          Text(PlatformIconCatalog.fallbackInitial(for: host))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
        )
    }
  }

  /// 主要动作靠左、破坏性动作靠右——「清除登录」和「登录」并排同色时容易误点。
  @ViewBuilder
  private func cardActions(
    @ViewBuilder primary: () -> some View,
    @ViewBuilder destructive: () -> some View
  ) -> some View {
    HStack(spacing: 8) {
      primary()
      Spacer(minLength: 16)
      destructive()
    }
  }
}

extension SiteSessionPlatform: Identifiable {
  public var id: String { rawValue }
}
