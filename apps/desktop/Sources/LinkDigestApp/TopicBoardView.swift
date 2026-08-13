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
  @State private var isRecipeOpen = false
  @AppStorage(TopicSchedule.storageKey) private var scheduleRaw = ""
  @AppStorage(TopicSchedule.lastRunKey) private var lastRunAt: Double = 0
  @AppStorage(TopicRecipe.storageKey) private var recipeRaw = ""
  @Environment(\.appTheme) private var appTheme

  private var recipe: TopicRecipe { TopicRecipe.decoded(from: recipeRaw) }

  /// 把配方的某一项做成 Binding。
  ///
  /// 存的是一整份 JSON,所以每个输入框都要「读出来—改一项—写回去」。
  /// 抽出来是为了让那三步只有一份实现:漏掉写回的那一项，表现是
  /// 用户改了数字、界面也变了，下次打开又回到旧值。
  private func field<Value>(
    _ keyPath: WritableKeyPath<TopicRecipe, Value>
  ) -> Binding<Value> {
    Binding(
      get: { recipe[keyPath: keyPath] },
      set: { newValue in
        var value = recipe
        value[keyPath: keyPath] = newValue
        recipeRaw = value.encoded()
      }
    )
  }

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
      if isRecipeOpen {
        recipeDrawer
      }
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
  ///
  /// 记账挂在「候选真的落库」上，不是「发起了」:模型没跑起来也把今天记成
  /// 跑过，用户白等一天，而他根本不知道今天这一次已经被消耗掉了。
  private func runScheduledIfDue() {
    let schedule = TopicSchedule.decoded(from: scheduleRaw)
    let lastRun = lastRunAt > 0 ? Date(timeIntervalSince1970: lastRunAt) : nil
    model.runScheduledTopicsIfDue(
      schedule: schedule, lastRun: lastRun, recipe: recipe, voice: voice
    ) {
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
            .font(.body.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("topic-board-toggle")

      Spacer()

      // 配方入口长在正在用的这块板上,不进设置页。
      // 「这五条为什么是这五条」的答案,应该在看见那五条的地方点得开。
      Button {
        isRecipeOpen.toggle()
        if !isRecipeOpen { model.topicDryRunResult = nil }
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: DesignTokens.IconSize.inline))
          .foregroundStyle(isRecipeOpen ? Color.accentColor : Color.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isRecipeOpen ? "收起配方" : "看看它读了什么、怎么问的")
      .accessibilityLabel("配方")
      .accessibilityIdentifier("topic-board-recipe")

      if model.isGeneratingTopics {
        ProgressView().controlSize(.small)
      } else {
        Button("出选题") {
          // 手动跑成功同样顶掉今天的定时那一次;失败则不动记账,
          // 到点了照样会自动补一次。
          model.generateTopics(recipe: recipe, voice: voice) {
            lastRunAt = Date().timeIntervalSince1970
          }
        }
          .font(.subheadline)
          .buttonStyle(.plain)
          .foregroundStyle(model.canGenerateTopics ? Color.accentColor : Color.secondary)
          .disabled(!model.canGenerateTopics)
          .help(model.topicUnavailableReason() ?? "按当前配方从素材库里出选题")
          .accessibilityIdentifier("topic-board-generate")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - 配方

  private var recipeDrawer: some View {
    VStack(alignment: .leading, spacing: 12) {
      recipeSection("① 读哪些素材") {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 5) {
            Text("最近")
            numberField(field(\.recentDays), width: 38)
            Text("天内，取")
            numberField(field(\.recentLimit), width: 38)
            Text("条")
            Spacer(minLength: 0)
          }
          HStack(spacing: 5) {
            numberField(field(\.dormantSinceDays), width: 38)
            Text("天没碰过的，取")
            numberField(field(\.dormantLimit), width: 38)
            Text("条")
            Spacer(minLength: 0)
          }
          // 两路而不是一路,是因为碰撞需要距离。这句话得让用户看得到,
          // 否则他会先把旧的那一路关掉——它看起来最像多余的。
          Text("两路分开是为了让远的和近的能撞上。取 0 条就是关掉那一路。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 5) {
            Text("只要标签")
            TextField("留空 = 全部，多个用逗号分开", text: tagsField)
              .textFieldStyle(.roundedBorder)
              .font(.subheadline)
            Spacer(minLength: 0)
          }
          HStack(spacing: 5) {
            Text("每份摘录")
            numberField(field(\.excerptLimit), width: 48)
            Text("字")
            Spacer(minLength: 0)
          }
        }
      }

      recipeSection("② 怎么问") {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(recipe.isTemplateCustomized ? "我的版本" : "预置 · 只读")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(recipe.isTemplateCustomized ? Color.accentColor : Color.secondary)
            Spacer(minLength: 0)
            if recipe.isTemplateCustomized {
              Button("恢复预置") { field(\.template).wrappedValue = nil }
                .font(.caption2)
            } else {
              Button("改成我的版本") {
                field(\.template).wrappedValue = TopicPrompt.presetTemplate
              }
              .font(.caption2)
            }
          }

          if recipe.isTemplateCustomized {
            TextEditor(text: templateField)
              .font(.system(size: 10.5, design: .monospaced))
              .frame(height: 200)
              .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                  .strokeBorder(Color.primary.opacity(0.12))
              )
              .accessibilityIdentifier("topic-recipe-template")
          } else {
            // 只读时也要看得见全文。看不见的默认值和不存在的功能差别不大。
            ScrollView {
              Text(TopicPrompt.presetTemplate)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 140)
            .background(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
          }

          Text("可用变量：" + TopicPrompt.Placeholder.all.map(\.0).joined(separator: " "))
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          Text("变量为空时它那一行会消失；一段只剩标题，整段也消失。")
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      recipeSection("③ 要什么") {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 5) {
            Text("出")
            numberField(field(\.count), width: 38)
            Text("条，其中越界")
            numberField(field(\.boundaryCount), width: 38)
            Text("条")
            Spacer(minLength: 0)
          }
          Text("越界那条不受你的偏好约束。设成 0 就不要了，但回音室也是这么形成的。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 8) {
        if model.isDryRunningTopics {
          ProgressView().controlSize(.small)
          Text("正在试跑…").font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
          Button("试跑一次") { model.dryRunTopics(recipe: recipe, voice: voice) }
            .font(.subheadline)
            .disabled(!model.canGenerateTopics)
            .help("按当前配方跑一次，只看解析出几条，不写进选题板")
            .accessibilityIdentifier("topic-recipe-dry-run")
        }
        Spacer(minLength: 0)
        Button("全部恢复默认") { recipeRaw = "" }
          .font(.subheadline)
          .disabled(recipe == .default)
      }

      if let result = model.topicDryRunResult {
        Text(result)
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("topic-recipe-dry-run-result")
      }
    }
    .font(.system(size: 11))
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private func recipeSection(
    _ title: String, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      content()
    }
  }

  /// 数字输入框。
  ///
  /// 不用 Stepper:这些值改动频率低，但每次改都是「从 7 改成 30」这种
  /// 跨度，点 23 下箭头不合理。夹范围交给 `TopicRecipe.sanitized()`。
  private func numberField(_ binding: Binding<Int>, width: CGFloat) -> some View {
    TextField("", value: binding, format: .number)
      .textFieldStyle(.roundedBorder)
      .font(.subheadline)
      .frame(width: width)
      .multilineTextAlignment(.center)
  }

  private var tagsField: Binding<String> {
    Binding(
      get: { recipe.tags.joined(separator: "，") },
      set: { raw in
        var value = recipe
        value.tags = raw
          .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        recipeRaw = value.encoded()
      }
    )
  }

  private var templateField: Binding<String> {
    Binding(
      get: { recipe.template ?? TopicPrompt.presetTemplate },
      set: { field(\.template).wrappedValue = $0 }
    )
  }

  @AppStorage(VoiceSettings.storageKey) private var voiceSettingsRaw = ""
  private var voice: String? { VoiceSettings.decoded(from: voiceSettingsRaw).promptText }

  private func dayGroup(_ day: Int64, candidates: [TopicCandidate]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(Self.dayLabel(day))
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
        // 「一条都没要」本身就是信号，所以那一天也留在板上，不隐藏。
        if candidates.allSatisfy({ $0.verdict == .declined }) {
          Text("一条都没要")
            .font(.caption2)
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
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(appTheme.warning.opacity(0.16))
              )
              .foregroundStyle(appTheme.warning)
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
            .font(.subheadline)
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
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
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
        .font(.subheadline)
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
