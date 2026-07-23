import Foundation
import LinkDigestCore
import Vision

/// On-device OCR for cached article images. Vision receives file URLs only;
/// no Provider credentials or network session enter this adapter.
public struct AppleVisionTextRecognizer: LocalImageTextRecognizing {
  public init() {}

  public func recognizeText(in imageURLs: [URL], languages: [String]) async throws -> String {
    guard !imageURLs.isEmpty else { throw LocalImageTextRecognitionError.noImages }
    return try await Task.detached(priority: .userInitiated) {
      var pages: [String] = []
      for (index, url) in imageURLs.enumerated() {
        try Task.checkCancellation()
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
          throw LocalImageTextRecognitionError.unreadableImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        do {
          try VNImageRequestHandler(url: url, options: [:]).perform([request])
        } catch is CancellationError {
          throw LocalImageTextRecognitionError.cancelled
        } catch {
          throw LocalImageTextRecognitionError.recognitionFailed
        }
        let observations = (request.results ?? []).sorted { left, right in
          let verticalDelta = left.boundingBox.midY - right.boundingBox.midY
          if abs(verticalDelta) > 0.015 { return verticalDelta > 0 }
          return left.boundingBox.minX < right.boundingBox.minX
        }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          let heading = imageURLs.count > 1 ? "图片 \(index + 1)" : nil
          pages.append([heading, text].compactMap { $0 }.joined(separator: "\n"))
        }
      }
      try Task.checkCancellation()
      guard !pages.isEmpty else { throw LocalImageTextRecognitionError.noText }
      return pages.joined(separator: "\n\n")
    }.value
  }
}
