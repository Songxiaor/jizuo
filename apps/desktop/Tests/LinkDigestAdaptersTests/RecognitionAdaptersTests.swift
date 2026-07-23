import Foundation
import XCTest
@testable import LinkDigestAdapters
import LinkDigestCore

final class RecognitionAdaptersTests: XCTestCase {
  func testVisionOCRRejectsEmptyAndUnreadableInputsWithoutNetwork() async {
    let recognizer = AppleVisionTextRecognizer()
    do {
      _ = try await recognizer.recognizeText(in: [], languages: ["zh-Hans"])
      XCTFail("empty input should fail")
    } catch {
      XCTAssertEqual(error as? LocalImageTextRecognitionError, .noImages)
    }

    do {
      _ = try await recognizer.recognizeText(
        in: [FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).png")],
        languages: ["zh-Hans"]
      )
      XCTFail("missing image should fail")
    } catch {
      XCTAssertEqual(error as? LocalImageTextRecognitionError, .unreadableImage)
    }
  }

  func testOnlineTranscriptionRequiresDedicatedModelBeforeReadingMedia() async throws {
    let profileStore = RecognitionProfileStore()
    let secretStore = RecognitionSecretStore()
    let service = ProviderConfigurationService(profileStore: profileStore, secretStore: secretStore)
    _ = try await service.save(
      baseURL: "https://api.openai.com/v1",
      model: "fixture-chat-model",
      apiKey: "fixture-key-never-sent"
    )
    let transcriber = OpenAICompatibleAudioTranscriber(configurationService: service)
    do {
      _ = try await transcriber.transcribe(
        remoteMediaURL: URL(string: "https://example.test/video.mp4")!,
        model: "",
        language: "zh"
      )
      XCTFail("missing transcription model should fail before reading media")
    } catch {
      XCTAssertEqual(error as? OnlineAudioTranscriptionError, .modelNotConfigured)
    }
  }
}

private actor RecognitionProfileStore: ProviderProfileStore {
  private var value: ProviderProfile?
  func load() async throws -> ProviderProfile? { value }
  func save(_ profile: ProviderProfile) async throws { value = profile }
  func delete() async throws { value = nil }
}

private actor RecognitionSecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  func save(_ secret: String, for reference: SecretReference) async throws { values[reference] = secret }
  func read(_ reference: SecretReference) async throws -> String? { values[reference] }
  func contains(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
  func delete(_ reference: SecretReference) async throws { values.removeValue(forKey: reference) }
}
