import AVFoundation
import XCTest
@testable import LinkDigestAdapters

/// B 站 DASH 给的是两条各自不完整的流。这里现造一条只有画面的 mp4 和一条只有
/// 声音的 m4a，验证合成产物确实同时带上了两条轨——线上一旦退化成无声视频，
/// 表现和"正常"几乎分辨不出来，必须有测试兜住。
final class SeparateTrackMuxerTests: XCTestCase {
  private var workspace: URL!

  override func setUpWithError() throws {
    workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("muxer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workspace)
  }

  func testMuxCombinesSeparateVideoAndAudioTracksIntoOnePlayableFile() async throws {
    let videoURL = try await makeVideoOnlyFile(seconds: 1.0)
    let audioURL = try await makeAudioOnlyFile(seconds: 1.0)

    // 前提：两条输入各自都缺一半，正是线上的形态。
    let videoOnly = AVURLAsset(url: videoURL)
    let audioOnly = AVURLAsset(url: audioURL)
    let videoInputAudioTracks = try await videoOnly.loadTracks(withMediaType: .audio)
    let audioInputVideoTracks = try await audioOnly.loadTracks(withMediaType: .video)
    XCTAssertTrue(videoInputAudioTracks.isEmpty, "画面那条本来就不该有声音")
    XCTAssertTrue(audioInputVideoTracks.isEmpty, "声音那条本来就不该有画面")

    let output = workspace.appendingPathComponent("muxed.mp4", isDirectory: false)
    try await SeparateTrackMuxer.mux(
      videoFileURL: videoURL,
      audioFileURL: audioURL,
      destinationURL: output
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let muxed = AVURLAsset(url: output)
    let videoTracks = try await muxed.loadTracks(withMediaType: .video)
    let audioTracks = try await muxed.loadTracks(withMediaType: .audio)
    XCTAssertEqual(videoTracks.count, 1)
    XCTAssertEqual(audioTracks.count, 1)
    let duration = try await muxed.load(.duration)
    XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.2)
  }

  func testMuxRejectsInputThatCarriesNoVideoTrack() async throws {
    let audioURL = try await makeAudioOnlyFile(seconds: 0.5)
    let output = workspace.appendingPathComponent("muxed.mp4", isDirectory: false)

    do {
      try await SeparateTrackMuxer.mux(
        videoFileURL: audioURL,
        audioFileURL: audioURL,
        destinationURL: output
      )
      XCTFail("画面缺失时必须报错，不能悄悄产出一个无画面的文件")
    } catch let error as SeparateTrackMuxError {
      XCTAssertEqual(error, .missingVideoTrack)
    }
  }

  // MARK: - 造测试素材

  private func makeVideoOnlyFile(seconds: Double) async throws -> URL {
    let url = workspace.appendingPathComponent("video-only.mp4", isDirectory: false)
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
    let frames = Int(seconds * Double(frameRate))
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
    let url = workspace.appendingPathComponent("audio-only.m4a", isDirectory: false)
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
    // 一段低幅正弦，避免全静音被编码器优化掉。
    if let channel = pcm.floatChannelData?[0] {
      for index in 0..<Int(frameCount) {
        channel[index] = 0.1 * sinf(2.0 * .pi * 440.0 * Float(index) / Float(sampleRate))
      }
    }
    guard let sampleBuffer = pcm.makeSampleBuffer() else { throw XCTSkip("无法生成采样缓冲") }
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
    input.append(sampleBuffer)
    input.markAsFinished()
    await writer.finishWriting()
    return url
  }
}

private extension AVAudioPCMBuffer {
  /// `AVAssetWriterInput` 要的是 CMSampleBuffer，这里把 PCM 缓冲包一层。
  func makeSampleBuffer() -> CMSampleBuffer? {
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
