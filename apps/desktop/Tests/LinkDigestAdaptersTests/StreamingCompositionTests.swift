import AVFoundation
import XCTest
@testable import LinkDigestAdapters

/// 远程多轨合成原语：单轨返回 AVURLAsset，双轨在内存合成且不落盘。
/// 测试只用本地临时文件，不打真实网络。
final class StreamingCompositionTests: XCTestCase {
  private var workspace: URL!

  override func setUpWithError() throws {
    workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("streaming-composition-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workspace)
  }

  func testSingleURLReturnsURLAssetWithoutCompanion() async throws {
    let videoURL = try await makeVideoOnlyFile(seconds: 0.5)
    let asset = try await StreamingComposition.makePlayableAsset(videoURL: videoURL)
    XCTAssertTrue(asset is AVURLAsset, "单轨应直接返回 AVURLAsset，不做合成")
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(videoTracks.count, 1)
  }

  func testDualURLComposesVideoAndAudioTracksInMemory() async throws {
    let videoURL = try await makeVideoOnlyFile(seconds: 1.0)
    let audioURL = try await makeAudioOnlyFile(seconds: 1.0)

    // 输入各自缺一半，与线上 DASH 形态一致。
    let videoOnly = AVURLAsset(url: videoURL)
    let audioOnly = AVURLAsset(url: audioURL)
    let videoInputAudioTracks = try await videoOnly.loadTracks(withMediaType: .audio)
    let audioInputVideoTracks = try await audioOnly.loadTracks(withMediaType: .video)
    XCTAssertTrue(videoInputAudioTracks.isEmpty)
    XCTAssertTrue(audioInputVideoTracks.isEmpty)

    let before = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
    let asset = try await StreamingComposition.makePlayableAsset(
      videoURL: videoURL,
      companionAudioURL: audioURL
    )
    let after = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
    XCTAssertEqual(before.count, after.count, "合成不得在工作区落盘")

    XCTAssertTrue(asset is AVMutableComposition, "双轨应返回内存合成资产")
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(videoTracks.count, 1)
    XCTAssertEqual(audioTracks.count, 1)
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.25)
  }

  func testDualURLUsesShorterTrackDuration() async throws {
    let videoURL = try await makeVideoOnlyFile(seconds: 1.2)
    let audioURL = try await makeAudioOnlyFile(seconds: 0.6)
    let asset = try await StreamingComposition.makePlayableAsset(
      videoURL: videoURL,
      companionAudioURL: audioURL
    )
    let duration = try await asset.load(.duration)
    XCTAssertEqual(duration.seconds, 0.6, accuracy: 0.2)
  }

  func testDualURLRejectsInputWithoutVideoTrack() async throws {
    let audioURL = try await makeAudioOnlyFile(seconds: 0.5)
    do {
      _ = try await StreamingComposition.makePlayableAsset(
        videoURL: audioURL,
        companionAudioURL: audioURL
      )
      XCTFail("画面缺失时必须报错")
    } catch let error as StreamingCompositionError {
      XCTAssertEqual(error, .missingVideoTrack)
    }
  }

  func testLocalFileURLAssetDoesNotRequireNetworkHeaders() {
    let local = workspace.appendingPathComponent("local.mp4")
    // 不需要真实媒体字节：只验证 file:// 分支返回非 nil 资产。
    FileManager.default.createFile(atPath: local.path, contents: Data(), attributes: nil)
    let asset = StreamingComposition.urlAsset(url: local, role: .video, httpHeaders: ["Referer": "https://example.test/"])
    XCTAssertEqual(asset.url, local)
  }

  func testMIMEHintUsesHLSPlaylistTypeForM3U8() {
    let hls = URL(string: "https://cdn.example.test/master.m3u8")!
    XCTAssertEqual(
      StreamingComposition.mimeTypeHint(for: hls, role: .video),
      "application/vnd.apple.mpegurl"
    )
    let dash = URL(string: "https://cdn.example.test/video.m4s")!
    XCTAssertEqual(StreamingComposition.mimeTypeHint(for: dash, role: .video), "video/mp4")
    XCTAssertEqual(StreamingComposition.mimeTypeHint(for: dash, role: .audio), "audio/mp4")
  }

  // MARK: - 造测试素材（与 SeparateTrackMuxerTests 同风格）

  private func makeVideoOnlyFile(seconds: Double) async throws -> URL {
    let url = workspace.appendingPathComponent("video-only-\(UUID().uuidString).mp4", isDirectory: false)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let width = 160, height = 120
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frameRate = 15
    let frames = max(1, Int(seconds * Double(frameRate)))
    for index in 0..<frames {
      var pixelBuffer: CVPixelBuffer?
      CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
      guard let buffer = pixelBuffer else { throw XCTSkip("无法创建像素缓冲") }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(index % 255), CVPixelBufferGetDataSize(buffer))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
  }

  private func makeAudioOnlyFile(seconds: Double) async throws -> URL {
    let url = workspace.appendingPathComponent("audio-only-\(UUID().uuidString).m4a", isDirectory: false)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let sampleRate = 44_100.0
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      throw XCTSkip("无法创建 PCM 缓冲")
    }
    pcm.frameLength = frameCount
    if let channel = pcm.floatChannelData?[0] {
      for index in 0..<Int(frameCount) {
        channel[index] = 0.1 * sinf(2.0 * .pi * 440.0 * Float(index) / Float(sampleRate))
      }
    }
    guard let sampleBuffer = pcm.makeStreamingSampleBuffer() else { throw XCTSkip("无法生成采样缓冲") }
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
    input.append(sampleBuffer)
    input.markAsFinished()
    await writer.finishWriting()
    return url
  }
}

private extension AVAudioPCMBuffer {
  func makeStreamingSampleBuffer() -> CMSampleBuffer? {
    let audioBufferList = mutableAudioBufferList
    var format: CMFormatDescription?
    guard CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: self.format.streamDescription,
      layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
      extensions: nil, formatDescriptionOut: &format
    ) == noErr, let format else { return nil }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(self.format.sampleRate)),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    guard CMSampleBufferCreate(
      allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
      sampleCount: CMItemCount(frameLength), sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return nil }

    guard CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: audioBufferList
    ) == noErr else { return nil }
    return sampleBuffer
  }
}
