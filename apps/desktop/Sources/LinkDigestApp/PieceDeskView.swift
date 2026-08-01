import LinkDigestCore
import SwiftUI

/// 单件创作台：左边是攒到的素材，右边是正在长出来的稿子。
///
/// 灵感原句钉在最上面——写到第三天很容易偏离，那句话是锚。
struct PieceDeskView: View {
  @ObservedObject var model: HistoryViewModel
  let piece: PieceSummary
  /// 打开正文那条笔记（复用现有的笔记详情，稿子就是一条笔记）。
  let onOpenNote: (TaskID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HStack(alignment: .top, spacing: 0) {
        materialsColumn
          .frame(width: 240)
        Divider()
        bodyColumn
      }
    }
  }

  // MARK: - 顶部：灵感与阶段

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("灵感")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .textCase(.uppercase)
          .tracking(0.6)
        Text(piece.spark)
          .font(.system(size: 15, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      PieceStageTrack(stage: piece.stage)
        .frame(maxWidth: 320)

      stageControls
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 阶段可以往回退——写到一半发现素材不够，回收集是正常的，不是失败。
  /// 所以这里是一排可点的格子，不是只能前进的「下一步」按钮。
  private var stageControls: some View {
    HStack(spacing: 6) {
      ForEach(PieceStage.track, id: \.self) { stage in
        Button(stage.displayName) {
          model.setStage(piece.stage == stage ? nil : stage, for: piece.id)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: piece.stage == stage ? .semibold : .regular))
        .foregroundStyle(piece.stage == stage ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
          Capsule().fill(piece.stage == stage ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .help(piece.stage == stage ? "再点一次回到自动判断" : "把这件创作标到「\(stage.displayName)」")
      }

      Spacer(minLength: 8)

      if piece.isFinished {
        Button("重新打开") { model.setStage(nil, for: piece.id) }
          .font(.system(size: 11))
      } else {
        Button("标记已发出") { model.finishPiece(id: piece.id) }
          .font(.system(size: 11))
          .accessibilityIdentifier("piece-mark-done")
      }
    }
  }

  // MARK: - 左栏：素材

  private var materialsColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("素材")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .textCase(.uppercase)
          .tracking(0.6)
        Spacer()
        Text("\(piece.materialCount)")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }

      if model.pieceMaterials.isEmpty {
        // 说清楚怎么加，否则这块空白不告诉用户任何事。
        Text("在任意列表里右键条目，\n选「加入工作台」。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 6)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.pieceMaterials) { material in
              materialRow(material)
            }
          }
        }
        .subtleScrollers()
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func materialRow(_ material: PieceMaterial) -> some View {
    Button {
      guard material.isAvailable else { return }
      onOpenNote(material.id)
    } label: {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: material.host == HistoryPlatformDisplay.noteHost ? "square.and.pencil" : "doc.text")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
        Text(material.title)
          .font(.system(size: 12))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .foregroundStyle(material.isAvailable ? Color.primary : Color.secondary)
          .strikethrough(!material.isAvailable)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(material.isAvailable ? "打开这份素材" : "这份素材已不在")
    .contextMenu {
      Button("移出这件创作", role: .destructive) {
        model.removeMaterial(taskID: material.id, from: piece.id)
      }
    }
  }

  // MARK: - 右栏：稿子

  private var bodyColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("稿子")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .textCase(.uppercase)
          .tracking(0.6)
        Spacer()
        Text("\(piece.bodyLength) 字")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }

      // 稿子就是一条笔记，所以不在这里再做一个编辑器——那会变成两个能写的地方，
      // 而两处各存一份迟早对不上。这里只负责把人送过去。
      Button {
        onOpenNote(piece.noteTaskID)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "square.and.pencil")
          Text(piece.bodyLength > 0 ? "继续写" : "开始写")
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.25))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("piece-open-note")

      Text(nextStepHint)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 「今天该干什么」——面板存在的理由就是回答这一句。
  private var nextStepHint: String {
    switch piece.stage {
    case .spark:
      "下一步：找几份能撑住这个念头的素材。"
    case .collect:
      piece.bodyLength > 0
        ? "素材有了，可以开始把它们变成一段有结构的文字。"
        : "已经有 \(piece.materialCount) 份素材。够了就开始起草。"
    case .draft:
      "已经写了 \(piece.bodyLength) 字。写不动的时候，回素材里翻翻。"
    case .polish:
      "在决定能不能发出去。可以在稿子里用「整理排版」过一遍。"
    case .done:
      "已经发出。收到的反馈可以记成新笔记，它会回到素材库。"
    }
  }
}
