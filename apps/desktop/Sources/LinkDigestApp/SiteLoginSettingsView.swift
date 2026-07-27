import LinkDigestCore
import SwiftUI

/// Dedicated settings page for App-owned platform login sessions used by
/// high-quality streaming recovery. Kept separate from “视频存储” so disk
/// preferences do not grow into a multi-site account hub.
struct SiteLoginSettingsView: View {
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili
  @ObservedObject private var douyinSession = SiteSessionController.douyin
  @ObservedObject private var xiaohongshuSession = SiteSessionController.xiaohongshu
  /// 哪个站点的登录窗口正开着。用 profile 的 platform 当身份，避免再加一堆布尔量。
  @State private var presentedLogin: SiteSessionPlatform?

  var body: some View {
    Form {
      Section {
        LabeledContent("B 站") {
          Text(bilibiliSession.statusLabel)
            .foregroundStyle(bilibiliSession.isLoggedIn ? .primary : .secondary)
            .accessibilityIdentifier("site-login-bilibili-status")
        }
        HStack {
          Button(bilibiliSession.isLoggedIn ? "重新登录…" : "登录…") {
            mediaStorage.presentBilibiliLogin()
          }
          .accessibilityIdentifier("site-login-bilibili-login")
          Button("清除登录", role: .destructive, action: mediaStorage.clearBilibiliSession)
            .disabled(!bilibiliSession.isLoggedIn)
            .accessibilityIdentifier("site-login-bilibili-clear")
          Spacer()
          // 上面那行「已登录」只证明本机存着 Cookie，不证明服务端认它。
          Button(bilibiliSession.isVerifying ? "校验中…" : "校验会话") {
            Task { await bilibiliSession.verifySession() }
          }
          .disabled(bilibiliSession.isVerifying)
          .accessibilityIdentifier("site-login-bilibili-verify")
        }
        if let verification = bilibiliSession.verificationLabel {
          Text(verification)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("site-login-bilibili-verification")
        } else if bilibiliSession.isLoggedIn {
          // 「已登录」只说明本机存着 Cookie。会话过期、或 Cookie 在我们自己的网络层
          // 被丢掉，这行字都不会变——而症状是清晰度悄悄降档，没有任何报错。
          // 不自动去打接口（每次进设置页都发一次请求不合适），但要让人知道该点一下。
          Text("「已登录」只表示本机存有 Cookie。清晰度上不去时，先点「校验会话」确认服务端是否认可。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("site-login-bilibili-verify-hint")
        }
      } header: {
        // 原来叫「已支持」——那既没说清 B 站要不要登录，也让人以为另外两组「不支持」。
        // 分组判据统一成「登录对这个站点起什么作用」。
        Text("登录可选：影响清晰度")
      } footer: {
        Text("B 站不登录也能抓取和转写，公开接口通常能拿到 720P。登录只抬高「重新获取播放」的清晰度上限——会员专属档需要你自己的账号权限。\n登录态仅保存在本机隔离 WebKit 环境，不会上传，也不会读取系统浏览器 Cookie；可随时清除。")
      }

      // 抖音与小红书的用途和 B 站不同：B 站是「刷新会过期的高清地址」，
      // 这两个是「未登录看不到正文」。同一套隔离会话机制，两种消费端。
      Section {
        // 不要在这里插 Divider()：grouped Form 会把它当成一个独立行渲染成空白横条，
        // Section 本身已经给相邻行画了分隔线。
        captureSessionRow(session: xiaohongshuSession, platform: .xiaohongshu)
        // 抖音排在小红书后面并带一行提示：同在这一组是因为登录机制相同，但它是
        // 「登录了也常常不够」，不能让人以为登录完粘链接就能用。
        captureSessionRow(
          session: douyinSession,
          platform: .douyin,
          note: "抖音正文由页面脚本渲染，手动链接常取不到；抓抖音请优先用浏览器扩展。")
      } header: {
        Text("登录才能抓到正文")
      } footer: {
        Text("这两个站点未登录时只返回登录墙或验证页，直接抓会把那个外壳当正文存下来。登录后手动粘贴链接才能取到真正的内容。\n抖音还有一层限制：它的正文是页面脚本在浏览器里渲染出来的，服务端返回的 HTML 里没有内容，所以即使登录，手动粘链接也常常取不到正文，这时会明确提示改用扩展——抖音走扩展最稳。\n登录态与 B 站一样保存在本机隔离 WebKit 环境，不会上传，也不会读取系统浏览器 Cookie；可随时清除。抖音用手机扫码登录。")
      }

      Section {
        LabeledContent("YouTube") {
          Text("官方嵌入播放，无需登录").foregroundStyle(.secondary)
        }
        LabeledContent("X") {
          Text("走公开嵌入接口，登录不影响结果").foregroundStyle(.secondary)
        }
      } header: {
        Text("无需登录")
      } footer: {
        Text("YouTube 用官方嵌入播放器，X 的视频走公开嵌入接口——那个接口不认账号，登录不会改变结果。\n\n这一页只管「手动粘贴链接」这条入口。浏览器扩展走的是你自己浏览器里的登录态，与这里的会话无关，任何平台都不需要先在这里登录——需要登录才能看到的页面，在浏览器里登录后用扩展发送即可，那也是最可靠的一条路。")
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

  /// 抓取型会话的一行：状态 + 登录 + 清除。
  ///
  /// 没有「校验会话」——这两个站没有稳定的公开登录态接口，硬找就要 replay 私有
  /// 签名接口。会话失效的表现是抓取回落到明确报错，不会静默出坏结果，所以不需要
  /// 一个只能靠猜实现的校验按钮。
  /// - Parameter note: 只属于这一行的限制说明。抖音需要它——「已登录」这三个字会让人
  ///   以为手动粘链接就能用了，而实际上多半取不到正文。放在行内而不是只写进 footer，
  ///   是因为状态那行才是人真正会看的地方。
  @ViewBuilder
  private func captureSessionRow(
    session: SiteSessionController,
    platform: SiteSessionPlatform,
    note: String? = nil
  ) -> some View {
    let id = platform.rawValue
    LabeledContent(platform.displayName) {
      Text(session.statusLabel)
        .foregroundStyle(session.isLoggedIn ? .primary : .secondary)
        .accessibilityIdentifier("site-login-\(id)-status")
    }
    if let note {
      Text(note)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("site-login-\(id)-note")
    }
    HStack {
      Button(session.isLoggedIn ? "重新登录…" : "登录…") { presentedLogin = platform }
        .accessibilityIdentifier("site-login-\(id)-login")
      Button("清除登录", role: .destructive) {
        Task { await session.clear() }
      }
      .disabled(!session.isLoggedIn)
      .accessibilityIdentifier("site-login-\(id)-clear")
      Spacer()
    }
  }
}

extension SiteSessionPlatform: Identifiable {
  public var id: String { rawValue }
}
