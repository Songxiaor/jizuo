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
/// 长说明也从卡片外的 footer 收进卡片内：卡片里只留一句最关键的，其余进
/// 「了解更多」。放在 footer 时它离对应站点隔着一段距离，读者不会把两者关联起来。
struct SiteLoginSettingsView: View {
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  /// 哪个站点的登录窗口正开着。用 profile 的 platform 当身份，避免再加一堆布尔量。
  @State private var presentedLogin: SiteSessionPlatform?

  var body: some View {
    Form {
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
      // 「登录了也常常不够」，不能让人以为登录完粘链接就能用。
      Section {
        captureSessionCard(
          session: douyinSession,
          platform: .douyin,
          note: "抖音正文由页面脚本渲染，手动链接常取不到；抓抖音请优先用浏览器扩展。",
          details: "抖音的正文是页面脚本在浏览器里渲染出来的，服务端返回的 HTML 里没有内容，所以即使登录，手动粘链接也常常取不到正文，这时会明确提示改用扩展——抖音走扩展最稳。\n抖音用手机扫码登录。"
        )
      }

      Section {
        noLoginCard(
          name: "YouTube",
          host: "youtube.com",
          summary: "官方嵌入播放，无需登录",
          details: "YouTube 用官方嵌入播放器，登录不会改变结果。"
        )
      } header: {
        Text("无需登录")
      }

      Section {
        noLoginCard(
          name: "X",
          host: "x.com",
          summary: "走公开嵌入接口，登录不影响结果",
          details: "X 的视频走公开嵌入接口——那个接口不认账号，登录不会改变结果。"
        )
      }

      Section {
        // 这一页只管「手动粘贴链接」这条入口。扩展是另一条完全独立的路，
        // 不写清楚会被当成所有抓取路径的总开关。
        Label {
          Text("这一页只管「手动粘贴链接」这条入口。浏览器扩展走的是你自己浏览器里的登录态，与这里的会话无关，任何平台都不需要先在这里登录——需要登录才能看到的页面，在浏览器里登录后用扩展发送即可，那也是最可靠的一条路。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("site-login-scope-note")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
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
        role: "影响清晰度上限",
        isLoggedIn: bilibiliSession.isLoggedIn,
        detail: bilibiliSession.accountDetail,
        statusIdentifier: "site-login-bilibili-status"
      )

      Text("B 站不登录也能抓取和转写，公开接口通常能拿到 720P；登录只抬高「重新获取播放」的清晰度上限。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let verification = bilibiliSession.verificationLabel {
        Label(verification, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("site-login-bilibili-verification")
      } else if bilibiliSession.isLoggedIn {
        // 「已登录」只说明本机存着 Cookie。会话过期、或 Cookie 在我们自己的网络层
        // 被丢掉，这行字都不会变——而症状是清晰度悄悄降档，没有任何报错。
        // 不自动去打接口（每次进设置页都发一次请求不合适），但要让人知道该点一下。
        Label(
          "「已登录」只表示本机存有 Cookie。清晰度上不去时，先点「校验会话」确认服务端是否认可。",
          systemImage: "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("site-login-bilibili-verify-hint")
      }

      moreDetails(
        "会员专属档需要你自己的账号权限，登录也不保证一定能拿到 4K。\n登录态仅保存在本机隔离 WebKit 环境，不会上传，也不会读取系统浏览器 Cookie；可随时清除。"
      )

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
  /// - Parameter note: 只属于这一站的限制说明。抖音需要它——「已登录」这三个字会让人
  ///   以为手动粘链接就能用了，而实际上多半取不到正文。放在卡片内而不是页尾 footer，
  ///   是因为状态那块才是人真正会看的地方。
  @ViewBuilder
  private func captureSessionCard(
    session: SiteSessionController,
    platform: SiteSessionPlatform,
    note: String? = nil,
    details: String? = nil
  ) -> some View {
    let id = platform.rawValue
    VStack(alignment: .leading, spacing: 12) {
      cardHeader(
        host: host(for: platform),
        name: platform.displayName,
        role: "登录才能抓到正文",
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
      } else {
        Text("未登录时只返回登录墙或验证页，直接抓会把那个外壳当正文存下来。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      moreDetails(
        (details.map { $0 + "\n" } ?? "")
          + "登录态与 B 站一样保存在本机隔离 WebKit 环境，不会上传，也不会读取系统浏览器 Cookie；可随时清除。"
      )

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

  @ViewBuilder
  private func noLoginCard(
    name: String,
    host: String,
    summary: String,
    details: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        siteIcon(host: host)
        Text(name).font(.headline)
        Spacer(minLength: 12)
        statusBadge(isLoggedIn: false, text: "无需登录", tone: .neutral)
      }
      Text(summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      moreDetails(details)
    }
    .padding(.vertical, 4)
  }

  // MARK: - 卡片零件

  @ViewBuilder
  private func cardHeader(
    host: String,
    name: String,
    role: String,
    isLoggedIn: Bool,
    detail: String?,
    statusIdentifier: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      siteIcon(host: host)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(role).font(.caption).foregroundStyle(.secondary)
      }
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

  /// 详细说明默认收起。信息一条不删，但不再默认占掉半页。
  @ViewBuilder
  private func moreDetails(_ text: String) -> some View {
    DisclosureGroup("了解更多") {
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
    .font(.caption)
    .accessibilityIdentifier("site-login-more-details")
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
