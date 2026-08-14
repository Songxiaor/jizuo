import Foundation

/// Apple Speech 本机转写用的语言。默认简体中文，和产品上线以来的行为一致；
/// 英文等选项是为了让非中文视频也能听写，而不是跟界面语言绑死。
public enum SpeechTranscriptionLocale: String, CaseIterable, Identifiable, Sendable {
  case simplifiedChinese = "zh_CN"
  case traditionalChinese = "zh_TW"
  case english = "en_US"
  case japanese = "ja_JP"
  case korean = "ko_KR"
  case spanish = "es_ES"
  case french = "fr_FR"
  case german = "de_DE"

  public static let `default` = simplifiedChinese

  public var id: String { rawValue }
  public var localeIdentifier: String { rawValue }

  public var languageCode: String {
    switch self {
    case .simplifiedChinese, .traditionalChinese: "zh"
    case .english: "en"
    case .japanese: "ja"
    case .korean: "ko"
    case .spanish: "es"
    case .french: "fr"
    case .german: "de"
    }
  }

  public var displayName: String {
    switch self {
    case .simplifiedChinese: "简体中文"
    case .traditionalChinese: "繁體中文"
    case .english: "英语"
    case .japanese: "日本語"
    case .korean: "한국어"
    case .spanish: "Español"
    case .french: "Français"
    case .german: "Deutsch"
    }
  }

  public static func resolved(_ stored: String?) -> SpeechTranscriptionLocale {
    guard let stored, let match = Self(rawValue: stored) else { return .default }
    return match
  }
}
