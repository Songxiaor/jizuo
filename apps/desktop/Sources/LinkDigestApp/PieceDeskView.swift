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
  /// 对某份素材跑总结。
  let onRunSummary: (TaskID) -> Void
  /// 对稿子跑整理排版。
  let onTidy: (TaskID) -> Void
  /// 让 Agent 把素材写成初稿。
  let onDraft: (PieceID) -> Void
  let onRewrite: (PieceID, RewritePrompt.Intensity) -> Void
  @AppStorage(ExperimentalFeatures.hitLabKey) private var isHitLabEnabled = false

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
        // 一个字都没写就能标记完成,产出的是一份内容为占位符的「作品」。
        // 置灰而不是藏起来:藏起来会让人以为这个功能不存在。
        Button("标记已发出") { model.finishPiece(id: piece.id) }
          .font(.system(size: 11))
          .disabled(piece.bodyLength == 0)
          .help(piece.bodyLength == 0 ? "还没写正文" : "把这篇收进「我的作品」")
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

      if model.draftingPieceID == piece.id {
        draftingBanner
      }

      Text(nextStepHint)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      stageTools

      // 只在打磨和已发出时出现:更早的阶段稿子还没成形，这时候猜
      // 传播效果，猜的是一个还不存在的东西。
      if isHitLabEnabled, piece.stage == .polish || piece.stage == .done {
        HitLabView(model: model, piece: piece)
          .padding(.top, 4)
      }

      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 起草进行中。
  ///
  /// 流式产出直接往这里刷:一个转圈的图标只说明「在跑」,而看见字一个个
  /// 出来才知道它在写什么、值不值得等下去。
  private var draftingBanner: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        ProgressView().controlSize(.small)
        Text("正在起草…").font(.system(size: 12, weight: .medium))
        Spacer(minLength: 0)
        Button("停止") { model.cancelDrafting() }.font(.system(size: 11))
      }
      if !model.draftingText.isEmpty {
        Text(model.draftingText.suffix(300))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.accentColor.opacity(0.08))
    )
  }

  /// 此刻这个阶段该用的工具。
  ///
  /// 这些能力本来就有,只是原先散在详情页上——一条记录不管处于什么状态,
  /// 那几个按钮永远都在。挪进阶段之后,它们变成「现在这一步该做的事」:
  /// 读长素材时才需要总结,理骨架时才需要脑图,要发出去了才需要整理排版。
  ///
  /// 不做的事:不在这里重复实现任何一个能力,全都调既有入口。
  @ViewBuilder private var stageTools: some View {
    let tools = toolsForCurrentStage
    if !tools.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("这一步可以")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .textCase(.uppercase)
          .tracking(0.6)
        ForEach(tools, id: \.title) { tool in
          Button(action: tool.action) {
            HStack(spacing: 7) {
              Image(systemName: tool.icon).font(.system(size: 11)).frame(width: 14)
              Text(tool.title).font(.system(size: 12.5))
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(tool.isDisabled)
          .help(tool.hint)
        }
      }
      .padding(.top, 4)
    }
  }

  private struct StageTool {
    let title: String
    let icon: String
    let hint: String
    var isDisabled = false
    let action: () -> Void
  }

  private var toolsForCurrentStage: [StageTool] {
    switch piece.stage {
    case .spark:
      // 只有一句话时唯一该做的是去找东西,不该摆一堆用不上的按钮。
      []
    case .collect:
      [
        // 这一步最值钱的动作:把攒到的素材直接变成一篇初稿。
        // 零冷启动——不需要历史数据、不需要先攒判断,当天就有价值。
        StageTool(
          title: model.pieceMaterials.isEmpty ? "就着灵感起草" : "把素材写成初稿",
          icon: "sparkles",
          hint: model.draftUnavailableReason(for: piece.id) ?? "读完素材写一篇,直接写进稿子",
          isDisabled: !model.canDraft(for: piece.id)
        ) { onDraft(piece.id) },
      ] + (model.pieceMaterials.isEmpty ? [] : [
        StageTool(
          title: "总结这些素材",
          icon: "text.alignleft",
          hint: "对每份素材各跑一次总结，长素材不用逐字读",
          isDisabled: model.pieceMaterials.isEmpty
        ) {
          for material in model.pieceMaterials where material.isAvailable {
            onRunSummary(material.id)
          }
        },
      ])
    case .draft:
      [
        StageTool(
          title: "生成脑图理骨架",
          icon: "circle.hexagongrid",
          hint: "把已写的内容画成结构，看哪一节缺东西"
        ) { model.requestMindMapGeneration(taskID: piece.noteTaskID) },
        // 第二块画板。和起草吃同一份表达方式设置。
        StageTool(
          title: "按我的表达方式重写",
          icon: "person.wave.2",
          hint: model.rewriteUnavailableReason(for: piece.id)
            ?? "照「我的表达方式」把全文改一遍；事实和数据不动",
          isDisabled: !model.canRewrite(for: piece.id)
        ) { onRewrite(piece.id, .rewrite) },
      ]
    case .polish:
      [
        // 打磨阶段用轻的那一档:这时候结构已经定了，只该顺语感。
        StageTool(
          title: "顺一遍语感",
          icon: "person.wave.2",
          hint: model.rewriteUnavailableReason(for: piece.id)
            ?? "保留段落顺序和小标题，只调措辞与断句",
          isDisabled: !model.canRewrite(for: piece.id)
        ) { onRewrite(piece.id, .polish) },
        StageTool(
          title: "整理排版",
          icon: "wand.and.stars",
          hint: model.noteTidyUnavailableReason(taskID: piece.noteTaskID)
            ?? "重排段落、列表与标题层级；不改文字内容",
          isDisabled: !model.canTidyNote(taskID: piece.noteTaskID)
        ) {
          onTidy(piece.noteTaskID)
        },
      ]
    case .done:
      []
    }
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
