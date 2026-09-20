import Foundation

/// 只把抓取标题译成阅读语言，不改正文、不写入总结/翻译产物。
public protocol TitleLocalizing: Sendable {
  func localize(title: String, body: String?, outputLanguage: String, model: String?) async throws -> String
}

public enum TitleLocalizationPrompt {
  public static func system(outputLanguage: String) -> String {
    """
    Write a concise page title in \(outputLanguage). If the given page title is only a URL or otherwise unhelpful, infer the title from the content excerpt. Otherwise translate the title. Reply with the title only: no quotes, no markdown headings, no explanation, single line.
    """
  }
}

public enum TitleLocalizationError: Error, Equatable {
  case modelNotConfigured
  case emptyResult
  case cancelled
}
