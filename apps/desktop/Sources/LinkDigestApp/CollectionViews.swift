import SwiftUI
import LinkDigestCore

// MARK: - 合集（2026-09-29 第一期）
//
// 合集 = 一组要放在一起看、有顺序的内容，例如「Claude Code 教程 12 讲」。
// 这个文件放三样东西：菜单项（列表右键、卡片「更多」、阅读页「⋯」共用）、
// 新建 / 改名 / 删除的弹窗，以及加入 / 移出之后浮在窗口底部的一句提示。
// 侧栏那一组写在 `HistoryContentView.navigationRail` 里，和其它分组共用行样式。

/// 合集相关的图标。线性的「一叠」：合集是好几条摞在一起，不是一个文件夹。
enum CollectionIcon {
  static let collection = "rectangle.stack"
  static let add = "rectangle.stack.badge.plus"
  static let remove = "rectangle.stack.badge.minus"
}

/// 合集的弹窗。放在 view model 上而不是各视图的 @State：阅读页「⋯」和列表右键
/// 都要能弹「新建合集…」，而它们是两棵不同的视图树。
enum CollectionPrompt: Equatable {
  /// 新建；带着 id 时建好后把这几条放进去。
  case create(adding: [TaskID])
  case rename(HistoryCollectionSummary)
  case delete(HistoryCollectionSummary)

  var isNameInput: Bool {
    switch self {
    case .create, .rename: true
    case .delete: false
    }
  }
}

/// 「加入合集 ▸」和「从此合集移出」。
struct CollectionMenuItems: View {
  let model: HistoryViewModel
  /// 这次要作用的内容，按要加入的顺序。
  let taskIDs: [TaskID]

  var body: some View {
    if model.canEditCollections, !taskIDs.isEmpty {
      // 右键的那条（多选时是整批都在）已经在里面的合集打勾、置灰；
      // 多选时只有一部分在里面的不打勾，加入时自动跳过已在的。
      let members = model.collectionIDs(containingAll: taskIDs)
      Menu {
        ForEach(model.collections) { collection in
          let isMember = members.contains(collection.id)
          Button {
            model.addToCollection(collection.id, taskIDs: taskIDs)
          } label: {
            Label(collection.name, systemImage: isMember ? "checkmark" : CollectionIcon.collection)
          }
          .disabled(isMember)
        }
        if !model.collections.isEmpty { Divider() }
        Button {
          model.requestNewCollection(adding: taskIDs)
        } label: {
          Label("新建合集…", systemImage: "plus")
        }
        .accessibilityIdentifier("history-collection-create-with-items")
      } label: {
        Label("加入合集", systemImage: CollectionIcon.add)
      }
      .accessibilityIdentifier("history-context-add-to-collection")
      if let current = model.selectedCollection {
        Button {
          model.removeFromSelectedCollection(taskIDs: taskIDs)
        } label: {
          Label(
            "移出合集",
            systemImage: CollectionIcon.remove
          )
        }
        .help("内容不会删除")
        .accessibilityIdentifier("history-context-remove-from-collection")
      }
    }
  }
}

/// 新建 / 改名 / 删除合集的弹窗，和加入之后的提示条。挂在历史窗口根部。
struct CollectionPromptsModifier: ViewModifier {
  @Bindable var model: HistoryViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .alert(nameAlertTitle, isPresented: nameInputPresented) {
        TextField("合集名称", text: $model.collectionNameDraft)
          .accessibilityIdentifier("history-collection-name-field")
        Button(nameConfirmTitle) { model.confirmCollectionPrompt() }
        Button("取消", role: .cancel) { model.cancelCollectionPrompt() }
      } message: {
        Text(nameAlertMessage)
      }
      // 第二个弹窗挂在一层透明背景上：同一个视图挂两个 alert，旧系统上只有后挂的那个会弹。
      .background {
        Color.clear
          .alert(deleteAlertTitle, isPresented: deletePresented) {
            Button("删除合集", role: .destructive) { model.confirmCollectionPrompt() }
            Button("取消", role: .cancel) { model.cancelCollectionPrompt() }
          } message: {
            Text("不会删除里面的内容，只是不再把它们放在一起。")
          }
      }
      .overlay(alignment: .bottom) {
        if let feedback = model.collectionFeedback {
          // 带「撤销」的提示（删除后）要能点，其余提示仍然不挡鼠标（2026-10-01）。
          HStack(spacing: 12) {
            Label(feedback, systemImage: model.collectionFeedbackSymbol)
              .lineLimit(2)
            if model.canUndoFeedback {
              Button("撤销") { model.undoFeedbackAction() }
                .buttonStyle(.plain)
                .themedFont(.callout, weight: .semibold)
                .foregroundStyle(.tint)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("history-feedback-undo")
            }
          }
            .themedFont(.callout, weight: .medium)
            .padding(.vertical, 8).padding(.horizontal, 16)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
            .padding(.bottom, 28)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .allowsHitTesting(model.canUndoFeedback)
            .accessibilityIdentifier("history-collection-feedback")
        }
      }
      .animation(historyUIAnimation(reduceMotion: reduceMotion), value: model.collectionFeedback)
  }

  /// 弹窗被系统收起（按 Esc、窗口关掉）时也要把状态清掉，否则下次渲染又弹出来。
  /// 放到下一拍再清：按钮的动作和这里的「收起」谁先到不固定，先清了按钮就读不到弹窗了。
  private func dismissBinding(_ matches: @escaping (CollectionPrompt) -> Bool) -> Binding<Bool> {
    Binding(
      get: { model.collectionPrompt.map(matches) ?? false },
      set: { presented in
        guard !presented, let prompt = model.collectionPrompt, matches(prompt) else { return }
        DispatchQueue.main.async {
          if model.collectionPrompt == prompt { model.cancelCollectionPrompt() }
        }
      }
    )
  }

  private var nameInputPresented: Binding<Bool> { dismissBinding { $0.isNameInput } }
  private var deletePresented: Binding<Bool> { dismissBinding { !$0.isNameInput } }

  private var nameAlertTitle: String {
    if case .rename = model.collectionPrompt { return "重命名合集" }
    return "新建合集"
  }

  private var nameConfirmTitle: String {
    if case .rename = model.collectionPrompt { return "改名" }
    return "新建"
  }

  private var nameAlertMessage: String {
    switch model.collectionPrompt {
    case let .create(taskIDs) where !taskIDs.isEmpty:
      return taskIDs.count == 1 ? "建好后把这一条放进去。" : "建好后把选中的 \(taskIDs.count) 条按顺序放进去。"
    case .rename:
      return "只改名字，里面的内容和顺序不变。"
    default:
      return "把要按顺序一起看的内容放在一起，例如一套教程。"
    }
  }

  private var deleteAlertTitle: String {
    if case let .delete(collection) = model.collectionPrompt { return "删除合集「\(collection.name)」？" }
    return "删除合集？"
  }
}
