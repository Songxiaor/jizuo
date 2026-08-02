import LinkDigestCore
import SwiftUI

/// 阶段进度条。
///
/// 它不是装饰——回答的是「今天该在这件事上干什么」，也让搁置了三天的那件
/// 不至于被忘掉。四格固定，`done` 不占位：完成是终点，不是第五步。
struct PieceStageTrack: View {
  let stage: PieceStage
  var showsLabels = true

  private var currentIndex: Int {
    // 已完成时整条点亮：它走完了全程。
    stage == .done ? PieceStage.track.count : (stage.trackIndex ?? 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        ForEach(Array(PieceStage.track.enumerated()), id: \.offset) { index, _ in
          if index > 0 {
            Rectangle()
              .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.25))
              .frame(height: 1.5)
          }
          Circle()
            .fill(index <= currentIndex ? Color.accentColor : Color.clear)
            .frame(width: 8, height: 8)
            .overlay(
              Circle().strokeBorder(
                index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.45),
                lineWidth: 1.5
              )
            )
            // 当前那一格加一圈光晕，扫一眼就知道停在哪。
            .background(
              Circle()
                .fill(Color.accentColor.opacity(index == currentIndex ? 0.18 : 0))
                .frame(width: 16, height: 16)
            )
        }
      }
      .accessibilityElement()
      .accessibilityLabel("阶段 \(stage.displayName)")

      if showsLabels {
        HStack(spacing: 0) {
          ForEach(Array(PieceStage.track.enumerated()), id: \.offset) { index, item in
            Text(item.displayName)
              .font(.system(size: 10))
              .foregroundStyle(index == currentIndex ? Color.accentColor : Color.secondary.opacity(0.6))
              .fontWeight(index == currentIndex ? .semibold : .regular)
              .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : (index == PieceStage.track.count - 1 ? .trailing : .center))
          }
        }
        .accessibilityHidden(true)
      }
    }
  }
}

/// 首页那张卡片:一件创作现在长到哪了。
struct PieceCard: View {
  let piece: PieceSummary
  let isSelected: Bool

  private var stageColor: Color {
    switch piece.stage {
    case .done: .secondary
    case .draft, .polish: .accentColor
    default: .secondary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(piece.stage.displayName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(piece.stage == .done ? Color.secondary : Color.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(
            Capsule().fill(piece.stage == .done ? Color.clear : Color.accentColor)
          )
          .overlay(
            Capsule().strokeBorder(
              piece.stage == .done ? Color.secondary.opacity(0.5) : Color.clear
            )
          )
        Text(piece.title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }

      // 已发出的不再显示进度条:它已经不需要「下一步」了。
      if piece.stage != .done {
        PieceStageTrack(stage: piece.stage)
      }

      HStack(spacing: 6) {
        if piece.materialCount > 0 {
          Text("素材 \(piece.materialCount)")
        }
        if piece.bodyLength > 0 {
          Text("·")
          Text("\(piece.bodyLength) 字")
        }
        if piece.materialCount == 0, piece.bodyLength == 0 {
          Text("还只是一句话")
        }
        Spacer(minLength: 0)
      }
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .monospacedDigit()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06),
          lineWidth: 1
        )
    )
    .contentShape(Rectangle())
  }
}

/// 工作台首页:我手上有哪几件,各自到哪一步了。
struct WorkbenchListView: View {
  @ObservedObject var model: HistoryViewModel
  let onNewSpark: () -> Void
  let onTakeTopic: (TopicCandidate) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 第一层:按天滚动的选题板，永远在长。第二层(进行中的创作)在它下面。
      TopicBoardView(model: model, onTake: onTakeTopic)
      Divider()
      HStack {
        Text("在做的")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(activeCountLabel)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      if model.pieces.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(model.pieces) { piece in
              PieceCard(piece: piece, isSelected: model.selectedPieceID == piece.id)
                .onTapGesture { model.selectedPieceID = piece.id }
                .contextMenu {
                  Button("删除这件创作（保留稿子）", role: .destructive) {
                    model.deletePiece(id: piece.id)
                  }
                }
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
        }
        .subtleScrollers()
      }

      Divider()
      MethodLibraryView(model: model)
      Divider()
      Button(action: onNewSpark) {
        HStack(spacing: 6) {
          Image(systemName: "plus.circle")
          Text("记一个新灵感")
          Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("workbench-new-spark")
    }
  }

  private var activeCountLabel: String {
    let active = model.pieces.filter { !$0.isFinished }.count
    return active > 0 ? "进行中 \(active)" : ""
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "lightbulb")
        .font(.system(size: 26))
        .foregroundStyle(.tertiary)
      Text("还没有在做的创作")
        .font(.callout.weight(.medium))
      // 说清楚这里跟「笔记」的分别，否则用户不知道该往哪写。
      Text("一个念头写下来就是一件创作，\n它会跟着你收集素材、起草、打磨一路长大。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
