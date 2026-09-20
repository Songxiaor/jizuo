import LinkDigestShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct NoteDetailView: View {
  @Bindable var model: NotesViewModel
  @State var note: SyncNoteCard
  @State private var copyHint: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          Text(note.title)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
          if note.sourceURL != nil {
            copyButton(label: "标题+链接", hint: "已复制标题与链接") {
              titleAndLinkClipboardText
            }
          }
        }

        if let url = note.sourceURL {
          Text(url)
            .font(.footnote)
            .foregroundStyle(.tint)
            .textSelection(.enabled)
          if let platform = IOSContentPlatform.recognize(urlString: url) {
            Text(platform.displayName)
              .font(.caption.weight(.medium))
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.secondary.opacity(0.15), in: Capsule())
          }
        }

        if let summary = note.summary, !summary.isEmpty {
          labeledBlock(title: "总结", text: summary) {
            copyButton(label: "复制", hint: "已复制总结") { summary }
          }
        }

        if let translation = note.translation, !translation.isEmpty {
          labeledBlock(title: "翻译", text: translation) {
            copyButton(label: "复制", hint: "已复制翻译") { translation }
          }
        }

        if let transcript = note.transcript, !transcript.isEmpty {
          labeledBlock(title: NotesViewModel.transcriptSectionTitle(for: transcript), text: transcript) {
            copyButton(label: "复制", hint: "已复制转写") { transcript }
          }
        }

        labeledBlock(
          title: note.kind == .link ? "原文" : "正文",
          text: note.body
        ) {
          copyButton(
            label: "复制",
            hint: note.kind == .link ? "已复制原文" : "已复制正文"
          ) { note.body }
        }
      }
      .padding()
    }
    .navigationTitle(kindTitle)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if model.isGenerating {
          Button("停止") {
            model.cancelGeneration()
          }
        }

        if note.kind == .link || !note.body.isEmpty {
          Button {
            Task {
              await model.summarizeNote(note)
              refreshNote()
            }
          } label: {
            if model.isSummarizing {
              ProgressView()
            } else {
              Text(note.summary?.isEmpty == false ? "重新总结" : "总结")
            }
          }
          .disabled(model.isGenerating)

          Button {
            Task {
              await model.translateNote(note)
              refreshNote()
            }
          } label: {
            if model.isTranslating {
              ProgressView()
            } else {
              Text(note.translation?.isEmpty == false ? "重新翻译" : "翻译")
            }
          }
          .disabled(model.isGenerating)

          Button {
            Task {
              await model.transcribeNote(note)
              refreshNote()
            }
          } label: {
            if model.isTranscribing {
              ProgressView()
            } else {
              Text(
                NotesViewModel.transcribeActionTitle(
                  for: note,
                  hasExisting: note.transcript?.isEmpty == false
                )
              )
            }
          }
          .disabled(model.isGenerating)

          if note.kind == .link, note.sourceURL != nil {
            Button {
              Task {
                await model.requestMacTranscription(note)
                refreshNote()
              }
            } label: {
              Text(
                note.transcriptionRequestedAtMilliseconds == nil
                  ? "请 Mac 转写"
                  : "已排队 Mac"
              )
            }
            .disabled(model.isGenerating)
          }
        }

        Menu("复制") {
          Button("总结") {
            copy(note.summary ?? "", hint: "已复制总结")
          }
          .disabled((note.summary ?? "").isEmpty)

          Button("翻译") {
            copy(note.translation ?? "", hint: "已复制翻译")
          }
          .disabled((note.translation ?? "").isEmpty)

          Button("转写") {
            copy(note.transcript ?? "", hint: "已复制转写")
          }
          .disabled((note.transcript ?? "").isEmpty)

          Button(note.kind == .link ? "原文" : "正文") {
            copy(
              note.body,
              hint: note.kind == .link ? "已复制原文" : "已复制正文"
            )
          }
          .disabled(note.body.isEmpty)

          if note.sourceURL != nil {
            Button("标题+链接") {
              copy(titleAndLinkClipboardText, hint: "已复制标题与链接")
            }
          }
        }
      }
      ToolbarItem(placement: .destructiveAction) {
        Button("删除", role: .destructive) {
          Task {
            await model.delete(note)
          }
        }
      }
    }
    .overlay(alignment: .top) {
      if let copyHint {
        Text(copyHint)
          .font(.caption)
          .padding(8)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(.top, 8)
      }
    }
    .alert(
      "生成失败",
      isPresented: Binding(
        get: { model.summarizeError != nil },
        set: { if !$0 { model.clearSummarizeError() } }
      )
    ) {
      Button("好", role: .cancel) { model.clearSummarizeError() }
    } message: {
      Text(model.summarizeError ?? "")
    }
  }

  private var kindTitle: String {
    switch note.kind {
    case .text: "文字笔记"
    case .voice: "口述笔记"
    case .link: "链接笔记"
    }
  }

  private var titleAndLinkClipboardText: String {
    let url = note.sourceURL ?? ""
    if url.isEmpty { return note.title }
    return "\(note.title)\n\(url)"
  }

  private func refreshNote() {
    if let refreshed = model.notes.first(where: { $0.id == note.id }) {
      note = refreshed
    }
  }

  private func labeledBlock(
    title: String,
    text: String,
    @ViewBuilder trailing: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer(minLength: 8)
        trailing()
      }
      Text(text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func copyButton(label: String, hint: String, text: @escaping () -> String) -> some View {
    Button(label) {
      copy(text(), hint: hint)
    }
    .font(.caption.weight(.medium))
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func copy(_ text: String, hint: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
    copyHint = hint
    Task {
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      if copyHint == hint { copyHint = nil }
    }
  }
}
