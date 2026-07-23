import Foundation

public enum LocalImageTextRecognitionError: Error, Sendable, Equatable {
  case noImages
  case unreadableImage
  case noText
  case recognitionFailed
  case cancelled

  public var userMessage: String {
    switch self {
    case .noImages: "这条记录没有可识别的本机图片。"
    case .unreadableImage: "图片缓存不可读取，请重新同步后再试。"
    case .noText: "没有在图片中识别到文字。"
    case .recognitionFailed: "图片文字识别未完成，请稍后重试。"
    case .cancelled: "已取消图片文字识别。"
    }
  }
}

public protocol LocalImageTextRecognizing: Sendable {
  /// Reads local cached images only. Implementations must not upload images.
  func recognizeText(in imageURLs: [URL], languages: [String]) async throws -> String
}
