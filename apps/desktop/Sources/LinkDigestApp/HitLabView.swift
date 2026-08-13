import LinkDigestCore
import SwiftUI

/// 爆款实验室:一件创作的盲预测与复盘。
///
/// 挂在创作详情里,因为预测是针对**这一篇**的。整体校准情况在下面那一行。
///
/// 界面上最要紧的一件事:预测写完之后**不给改的入口**。不是防呆,
/// 是这个功能成不成立的前提——能改的话,人会不自觉地往结果的方向修,
/// 然后得出「我判断挺准的」这个毫无价值的结论。
struct HitLabView: View {
  @ObservedObject var model: HistoryViewModel
  let piece: PieceSummary
  @Environment(\.appTheme) private var appTheme

  @State private var predicted: HitPrediction.Tier = .modest
  @State private var reasoning = ""
  @State private var actual: HitPrediction.Tier = .modest
  @State private var review = ""

  private var existing: HitPrediction? { model.hitPrediction(of: piece.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("爆款实验室")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.6)

      if let existing {
        settled(existing)
      } else {
        composer
      }

      // 单看一次预测什么都说明不了——爆没爆很大程度上是运气。
      // 十次里有七次高估，那才是一个关于你自己的稳定事实。
      Text(model.hitCalibration.summary)
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("hit-lab-calibration")
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(appTheme.warning.opacity(0.06))
    )
    .onAppear { model.reloadHitPredictions() }
  }

  /// 还没预测过 —— 写一条。
  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("发出去之前，先猜一下。")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)

      tierPicker(selection: $predicted)

      // 这一栏比预测本身值钱：三天后回头看，「我以为标题够反常」和
      // 「我以为这个话题正热」是两种完全不同的误判，只看档位分不出来。
      TextField("为什么这么猜？", text: $reasoning)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11.5))
        .accessibilityIdentifier("hit-lab-reasoning")

      HStack {
        Spacer(minLength: 0)
        Button("记下来") {
          model.recordHitPrediction(
            pieceID: piece.id, predicted: predicted, reasoning: reasoning
          )
        }
        .font(.subheadline)
        .disabled(reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("记下之后不能改——整个功能靠的就是这个")
        .accessibilityIdentifier("hit-lab-record")
      }
    }
  }

  /// 已经预测过。展示，不给改的入口。
  @ViewBuilder private func settled(_ prediction: HitPrediction) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("你猜：\(prediction.predicted.displayName)")
          .font(.system(size: 11.5, weight: .medium))
        if let actual = prediction.actual {
          Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
          Text("实际：\(actual.displayName)")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prediction.isAccurate ? Color.secondary : appTheme.warning)
        }
        Spacer(minLength: 0)
      }
      if !prediction.reasoning.isEmpty {
        Text(prediction.reasoning)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if prediction.isSettled {
        if !prediction.review.isEmpty {
          Divider()
          Text(prediction.review)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Divider()
        Text("发出去几天之后，回来填真实结果。")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
        tierPicker(selection: $actual)
        TextField("和你想的差在哪？", text: $review)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11.5))
          .accessibilityIdentifier("hit-lab-review")
        HStack {
          Spacer(minLength: 0)
          Button("填结果") {
            model.settleHitPrediction(id: prediction.id, actual: actual, review: review)
          }
          .font(.subheadline)
          .accessibilityIdentifier("hit-lab-settle")
        }
      }
    }
  }

  private func tierPicker(selection: Binding<HitPrediction.Tier>) -> some View {
    Picker("", selection: selection) {
      ForEach(HitPrediction.Tier.allCases, id: \.self) {
        Text($0.displayName).tag($0)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .help(HitPrediction.Tier.allCases.map { "\($0.displayName)：\($0.hint)" }.joined(separator: "　"))
  }
}
