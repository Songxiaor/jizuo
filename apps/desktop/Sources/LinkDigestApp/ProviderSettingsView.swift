import SwiftUI

struct ProviderSettingsView: View {
  @ObservedObject var model: ProviderSettingsViewModel
  @State private var apiKeyInput = ""

  var body: some View {
    GroupBox("模型配置") {
      VStack(alignment: .leading, spacing: 10) {
        TextField("OpenAI-compatible Base URL（https://…）", text: $model.baseURL)
          .textFieldStyle(.roundedBorder)
          .disabled(model.isSaving)
          .accessibilityIdentifier("provider-base-url")

        TextField("模型名", text: $model.modelName)
          .textFieldStyle(.roundedBorder)
          .disabled(model.isSaving)
          .accessibilityIdentifier("provider-model-name")

        SecureField("API Key", text: $apiKeyInput)
          .textFieldStyle(.roundedBorder)
          .disabled(model.isSaving)
          .accessibilityIdentifier("provider-api-key")

        HStack(spacing: 12) {
          Button("保存模型配置") {
            let submittedKey = apiKeyInput
            apiKeyInput = ""
            Task {
              await model.save(apiKey: submittedKey)
            }
          }
          .disabled(model.isSaving || model.isTestingConnection)
          .accessibilityIdentifier("save-provider-settings")

          if model.isSaving {
            ProgressView()
              .controlSize(.small)
          }

          Text(model.statusText)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("provider-settings-status")
        }

        Divider().padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Button("测试连接") {
              Task { await model.testConnection() }
            }
            .disabled(
              model.isSaving
                || model.isTestingConnection
                || model.hasUnsavedIdentityChanges
                || !apiKeyInput.isEmpty
            )
            .accessibilityIdentifier("test-provider-connection")
            .accessibilityLabel("测试模型连接")
            .accessibilityHint(testConnectionBlocked ? unsavedChangesText : "发送极短提示验证当前已保存配置")

            if model.isTestingConnection {
              ProgressView()
                .controlSize(.small)
            }

            Text(connectionStatusText)
              .foregroundStyle(connectionStatusColor)
              .accessibilityIdentifier("provider-connection-status")
              .accessibilityLabel("连接测试状态：\(connectionStatusText)")
          }
          Text("测试只发送“Reply with OK.”的极短提示，可能产生极少模型用量；不会创建历史记录或保存回复内容。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 4)
    }
    .task {
      await model.load()
    }
  }

  private var statusColor: Color {
    if case .failed = model.state {
      return .red
    }
    return .secondary
  }

  private var connectionStatusColor: Color {
    if case .failure = model.connectionTestState {
      return .red
    }
    if case .success = model.connectionTestState {
      return .green
    }
    return .secondary
  }

  private let unsavedChangesText = "有未保存更改，请先保存后再测试"

  private var testConnectionBlocked: Bool {
    model.isSaving
      || model.isTestingConnection
      || model.hasUnsavedIdentityChanges
      || !apiKeyInput.isEmpty
  }

  private var connectionStatusText: String {
    if model.hasUnsavedIdentityChanges || !apiKeyInput.isEmpty {
      return unsavedChangesText
    }
    return model.connectionTestStatusText
  }
}
