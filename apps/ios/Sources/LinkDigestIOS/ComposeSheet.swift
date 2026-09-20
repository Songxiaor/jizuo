import LinkDigestShared
import SwiftUI

struct ComposeSheet: View {
  @Bindable var model: NotesViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var tab: Tab = .text
  @State private var showSessionCapture = false

  enum Tab: String, CaseIterable, Identifiable {
    case text = "手写"
    case voice = "口述"
    case link = "链接"
    var id: String { rawValue }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("类型", selection: $tab) {
          ForEach(Tab.allCases) { item in
            Text(item.rawValue).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .padding()

        switch tab {
        case .text:
          TextComposeForm(model: model, dismiss: dismiss)
        case .voice:
          VoiceComposeForm(model: model, dismiss: dismiss)
        case .link:
          LinkComposeForm(
            model: model,
            dismiss: dismiss,
            onOpenSessionCapture: { showSessionCapture = true }
          )
        }
      }
      .navigationTitle("新建")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
      }
      .sheet(isPresented: $showSessionCapture) {
        SessionCaptureSheet(model: model)
      }
    }
  }
}

private struct TextComposeForm: View {
  @Bindable var model: NotesViewModel
  let dismiss: DismissAction
  @State private var title = ""
  @State private var bodyText = ""

  var body: some View {
    Form {
      TextField("标题（可空）", text: $title)
      TextEditor(text: $bodyText)
        .frame(minHeight: 180)
    }
    .safeAreaInset(edge: .bottom) {
      Button("保存") {
        Task {
          await model.createTextNote(
            title: title.isEmpty ? nil : title,
            body: bodyText
          )
          dismiss()
        }
      }
      .buttonStyle(.borderedProminent)
      .frame(maxWidth: .infinity)
      .padding()
    }
  }
}

private struct VoiceComposeForm: View {
  @Bindable var model: NotesViewModel
  let dismiss: DismissAction
  @State private var dictation = VoiceDictationController()

  var body: some View {
    @Bindable var dictation = dictation
    Form {
      Section {
        Text("按住或点击麦克风口述；转写会实时出现在下方，可再手工改字后保存。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        HStack {
          Spacer()
          VoiceRecordButton(dictation: dictation)
          Spacer()
        }
        .listRowBackground(Color.clear)

        if dictation.isRecording {
          Text("正在听写…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let error = dictation.errorMessage {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityLabel("口述错误：\(error)")
        }
      } header: {
        Text("口述转写")
      }

      Section("转写文本") {
        TextEditor(text: $dictation.editableTranscript)
          .frame(minHeight: 160)
          .disabled(dictation.phase == .denied)
      }
    }
    .task {
      await dictation.prepareIfNeeded()
    }
    .safeAreaInset(edge: .bottom) {
      Button("保存口述笔记") {
        Task {
          let text = dictation.transcriptForSave()
          guard !text.isEmpty else { return }
          if dictation.isRecording {
            await dictation.stopRecording()
          }
          await model.createVoiceNote(transcript: dictation.transcriptForSave())
          dismiss()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!dictation.canSave || dictation.phase == .denied)
      .frame(maxWidth: .infinity)
      .padding()
    }
  }
}

private struct VoiceRecordButton: View {
  var dictation: VoiceDictationController
  @State private var holdTask: Task<Void, Never>?
  @State private var holdArmed = false

  var body: some View {
    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
      .font(.system(size: 36, weight: .semibold))
      .foregroundStyle(dictation.isRecording ? Color.white : Color.accentColor)
      .frame(width: 88, height: 88)
      .background(
        Circle()
          .fill(dictation.isRecording ? Color.red : Color.accentColor.opacity(0.15))
      )
      .accessibilityLabel(dictation.isRecording ? "停止口述" : "开始口述")
      .opacity(dictation.phase == .denied ? 0.4 : 1)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard holdTask == nil else { return }
            holdTask = Task {
              try? await Task.sleep(nanoseconds: 300_000_000)
              guard !Task.isCancelled else { return }
              holdArmed = true
              if !dictation.isRecording {
                await dictation.startRecording()
              }
            }
          }
          .onEnded { _ in
            holdTask?.cancel()
            holdTask = nil
            let viaHold = holdArmed
            holdArmed = false
            Task {
              if viaHold || dictation.isRecording {
                if dictation.isRecording {
                  await dictation.stopRecording()
                }
              } else {
                await dictation.toggleRecording()
              }
            }
          }
      )
      .disabled(dictation.phase == .denied || dictation.phase == .requestingPermission)
  }
}

private struct LinkComposeForm: View {
  @Bindable var model: NotesViewModel
  let dismiss: DismissAction
  var onOpenSessionCapture: () -> Void = {}
  @State private var url = ""
  @State private var title = ""
  @State private var bodyText = ""
  @State private var summary = ""
  @State private var isFetching = false
  @State private var fetchWarning: String?

  var body: some View {
    Form {
      TextField("链接 URL", text: $url)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        #endif
      TextField("标题（可空，抓取后可覆盖）", text: $title)
      Section {
        TextEditor(text: $bodyText)
          .frame(minHeight: 120)
      } header: {
        Text("正文（可空；空则自动抓取）")
      } footer: {
        Text("保存时若正文为空，会用本机网络抓取公开页面的标题与正文。失败仍可保存链接。登录墙页面请用「应用内打开抓取」或 Safari 分享。")
          .font(.footnote)
      }
      Section {
        Button("应用内打开抓取（可登录）…") {
          onOpenSessionCapture()
        }
      } footer: {
        Text("在 App 内打开站点并登录后抓当前页 DOM；不读取系统浏览器 Cookie。")
          .font(.footnote)
      }
      if let fetchWarning {
        Section {
          Text(fetchWarning)
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
      Section("总结（可空；也可稍后在详情页用模型生成）") {
        TextEditor(text: $summary)
          .frame(minHeight: 80)
      }
    }
    .safeAreaInset(edge: .bottom) {
      Button {
        Task {
          isFetching = true
          defer { isFetching = false }
          let warning = await model.createLinkNoteFetching(
            url: url,
            titleOverride: title.isEmpty ? nil : title,
            bodyOverride: bodyText.isEmpty ? nil : bodyText,
            summary: summary.isEmpty ? nil : summary
          )
          if let warning {
            fetchWarning = warning
            // 有警告时稍停，让用户看见原因后再关；仍已保存。
            try? await Task.sleep(nanoseconds: 900_000_000)
          }
          dismiss()
        }
      } label: {
        if isFetching {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text("保存链接笔记")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
      .padding()
    }
  }
}
