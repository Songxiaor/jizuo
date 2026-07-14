import SwiftUI

struct ProviderSettingsView: View {
  @ObservedObject var model: ProviderSettingsViewModel
  @State private var apiKeyInput = ""

  var body: some View {
    GroupBox("模型配置") {
      VStack(alignment: .leading, spacing: 10) {
        TextField("OpenAI-compatible Base URL（https://…）", text: $model.baseURL)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("provider-base-url")

        TextField("模型名", text: $model.modelName)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("provider-model-name")

        SecureField("API Key", text: $apiKeyInput)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("provider-api-key")

        HStack(spacing: 12) {
          Button("保存模型配置") {
            let submittedKey = apiKeyInput
            apiKeyInput = ""
            Task {
              await model.save(apiKey: submittedKey)
            }
          }
          .disabled(model.isSaving)
          .accessibilityIdentifier("save-provider-settings")

          if model.isSaving {
            ProgressView()
              .controlSize(.small)
          }

          Text(model.statusText)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("provider-settings-status")
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
}
