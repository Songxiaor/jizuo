import LinkDigestCore
import SwiftUI

/// 每日选题板。
///
/// 方案里的第一层:按天滚动的入口,永远在长。第二层(进行中的创作)在它下面。
///
/// 这块板最大的风险不是产出质量,是**变成负担**:如果 5 条都得读完才能选,
/// AI 只是把「想选题」换成了「审选题」。所以整个界面围绕一件事设计——
/// 否决必须极其便宜,扫一眼标题和一句摘要就能划掉。
struct TopicBoardView: View {
  @ObservedObject var model: HistoryViewModel
  let onTake: (TopicCandidate) -> Void

  @State private var isExpanded = true
  @AppStorage(TopicSchedule.storageKey) private var scheduleRaw = ""
  @AppStorage(TopicSchedule.lastRunKey) private var lastRunAt: Double = 0

  /// 按天分组,新的一天在前。
  private var days: [(day: Int64, candidates: [TopicCandidate])] {
    var order: [Int64] = []
    var grouped: [Int64: [TopicCandidate]] = [:]
    for candidate in model.topicCandidates {
      if grouped[candidate.dayStartMilliseconds] == nil {
        order.append(candidate.dayStartMilliseconds)
      }
      grouped[candidate.dayStartMilliseconds, default: []].append(candidate)
    }
    return order.map { ($0, grouped[$0] ?? []) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isExpanded {
        if days.isEmpty {
          emptyState
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(days, id: \.day) { group in
              dayGroup(group.day, candidates: group.candidates)
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
        }
      }
    }
    .onAppear { runScheduledIfDue() }
  }

  /// 到点了就自动出一次。
  ///
  /// 挂在 onAppear 上而不是开一个定时器:用户没在看的时候跑完，产出也
  /// 只是躺在那——他下次进来照样是「打开就有」。而定时器要处理
  /// App 休眠、时区变化、重复触发，换来的只是早那么几分钟。
  private func runScheduledIfDue() {
    let schedule = TopicSchedule.decoded(from: scheduleRaw)
    let lastRun = lastRunAt > 0 ? Date(timeIntervalSince1970: lastRunAt) : nil
    if model.runScheduledTopicsIfDue(schedule: schedule, lastRun: lastRun, voice: voice) {
      lastRunAt = Date().timeIntervalSince1970
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
          Text("选题板")
            .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("topic-board-toggle")

      Spacer()

      if model.isGeneratingTopics {
        ProgressView().controlSize(.small)
      } else {
        Button("出选题") {
          model.generateTopics(voice: voice)
          lastRunAt = Date().timeIntervalSince1970
        }
          .font(.system(size: 11))
          .buttonStyle(.plain)
          .foregroundStyle(model.canGenerateTopics ? Color.accentColor : Color.secondary)
          .disabled(!model.canGenerateTopics)
          .help(model.topicUnavailableReason() ?? "从素材库里出 5 条不同角度的选题")
          .accessibilityIdentifier("topic-board-generate")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  private var voice: String? { VoiceSettings.decoded(from: voiceSettingsRaw).promptText }

  private func dayGroup(_ day: Int64, candidates: [TopicCandidate]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(Self.dayLabel(day))
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
        // 「一条都没要」本身就是信号，所以那一天也留在板上，不隐藏。
        if candidates.allSatisfy({ $0.verdict == .declined }) {
          Text("一条都没要")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }
      ForEach(candidates) { candidate in
        row(candidate)
      }
    }
  }

  private func row(_ candidate: TopicCandidate) -> some View {
    let isDeclined = candidate.verdict == .declined
    let isTaken = candidate.verdict == .taken
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          if candidate.isOutOfBounds {
            // 每天那条不受偏好约束的。标出来是因为它「看起来不像我会写的」
            // 本来就是它存在的理由——不说明的话，它只会被当成跑偏的一条划掉。
            Text("越界")
              .font(.system(size: 9, weight: .semibold))
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(
                RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.16))
              )
              .foregroundStyle(.orange)
          }
          Text(candidate.title)
            .font(.system(size: 12.5, weight: .medium))
            .strikethrough(isDeclined)
            .foregroundStyle(isDeclined ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        if !candidate.summary.isEmpty, !isDeclined {
          Text(candidate.summary)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)

      if isTaken {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .help("已经从这条开始写了")
      } else if !isDeclined {
        // 两个动作都只有一步。多一次确认，否决就不再便宜了。
        HStack(spacing: 4) {
          Button {
            onTake(candidate)
          } label: {
            Image(systemName: "arrow.right.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("从这条开始写")
          .accessibilityLabel("从「\(candidate.title)」开始写")

          Button {
            model.declineTopic(candidate.id)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tertiary)
          .help("不要这条")
          .accessibilityLabel("划掉「\(candidate.title)」")
        }
        .font(.system(size: 11))
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(isDeclined ? 0.25 : 0.5))
    )
    .opacity(isDeclined ? 0.55 : 1)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("还没出过选题")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      Text("从素材库里找能碰撞的组合，写成几条不同角度的选题。")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
  }

  /// 「今天」「昨天」比日期好读——选题板上多数时候只关心这两天。
  static func dayLabel(_ dayStart: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
    let date = Date(timeIntervalSince1970: Double(dayStart) / 1000)
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? "M月d日" : "yyyy年M月d日"
    return formatter.string(from: date)
  }
}
