import Foundation

/// 给生成提示词补上输出语言，但不改中文场景下已经钉死的模板正文。
///
/// 总结提示词早已用 `ModelPreferences.summaryPrompt` 追加一句
/// `Write the final answer in …`。选题/起草/整理/脑图这些模板当时没走同一条路，
/// 输出语言设成英文时整段指令仍是中文。这里只在**非中文**时追加一句英文指令；
/// 简体/繁体中文原样返回，保证现有测试和中文产出不变。
public enum PromptOutputLanguage {
  public static func isChinese(_ value: String) -> Bool {
    CapturedContentLanguage.outputLanguage(value) == .chinese
  }

  public static func applying(_ outputLanguage: String, to prompt: String) -> String {
    let language = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let effective = language.isEmpty ? ModelPreferences.defaultTargetLanguage : language
    guard !isChinese(effective) else { return prompt }
    return """
    \(prompt)

    Write all user-visible output in \(effective). Keep required machine-readable field labels, JSON keys, and format markers unchanged so the result can still be parsed.
    """
  }
}
