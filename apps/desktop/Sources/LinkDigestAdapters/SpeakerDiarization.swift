import FluidAudio
import Foundation
import LinkDigestCore

public enum SpeakerDiarizationError: Error, Sendable, Equatable {
  case modelUnavailable(String)
  case audioUnreadable
  case noSpeech
  case onlineNotConfigured
  case fileTooLarge
  case authInvalid
  case rejected(Int)
  case network

  public var userMessage: String {
    switch self {
    case .modelUnavailable:
      // 原始报错在抛出处已写进日志，界面只说下一步（2026-10-01）。
      return "本机说话人分离模型没能准备好（第一次使用要联网下载一次）。请检查网络后重试。"
    case .audioUnreadable: return "录音读不出来，可能文件已损坏。"
    case .noSpeech: return "没有从录音里分出说话的人。"
    case .onlineNotConfigured:
      return "还没有设置在线说话人分离。请在「设置 → 模型服务」里添加 OpenAI，模型填 gpt-4o-transcribe-diarize。"
    case .fileTooLarge: return "录音超过在线服务单次上传的上限（25 MB，约 50 分钟），请改用本机分离。"
    case .authInvalid: return "在线服务不认这个密钥，请到设置的「模型服务」里检查。"
    case .rejected:
      return "在线服务没有接受这次请求，请检查模型名和账户余额后重试。"
    case .network: return "网络中断，请稍后重试。"
    }
  }
}

/// 本机说话人分离：FluidAudio 的离线流水线（pyannote Community-1 分段 + WeSpeaker 声纹 + VBx 聚类），
/// 在 Apple 神经网络引擎上跑。模型首次使用时下载到汲作自己的数据目录，之后完全离线。
///
/// 不是 actor：FluidAudio 的管理器不是 Sendable，跨 actor 调它的异步方法会被并发检查拦下。
/// 调用方（界面）同一时刻只发起一次分离，用一把锁护住「懒加载」这一步就够了。
public final class LocalSpeakerDiarizer: @unchecked Sendable {
  private let lock = NSLock()
  private var manager: OfflineDiarizerManager?
  private let modelsDirectory: URL

  public init(modelsDirectory: URL) {
    self.modelsDirectory = modelsDirectory
  }

  public func diarize(
    audioURL: URL,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> [SpeakerSegment] {
    let manager = try await preparedManager()
    let result: DiarizationResult
    do {
      result = try await manager.process(audioURL) { done, total in
        guard total > 0 else { return }
        progress?(Double(done) / Double(total))
      }
    } catch {
      throw SpeakerDiarizationError.audioUnreadable
    }
    let segments = result.segments.map {
      SpeakerSegment(
        startSeconds: Double($0.startTimeSeconds),
        endSeconds: Double($0.endTimeSeconds),
        speaker: $0.speakerId
      )
    }
    guard !segments.isEmpty else { throw SpeakerDiarizationError.noSpeech }
    return segments
  }

  private func preparedManager() async throws -> OfflineDiarizerManager {
    if let existing = lock.withLock({ manager }) { return existing }
    let created = OfflineDiarizerManager(config: .default)
    do {
      try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
      try await created.prepareModels(directory: modelsDirectory)
    } catch {
      AppLog.error(.media, "diarization_model_unavailable", code: "DIARIZATION_MODEL_UNAVAILABLE", ["error": String(describing: error)])
      throw SpeakerDiarizationError.modelUnavailable((error as NSError).localizedDescription)
    }
    lock.withLock { manager = created }
    return created
  }
}

/// 在线说话人分离：OpenAI 兼容 `/audio/transcriptions`，模型带说话人标注
///（如 `gpt-4o-transcribe-diarize`，`response_format=diarized_json`）。
///
/// 整个录音一次上传——分片上传时，不同分片里的「说话人 A」不保证是同一个人。
/// 超过单次上传上限就明确报错、建议改用本机分离，而不是悄悄给出张冠李戴的结果。
public final class OnlineSpeakerDiarizer: @unchecked Sendable {
  public static let maximumUploadBytes = 25 * 1_024 * 1_024
  private let configurationService: ProviderConfigurationService
  private let session: URLSession

  public init(configurationService: ProviderConfigurationService) {
    self.configurationService = configurationService
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 600
    configuration.timeoutIntervalForResource = 1_800
    session = URLSession(configuration: configuration)
  }

  /// 模型库里第一个模型名带 "diarize" 的服务。
  public func configuredProfile() async -> ProviderProfile? {
    guard let library = try? await configurationService.loadLibrary() else { return nil }
    if let assigned = library.profile(withID: library.transcriptionProfileID), Self.isDiarizationModel(assigned.model) {
      return assigned
    }
    return library.profiles.first { Self.isDiarizationModel($0.model) }
  }

  public static func isDiarizationModel(_ model: String) -> Bool {
    model.lowercased().contains("diarize")
  }

  public func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
    guard let profile = await configuredProfile(),
          let credentials = try? await configurationService.loadCredentials(profileID: profile.id)
    else { throw SpeakerDiarizationError.onlineNotConfigured }
    let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard size > 0 else { throw SpeakerDiarizationError.audioUnreadable }
    guard size <= Self.maximumUploadBytes else { throw SpeakerDiarizationError.fileTooLarge }
    let endpoint: URL
    do { endpoint = try OpenAICompatibleEndpoint.audioTranscriptionsURL(baseURL: credentials.profile.baseURL) }
    catch { throw SpeakerDiarizationError.onlineNotConfigured }

    let boundary = "LinkDigest-\(UUID().uuidString)"
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let bodyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-diarize-\(UUID().uuidString).multipart")
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    do {
      try OpenAICompatibleAudioTranscriber.writeMultipartBody(
        boundary: boundary,
        fields: [
          "model": credentials.profile.model,
          "response_format": "diarized_json",
          "chunking_strategy": "auto",
        ],
        audioURL: audioURL,
        outputURL: bodyURL
      )
    } catch {
      throw SpeakerDiarizationError.audioUnreadable
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.upload(for: request, fromFile: bodyURL)
    } catch {
      throw SpeakerDiarizationError.network
    }
    guard let http = response as? HTTPURLResponse else { throw SpeakerDiarizationError.network }
    if http.statusCode == 401 || http.statusCode == 403 { throw SpeakerDiarizationError.authInvalid }
    guard (200...299).contains(http.statusCode) else {
      AppLog.error(.provider, "diarization_rejected", code: "DIARIZATION_REJECTED", ["status": "\(http.statusCode)"])
      throw SpeakerDiarizationError.rejected(http.statusCode)
    }
    let segments = try Self.parseDiarizedJSON(data)
    guard !segments.isEmpty else { throw SpeakerDiarizationError.noSpeech }
    return segments
  }

  /// `diarized_json`：`{"segments":[{"speaker":"A","start":0.0,"end":3.2,"text":"…"}]}`。
  static func parseDiarizedJSON(_ data: Data) throws -> [SpeakerSegment] {
    struct Payload: Decodable {
      struct Segment: Decodable {
        let speaker: String?
        let start: Double?
        let end: Double?
        let text: String?
      }
      let segments: [Segment]?
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      throw SpeakerDiarizationError.rejected(200)
    }
    return (payload.segments ?? []).compactMap { segment in
      guard let start = segment.start, let text = segment.text,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return SpeakerSegment(
        startSeconds: start,
        endSeconds: segment.end ?? start,
        speaker: segment.speaker ?? "A",
        text: text
      )
    }
  }
}
