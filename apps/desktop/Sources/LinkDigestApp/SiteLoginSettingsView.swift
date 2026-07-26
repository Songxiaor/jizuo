import LinkDigestCore
import SwiftUI

/// Dedicated settings page for App-owned platform login sessions used by
/// high-quality streaming recovery. Kept separate from “视频存储” so disk
/// preferences do not grow into a multi-site account hub.
struct SiteLoginSettingsView: View {
  @ObservedObject var mediaStorage: MediaStorageSettingsViewModel
  @ObservedObject private var bilibiliSession = SiteSessionController.bilibili

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
        }
      } header: {
        Text("已支持")
      } footer: {
        Text("登录后，「重新获取播放」可按你的账号权限拉取更高清晰度。登录态仅保存在本机隔离 WebKit 环境，不会上传，也不会读取系统浏览器 Cookie；可随时清除。")
      }

      Section {
        LabeledContent("X") {
          Text("即将支持").foregroundStyle(.secondary)
        }
        LabeledContent("YouTube") {
          Text("官方嵌入，一般无需登录").foregroundStyle(.secondary)
        }
        LabeledContent("抖音") {
          Text("即将支持（扫码登录）").foregroundStyle(.secondary)
        }
        LabeledContent("小红书") {
          Text("即将支持").foregroundStyle(.secondary)
        }
      } header: {
        Text("后续平台")
      } footer: {
        Text("站点登录与「浏览器支持」不同：后者连接扩展抓取当前页；这里保存的是 App 内主动登录的会话，用于退出后再开仍能高清流式播放。")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.bottom, 24, for: .scrollContent)
    .onAppear {
      Task { await bilibiliSession.refreshStatus() }
    }
    .sheet(isPresented: $mediaStorage.isBilibiliLoginPresented) {
      SiteLoginSheet(session: bilibiliSession)
    }
    .accessibilityIdentifier("site-login-settings")
  }
}
