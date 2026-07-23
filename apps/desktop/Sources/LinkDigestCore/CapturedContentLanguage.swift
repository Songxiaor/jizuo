import Foundation

/// A deliberately conservative, local-only script detector for the UI gate.
/// It returns nil rather than guessing when no script is dominant, so a user
/// is never prevented from translating mixed-language or uncommon-language
/// content.
public enum CapturedContentLanguage: String, Sendable, Equatable {
  case chinese
  case japanese
  case korean
  case latin

  public static func detect(in text: String) -> CapturedContentLanguage? {
    var han = 0
    var hiraganaKatakana = 0
    var hangul = 0
    var latin = 0
    var unknown = 0
    var alphabetic = 0
    for scalar in text.unicodeScalars {
      guard scalar.properties.isAlphabetic else { continue }
      alphabetic += 1
      switch scalar.value {
      case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
      case 0x3040...0x30FF, 0x31F0...0x31FF: hiraganaKatakana += 1
      case 0xAC00...0xD7AF: hangul += 1
      case 0x0041...0x005A, 0x0061...0x007A: latin += 1
      default: unknown += 1
      }
    }
    // Han is shared by Chinese and Japanese. Any amount of kana makes a
    // Chinese classification ambiguous unless kana itself is a substantial,
    // clearly dominant Japanese signal. False negatives only leave Translate
    // available; false positives would take a user action away.
    if hiraganaKatakana > 0 {
      let japaneseScore = han + hiraganaKatakana
      guard
        hiraganaKatakana >= 12,
        hiraganaKatakana * 2 >= han,
        hasClearUniqueAdvantage(
          japaneseScore,
          over: [latin, hangul, unknown],
          totalAlphabetic: alphabetic
        )
      else {
        return nil
      }
      return .japanese
    }

    let candidates: [(CapturedContentLanguage, Int)] = [
      (.chinese, han),
      (.korean, hangul),
      (.latin, latin)
    ].sorted { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.0.rawValue < rhs.0.rawValue : lhs.1 > rhs.1
    }
    guard let dominant = candidates.first else { return nil }
    let competitors = candidates.dropFirst().map(\.1) + [unknown]
    guard hasClearUniqueAdvantage(
      dominant.1,
      over: competitors,
      totalAlphabetic: alphabetic
    ) else {
      return nil
    }
    return dominant.0
  }

  private static func hasClearUniqueAdvantage(
    _ leading: Int,
    over competitors: [Int],
    totalAlphabetic: Int
  ) -> Bool {
    guard totalAlphabetic > 0, leading >= 12 else { return false }
    guard leading * 100 >= totalAlphabetic * 60 else { return false }
    return competitors.allSatisfy { leading >= $0 * 2 }
  }

  public static func outputLanguage(_ value: String) -> CapturedContentLanguage? {
    let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.contains("中文") || normalized.contains("chinese") { return .chinese }
    if normalized.contains("日本") || normalized.contains("japanese") { return .japanese }
    if normalized.contains("한국") || normalized.contains("korean") { return .korean }
    if normalized.contains("english") || normalized == "英语" { return .latin }
    return nil
  }

  public static func isSameOutputLanguage(content: String, outputLanguage value: String) -> Bool {
    guard let detected = detect(in: content), let target = outputLanguage(value) else {
      return false
    }
    return detected == target
  }
}
