import SwiftUI
import LinkDigestCore

/// 汲作的六道工序。每道一枚印（2026-09-28 工序印样稿第五版）。
enum ProcessStep: String, CaseIterable, Identifiable, Hashable {
  case record
  case proof
  case comments
  case summary
  case translation
  case mindMap

  var id: String { rawValue }

  var glyph: SealMark.Glyph {
    switch self {
    case .record: .record
    case .proof: .proof
    case .comments: .comments
    case .summary: .summary
    case .translation: .translation
    case .mindMap: .mindMap
    }
  }

  /// 工序名：和按钮、进度提示用同一个词。
  var title: String {
    switch self {
    case .record: "转写"
    case .proof: "校对"
    case .comments: "评论"
    case .summary: "总结"
    case .translation: "翻译"
    case .mindMap: "脑图"
    }
  }

  /// 做完那一刻的一句话。
  var completionMessage: String {
    switch self {
    case .record: "转写好了"
    case .proof: "校对好了"
    case .comments: "评论存好了"
    case .summary: "总结好了"
    case .translation: "翻译好了"
    case .mindMap: "脑图生成好了"
    }
  }

  /// 手盖的章总有一点歪；每枚印歪的方向固定，不随刷新变。
  var rotation: Double {
    switch self {
    case .record: -1.5
    case .proof: 1.2
    case .comments: -0.6
    case .summary: 1.8
    case .translation: -1.1
    case .mindMap: 0.8
    }
  }
}

/// 一道做过的工序：什么时候做的、用什么做的（有记录才写，不编）。
struct ProcessStepRecord: Equatable, Identifiable {
  let step: ProcessStep
  let date: Date?
  let note: String?

  var id: ProcessStep { step }

  /// 悬停说明：「摘 · 总结 · 9月28日 11:02 · DeepSeek v4 Flash」。
  var provenance: String {
    var parts = ["\(step.glyph.rawValue) · \(step.title)"]
    if let date { parts.append(Self.format(date)) }
    if let note, !note.isEmpty { parts.append(note) }
    if date == nil, note == nil { parts.append("已做") }
    return parts.joined(separator: " · ")
  }

  /// 这条内容做过的工序，按先后。题跋上的章和扩展弹窗的「做到哪了」共用这一处判断。
  static func completed(in detail: HistoryDetailProjection, mindMap: TaskMindMapRecord?) -> [ProcessStepRecord] {
    func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    let transcriptKind = CapturedDocument.Origin.localTranscription.rawValue
    var records: [ProcessStepRecord] = []
    // 取最近一次：重新转写、重新抓评论后时间跟着变，盖章那一刻也靠它认出「刚重做完」。
    if let machine = detail.snapshots.last(where: { $0.sourceKind == transcriptKind && $0.captureMethod != tidyCaptureMethod }) {
      records.append(.init(step: .record, date: date(machine.capturedAtMilliseconds), note: nil))
    }
    if let tidy = detail.snapshots.last(where: { $0.captureMethod == tidyCaptureMethod }) {
      records.append(.init(step: .proof, date: date(tidy.capturedAtMilliseconds), note: nil))
    }
    if let withComments = detail.snapshots.last(where: { $0.bodyText.contains("\n## 评论") }) {
      records.append(.init(step: .comments, date: date(withComments.capturedAtMilliseconds), note: savedCommentsNote(withComments.bodyText)))
    }
    for (step, kind) in [(ProcessStep.summary, RunKind.summarize), (.translation, .translate)] {
      if let latest = detail.runs.reversed().first(where: { $0.run.kind == kind && !($0.artifact?.bodyText.isEmpty ?? true) }),
         let artifact = latest.artifact {
        records.append(.init(step: step, date: date(artifact.updatedAtMilliseconds), note: latest.run.model))
      }
    }
    if let mindMap, mindMap.taskID == detail.task.id {
      records.append(.init(step: .mindMap, date: date(mindMap.createdAtMilliseconds), note: mindMap.model))
    }
    return records
  }

  /// 转写整理产物的 captureMethod：有它就算「校」过。
  static let tidyCaptureMethod = "openai_compatible_chat_tidy"

  /// 「## 评论（已保存 20 条 / 页面显示 46）」→「存了 20 条」。
  static func savedCommentsNote(_ body: String) -> String? {
    guard let range = body.range(of: #"## 评论（已保存 (\d+) 条"#, options: .regularExpression) else { return nil }
    let digits = body[range].filter(\.isNumber)
    return digits.isEmpty ? nil : "存了 \(digits) 条"
  }

  static func format(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    return String(format: "%d月%d日 %02d:%02d", parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0)
  }

  /// 做过的时间，面板右侧用：今天只写时刻，别的日子写月日。
  static func shortFormat(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      let parts = calendar.dateComponents([.hour, .minute], from: date)
      return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(parts.month ?? 1)月\(parts.day ?? 1)日"
  }
}

/// 盖下的那一刻：印从稍大、透明压下来，微微回弹后停住（约 0.3 秒）。
/// 整个 App 只有这一处动效；系统开了「减少动态效果」时直接出现。
struct SealStampView: View {
  let glyph: SealMark.Glyph
  var size: CGFloat = 32
  let color: Color
  var rotation: Double = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var landed = false

  var body: some View {
    SealMark(glyph: glyph, size: size, color: color, style: .stamped, rotation: rotation)
      .scaleEffect(landed || reduceMotion ? 1 : 1.35)
      .opacity(landed || reduceMotion ? 1 : 0)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { landed = true }
      }
  }
}

/// 「处理」面板里的一行：印 + 动作 + 右侧状态。
struct ProcessStepRow: View {
  enum State: Equatable {
    /// 还没做：印位，右侧「去做」。
    case pending
    /// 正在做：印位 + 进度字样。
    case running(String)
    /// 上次失败：印位 + 原因。
    case failed(String)
    /// 做过了：盖好的章 + 时间。
    case done(String)
  }

  let step: ProcessStep
  let title: String
  let state: State
  let isEnabled: Bool
  let help: String
  let sealColor: Color
  let primaryText: Color
  let secondaryText: Color
  let identifier: String
  let action: () -> Void

  @SwiftUI.State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        seal
          .frame(width: 28, height: 28)
        Text(title)
          .themedFont(.body)
          .foregroundStyle(isDone ? secondaryText : primaryText)
          .lineLimit(1)
        Spacer(minLength: 12)
        trailing
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isHovered && isEnabled ? sealColor.opacity(0.07) : .clear)
      )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.5)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityIdentifier(identifier)
  }

  private var isDone: Bool { if case .done = state { true } else { false } }

  @ViewBuilder private var seal: some View {
    if isDone {
      SealMark(glyph: step.glyph, size: 26, color: sealColor, style: .stamped, rotation: step.rotation)
    } else {
      SealMark(glyph: step.glyph, size: 26, color: sealColor.opacity(0.75), style: .pending)
    }
  }

  @ViewBuilder private var trailing: some View {
    switch state {
    case .pending:
      Text("去做").themedFont(.caption).foregroundStyle(sealColor)
    case let .running(text):
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(text).themedFont(.caption).foregroundStyle(secondaryText).lineLimit(1)
      }
    case let .failed(reason):
      Text(reason).themedFont(.caption).foregroundStyle(sealColor).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: 150, alignment: .trailing)
    case let .done(when):
      Text(when).themedFont(.caption, monospacedDigit: true).foregroundStyle(secondaryText)
    }
  }
}
