import Foundation
import XCTest
@testable import LinkDigestAdapters
@testable import LinkDigestCore

final class SpeakerDiarizationTests: XCTestCase {
  func testParsesOpenAIDiarizedJSON() throws {
    let json = """
    {"text":"…","segments":[
      {"type":"transcript.text.segment","id":"s1","speaker":"A","start":0.0,"end":4.2,"text":"大家好。"},
      {"type":"transcript.text.segment","id":"s2","speaker":"B","start":4.5,"end":8.0,"text":"好的。"},
      {"speaker":"B","start":8.1,"end":9.0,"text":"   "}
    ]}
    """
    let segments = try OnlineSpeakerDiarizer.parseDiarizedJSON(Data(json.utf8))
    XCTAssertEqual(segments.map(\.speaker), ["A", "B"])
    XCTAssertEqual(segments.last?.text, "好的。")
  }

  func testRecognizesDiarizationModels() {
    XCTAssertTrue(OnlineSpeakerDiarizer.isDiarizationModel("gpt-4o-transcribe-diarize"))
    XCTAssertFalse(OnlineSpeakerDiarizer.isDiarizationModel("whisper-1"))
  }

  /// 真实跑一次本机分离。要下载模型，默认跳过：
  /// LINKDIGEST_DIARIZATION_AUDIO=/path/dialog.m4a LINKDIGEST_DIARIZATION_MODELS=/path/models swift test --filter SpeakerDiarizationTests
  func testLocalDiarizationOnRealAudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let audio = env["LINKDIGEST_DIARIZATION_AUDIO"], let models = env["LINKDIGEST_DIARIZATION_MODELS"] else {
      throw XCTSkip("需要 LINKDIGEST_DIARIZATION_AUDIO / LINKDIGEST_DIARIZATION_MODELS")
    }
    let diarizer = LocalSpeakerDiarizer(modelsDirectory: URL(fileURLWithPath: models, isDirectory: true))
    let started = Date()
    let segments = try await diarizer.diarize(audioURL: URL(fileURLWithPath: audio))
    let elapsed = Date().timeIntervalSince(started)
    for segment in segments {
      print("DIARIZE", segment.speaker, String(format: "%.1f-%.1f", segment.startSeconds, segment.endSeconds))
    }
    print("DIARIZE elapsed", String(format: "%.1fs", elapsed), "speakers", Set(segments.map(\.speaker)).count)
    XCTAssertGreaterThanOrEqual(Set(segments.map(\.speaker)).count, 2)
  }
}
