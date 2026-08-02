import LinkDigestCore
import SwiftUI

/// 阶段进度条。
///
/// 它不是装饰——回答的是「今天该在这件事上干什么」，也让搁置了三天的那件
/// 不至于被忘掉。四格固定，`done` 不占位：完成是终点，不是第五步。
struct PieceStageTrack: View {
  let stage: PieceStage
  var showsLabels = true
  /// 传了它，这条进度条本身就是切换阶段的控件：点圆点或下面那个词直接跳，
  /// 再点当前这格回到自动判断。
  ///
  /// 不传就是纯指示。列表卡片走的是这条——那里点击应该落到卡片上打开创作，
  /// 一张卡里再嵌四个可点的小目标，等于让人在两种点击之间猜。
  var onSelect: ((PieceStage?) -> Void)?

  private var isInteractive: Bool { onSelect != nil }

  private var currentIndex: Int {
    // 已完成时整条点亮：它走完了全程。
    stage == .done ? PieceStage.track.count : (stage.trackIndex ?? 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 0) {
        ForEach(Array(PieceStage.track.enumerated()), id: \.offset) { index, item in
          if index > 0 {
            Rectangle()
              .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.25))
              .frame(height: 1.5)
          }
          dot(index: index, item: item)
        }
      }
      .accessibilityElement(children: isInteractive ? .contain : .ignore)
      .accessibilityLabel(isInteractive ? "阶段" : "阶段 \(stage.displayName)")

      if showsLabels {
        HStack(spacing: 0) {
          ForEach(Array(PieceStage.track.enumerated()), id: \.offset) { index, item in
            label(index: index, item: item)
          }
        }
        // 可点的时候标题就是主要的点击目标（8pt 的圆点太小），
        // 它必须留在无障碍树里；纯指示时才藏起来。
        .accessibilityHidden(!isInteractive)
      }
    }
  }

  private var visualSize: CGFloat { isInteractive ? 22 : 8 }

  @ViewBuilder private func dot(index: Int, item: PieceStage) -> some View {
    let isFilled = index <= currentIndex
    let visual = Circle()
      .fill(isFilled ? Color.accentColor : Color.clear)
      .frame(width: 8, height: 8)
      .overlay(
        Circle().strokeBorder(
          isFilled ? Color.accentColor : Color.secondary.opacity(0.45),
          lineWidth: 1.5
        )
      )
      // 当前那一格加一圈光晕，扫一眼就知道停在哪。
      .background(
        Circle()
          .fill(Color.accentColor.opacity(index == currentIndex ? 0.18 : 0))
          .frame(width: 16, height: 16)
      )

    if isInteractive {
      Button { onSelect?(stage == item ? nil : item) } label: {
        // 可见的圆点只有 8pt，直接拿它当点击目标会让人点三次才中一次。
        // 撑到 22pt 的透明命中区，视觉不变。
        visual
          .frame(width: visualSize, height: visualSize)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(stage == item ? "再点一次回到自动判断" : "把这件创作标到「\(item.displayName)」")
      .accessibilityLabel(item.displayName)
    } else {
      visual
    }
  }

  @ViewBuilder private func label(index: Int, item: PieceStage) -> some View {
    let alignment: Alignment =
      index == 0 ? .leading : (index == PieceStage.track.count - 1 ? .trailing : .center)
    let text = Text(item.displayName)
      .font(.system(size: 10))
      .foregroundStyle(index == currentIndex ? Color.accentColor : Color.secondary.opacity(0.6))
      .fontWeight(index == currentIndex ? .semibold : .regular)

    if isInteractive {
      Button { onSelect?(stage == item ? nil : item) } label: {
        text
          .frame(maxWidth: .infinity, alignment: alignment)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(stage == item ? "再点一次回到自动判断" : "把这件创作标到「\(item.displayName)」")
    } else {
      text.frame(maxWidth: .infinity, alignment: alignment)
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
      // 三块共用一个滚动容器,而不是各自一个。
      //
      // 它们全都会长高:选题板按天追加、创作越攒越多、方法库展开后是一整个
      // 表单加一张列表。谁都不知道自己该占多高,所以谁也不能被钉成固定高度。
      // 之前只有「在做的」那块有滚动条,于是方法库一展开,整列的高度需求就
      // 超过了窗口——SwiftUI 会把超出的内容居中溢出,表现是整个窗口(连侧栏
      // 和标题栏)一起被顶上去,看起来像"全部错位"。
      ScrollView {
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

          Divider()
          MethodLibraryView(model: model)
        }
      }
      .subtleScrollers()

      // 「记一个新灵感」留在滚动区外:它是这一栏唯一随时都该够得着的动作，
      // 滚到底才能记的灵感，多半已经忘了。
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
    // 在滚动容器里不能要 maxHeight: .infinity——那是「我要所有剩下的高度」，
    // 而滚动区没有「剩下的高度」这个概念。给一个够站得住的最小高度就行。
    .frame(maxWidth: .infinity, minHeight: 160)
    .padding(24)
  }
}
