import LinkDigestCore
import SwiftUI

/// 方法库。
///
/// 可复用的写法。启用的会进起草和改写的提示词——这是它和「表达方式」的
/// 分工:表达方式管语感(怎么说),方法管做法(先说什么再说什么)。
///
/// 默认收起。它不是每天要看的东西,而侧栏上面那两块是。
struct MethodLibraryView: View {
  @ObservedObject var model: HistoryViewModel
  @Environment(\.appTheme) private var appTheme

  @State private var isExpanded = false
  @State private var draft = ""
  @State private var rejection: MethodAdmission.Rejection?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isExpanded {
        VStack(alignment: .leading, spacing: 8) {
          composer
          distillSection
          if model.writingMethods.isEmpty {
            emptyState
          } else {
            ForEach(model.writingMethods) { method in
              row(method)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
      }
    }
  }

  private var header: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
        Text("方法库")
          .font(.body.weight(.semibold))
        Spacer(minLength: 0)
        if !model.writingMethods.isEmpty {
          Text("\(model.enabledMethodBodies.count) 条在用")
            .font(.subheadline)
            .appTertiaryText()
            .monospacedDigit()
        }
      }
      .appSecondaryText()
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.appPlain)
    .accessibilityIdentifier("method-library-toggle")
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        TextField("先给一个反直觉的数据，再解释为什么反直觉", text: $draft)
          .textFieldStyle(.roundedBorder)
          .font(.callout)
          .onSubmit(commit)
          .accessibilityIdentifier("method-library-input")
        Button("加入", action: commit)
          .font(.subheadline)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      // 拒绝的理由要能照着改。「不符合规范」等于没说——用户不知道改什么，
      // 下次还是写一样的东西。
      if let rejection {
        Text(rejection.message)
          .font(.system(size: 10.5))
          .foregroundStyle(appTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("method-library-rejection")
      }
    }
  }

  /// 从「AI 写成这样、我改成了那样」里提炼。
  ///
  /// 候选**不直接入库**:提炼是模型给的，而方法会进每一次起草。让它
  /// 自己往库里写，等于把「什么算我的写法」也交出去了。
  @ViewBuilder private var distillSection: some View {
    HStack(spacing: 6) {
      if model.isDistilling {
        ProgressView().controlSize(.small)
        Text("正在从你的修改里找规律…")
          .font(.system(size: 10.5))
          .appSecondaryText()
      } else {
        Button("从我的修改里提炼") { model.distillMethods() }
          .font(.subheadline)
          .buttonStyle(.appPlain)
          .foregroundStyle(model.canDistill ? Color.accentColor : appTheme.secondaryText)
          .disabled(!model.canDistill)
          .help(model.distillUnavailableReason() ?? "对照几篇 AI 写的和你改完的，找出反复出现的差异")
          .accessibilityIdentifier("method-library-distill")
        if let reason = model.distillUnavailableReason(), !model.canDistill {
          Text(reason)
            .font(.caption2)
            .appTertiaryText()
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }

    ForEach(model.distilledCandidates, id: \.self) { candidate in
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: "sparkles")
          .font(.system(size: 9))
          .foregroundStyle(appTheme.warning)
          .padding(.top, 2)
        Text(candidate)
          .font(.system(size: 11.5))
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        Button {
          model.acceptDistilled(candidate)
        } label: {
          Image(systemName: "checkmark")
        }
        .buttonStyle(.appPlain)
        .foregroundStyle(.secondary)
        .help("收下这条")
        .accessibilityLabel("收下「\(candidate)」")
        Button {
          model.dismissDistilled(candidate)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.appPlain)
        .foregroundStyle(.tertiary)
        .help("不要这条")
        .accessibilityLabel("不要「\(candidate)」")
      }
      .font(.system(size: 11))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
          .fill(appTheme.warning.opacity(0.08))
      )
    }
  }

  private func commit() {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if let failed = model.addWritingMethod(text) {
      rejection = failed
      // 不清空输入框:用户要在原文上改，重打一遍是白费。
      return
    }
    draft = ""
    rejection = nil
  }

  private func row(_ method: WritingMethod) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Toggle("", isOn: Binding(
        get: { method.isEnabled },
        set: { model.setWritingMethodEnabled($0, for: method.id) }
      ))
      .toggleStyle(.checkbox)
      .labelsHidden()
      .accessibilityLabel(method.isEnabled ? "停用「\(method.body)」" : "启用「\(method.body)」")

      VStack(alignment: .leading, spacing: 1) {
        Text(method.body)
          .font(.system(size: 11.5))
          .foregroundStyle(method.isEnabled ? Color.primary : appTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
        if method.origin == .distilled {
          Text("从你的修改里提炼")
            .font(.system(size: 9.5))
            .appTertiaryText()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contextMenu {
      Button("删掉这条", role: .destructive) { model.deleteWritingMethod(id: method.id) }
    }
  }

  private var emptyState: some View {
    Text("还没有方法。写下一条能照着做的动作，起草时会一起交给 AI。")
      .font(.subheadline)
      .appTertiaryText()
      .fixedSize(horizontal: false, vertical: true)
  }
}
