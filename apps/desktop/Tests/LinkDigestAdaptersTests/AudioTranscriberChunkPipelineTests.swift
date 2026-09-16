import Foundation
import LinkDigestCore
import XCTest

@testable import LinkDigestAdapters

/// 在线转写的分片流水线与上传重试。
///
/// 测的是生产代码本身（`AudioChunkPipeline.run` / `.retrying`，真实
/// `transcribe()` 调用的就是这两个函数），只把 export / upload / sleep
/// 换成假的，不跑 AVFoundation 也不发网络请求。
final class AudioTranscriberChunkPipelineTests: XCTestCase {
  /// 记录上传时序，并提供可控的放行闸门。
  private actor UploadRecorder {
    enum Event: Equatable {
      case export(Int)
      case uploadStart(Int)
      case uploadEnd(Int)
    }

    private(set) var events: [Event] = []
    private(set) var attempts: [Int: Int] = [:]
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0
    private(set) var sleepCalls: [Double] = []
    private var openGates: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func recordExport(_ index: Int) { events.append(.export(index)) }

    /// 只登记一次尝试，不参与在飞计数（失败路径不好配对 end）。
    func noteAttempt(_ index: Int) -> Int {
      events.append(.uploadStart(index))
      attempts[index, default: 0] += 1
      return attempts[index] ?? 0
    }

    func attemptCount(_ index: Int) -> Int { attempts[index] ?? 0 }

    func beginUpload(_ index: Int) {
      events.append(.uploadStart(index))
      attempts[index, default: 0] += 1
      inFlight += 1
      peakInFlight = max(peakInFlight, inFlight)
    }

    func endUpload(_ index: Int) {
      events.append(.uploadEnd(index))
      inFlight -= 1
    }

    func recordSleep(_ seconds: Double) { sleepCalls.append(seconds) }

    func open(_ gate: String) {
      openGates.insert(gate)
      for waiter in waiters.removeValue(forKey: gate) ?? [] { waiter.resume() }
    }

    func wait(_ gate: String) async {
      if openGates.contains(gate) { return }
      await withCheckedContinuation { continuation in
        waiters[gate, default: []].append(continuation)
      }
    }

    /// 在飞数达到 `count` 时自动放行，避免并发上限把测试卡死。
    func releaseWhenInFlightReaches(_ count: Int, gate: String) {
      if inFlight >= count { open(gate) }
    }

    func firstIndex(of event: Event) -> Int? { events.firstIndex(of: event) }
  }

  private func chunkURL(_ index: Int) -> URL {
    URL(fileURLWithPath: "/tmp/linkdigest-test-audio-\(index).m4a")
  }

  /// 把某片的上传包上和生产代码同样的重试壳：重试耗尽翻译成 responseRejected。
  private func retryingUpload(
    recorder: UploadRecorder,
    maximumAttempts: Int = 3,
    body: @escaping @Sendable (Int) async throws -> String
  ) -> @Sendable (Int, URL) async throws -> String {
    { index, _ in
      do {
        return try await AudioChunkPipeline.retrying(
          maximumAttempts: maximumAttempts,
          isRetryable: { $0 is AudioChunkPipeline.RetryableFailure },
          sleep: { await recorder.recordSleep($0) }
        ) {
          try await body(index)
        }
      } catch is AudioChunkPipeline.RetryableFailure {
        throw OnlineAudioTranscriptionError.responseRejected
      }
    }
  }

  /// 一片被限流后重试成功，整体仍成功；文稿必须按分片序号拼，不是完成顺序。
  func testChunkRetriedAfter429StillJoinsInChunkIndexOrder() async throws {
    let recorder = UploadRecorder()
    let texts = ["第一段", "第二段", "第三段"]
    let ordered = try await AudioChunkPipeline.run(
      total: 3,
      concurrencyLimit: 3,
      progress: nil,
      export: { index in
        await recorder.recordExport(index)
        return self.chunkURL(index)
      },
      upload: retryingUpload(recorder: recorder) { index in
        let attempt = await recorder.noteAttempt(index)
        // 完成顺序刻意乱序：第 0 片等第 2 片先返回；第 1 片先被限流一次。
        if index == 1, attempt == 1 {
          throw AudioChunkPipeline.RetryableFailure(statusCode: 429)
        }
        if index == 0 { await recorder.wait("chunk2-done") }
        if index == 2 { await recorder.open("chunk2-done") }
        return texts[index]
      }
    )

    let joined = ordered.keys.sorted().compactMap { ordered[$0] }.joined(separator: "\n")
    XCTAssertEqual(joined, "第一段\n第二段\n第三段")
    let firstAttempts = await recorder.attemptCount(0)
    let secondAttempts = await recorder.attemptCount(1)
    let thirdAttempts = await recorder.attemptCount(2)
    XCTAssertEqual(secondAttempts, 2, "第 1 片应当在 429 后重试一次")
    XCTAssertEqual(firstAttempts, 1)
    XCTAssertEqual(thirdAttempts, 1)
    let sleeps = await recorder.sleepCalls
    XCTAssertEqual(sleeps.count, 1, "只应在唯一一次重试前退避")
    XCTAssertGreaterThan(sleeps.first ?? 0, 0, "退避时长必须为正")
  }

  /// 持续 429 超过重试上限：整体失败，且抛出的仍是原有的 responseRejected。
  func testChunkFailsWithResponseRejectedAfterRetriesExhausted() async {
    let recorder = UploadRecorder()
    do {
      _ = try await AudioChunkPipeline.run(
        total: 2,
        concurrencyLimit: 3,
        progress: nil,
        export: { self.chunkURL($0) },
        upload: retryingUpload(recorder: recorder) { index in
          _ = await recorder.noteAttempt(index)
          if index == 1 { throw AudioChunkPipeline.RetryableFailure(statusCode: 429) }
          return "ok"
        }
      )
      XCTFail("持续限流必须让整条转写失败")
    } catch let error as OnlineAudioTranscriptionError {
      XCTAssertEqual(error, .responseRejected)
    } catch {
      XCTFail("错误类型必须与改动前一致，实际是 \(error)")
    }
    let attempts = await recorder.attemptCount(1)
    XCTAssertEqual(attempts, 3, "首次 + 2 次重试 = 3 次尝试")
  }

  /// 401 这类不可重试的错误必须一次就抛出，绝不浪费两轮退避。
  func testAuthFailureIsNotRetried() async {
    let recorder = UploadRecorder()
    do {
      _ = try await AudioChunkPipeline.run(
        total: 1,
        concurrencyLimit: 3,
        progress: nil,
        export: { self.chunkURL($0) },
        upload: retryingUpload(recorder: recorder) { index in
          _ = await recorder.noteAttempt(index)
          throw OnlineAudioTranscriptionError.authInvalid
        }
      )
      XCTFail("鉴权失败必须直接抛出")
    } catch let error as OnlineAudioTranscriptionError {
      XCTAssertEqual(error, .authInvalid)
    } catch {
      XCTFail("不该改写非限流错误，实际是 \(error)")
    }
    let attempts = await recorder.attemptCount(0)
    XCTAssertEqual(attempts, 1)
    let sleeps = await recorder.sleepCalls
    XCTAssertTrue(sleeps.isEmpty, "不可重试的错误不该退避")
  }

  /// 导出与上传真的重叠：第 2 片的导出发生在第 1 片上传完成之前。
  func testExportOfNextChunkHappensBeforePreviousUploadFinishes() async throws {
    let recorder = UploadRecorder()
    let ordered = try await AudioChunkPipeline.run(
      total: 3,
      concurrencyLimit: 3,
      progress: nil,
      export: { index in
        await recorder.recordExport(index)
        // 第 2 片（index 1）导出后才放行第 1 片的上传。
        if index == 1 { await recorder.open("chunk1-exported") }
        return self.chunkURL(index)
      },
      upload: { index, _ in
        await recorder.beginUpload(index)
        if index == 0 { await recorder.wait("chunk1-exported") }
        await recorder.endUpload(index)
        return "段\(index)"
      }
    )

    XCTAssertEqual(ordered.count, 3)
    let exportOfSecond = await recorder.firstIndex(of: .export(1))
    let uploadEndOfFirst = await recorder.firstIndex(of: .uploadEnd(0))
    let exportIndex = try XCTUnwrap(exportOfSecond)
    let uploadEndIndex = try XCTUnwrap(uploadEndOfFirst)
    XCTAssertLessThan(
      exportIndex,
      uploadEndIndex,
      "导出必须与上传重叠：第 2 片的导出不该等第 1 片上传返回"
    )
  }

  /// 在飞上传数永远不超过并发上限，且进度分母从第一次回调起就是总片数。
  func testInFlightUploadsNeverExceedConcurrencyLimitAndProgressTotalIsStable() async throws {
    let recorder = UploadRecorder()
    let limit = 3
    let total = 8
    let progressLog = ProgressLog()
    let ordered = try await AudioChunkPipeline.run(
      total: total,
      concurrencyLimit: limit,
      progress: { completed, reported in progressLog.append(completed: completed, total: reported) },
      export: { self.chunkURL($0) },
      upload: { index, _ in
        await recorder.beginUpload(index)
        // 在飞数顶到上限后统一放行，既验证了上限也不会把测试卡死。
        await recorder.releaseWhenInFlightReaches(limit, gate: "saturated")
        await recorder.wait("saturated")
        await recorder.endUpload(index)
        return "段\(index)"
      }
    )

    XCTAssertEqual(ordered.count, total)
    let peak = await recorder.peakInFlight
    XCTAssertLessThanOrEqual(peak, limit, "在飞上传数超过了 \(limit)")
    XCTAssertEqual(peak, limit, "并发没有真正打满，流水线没起作用")

    let entries = progressLog.snapshot()
    XCTAssertEqual(entries.first?.completed, 0)
    XCTAssertTrue(entries.allSatisfy { $0.total == total }, "进度分母一开始就该是准确的总片数")
    XCTAssertEqual(entries.last?.completed, total)
  }

  /// multipart 改成流式落盘后，字节序列必须与原来的内存拼装一模一样：
  /// 少一个 CRLF 服务端就只会回一句含糊的 400。
  func testMultipartBodyOnDiskMatchesTheExpectedByteSequence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-multipart-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // 大于一次拷贝块（1MiB），确保分块循环真的被走到。
    let audio = Data((0..<(1 << 20 + 777)).map { UInt8($0 % 251) })
    let audioURL = directory.appendingPathComponent("audio.m4a")
    try audio.write(to: audioURL)
    let bodyURL = directory.appendingPathComponent("body.multipart")
    let boundary = "LinkDigest-TEST"

    try OpenAICompatibleAudioTranscriber.writeMultipartBody(
      boundary: boundary,
      fields: ["model": "whisper-1", "response_format": "json", "language": ""],
      audioURL: audioURL,
      outputURL: bodyURL
    )

    var expected = Data()
    // 空值字段（language）被跳过；其余按 key 排序。
    for (key, value) in [("model", "whisper-1"), ("response_format", "json")] {
      expected.append(Data("--\(boundary)\r\n".utf8))
      expected.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
      expected.append(Data("\(value)\r\n".utf8))
    }
    expected.append(Data("--\(boundary)\r\n".utf8))
    expected.append(
      Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8)
    )
    expected.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
    expected.append(audio)
    expected.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let written = try Data(contentsOf: bodyURL)
    XCTAssertEqual(written.count, expected.count, "上传体长度与内存拼装不一致")
    XCTAssertEqual(written, expected)
  }

  /// progress 回调是同步的，用一把锁收集即可。
  private final class ProgressLog: @unchecked Sendable {
    struct Entry {
      let completed: Int
      let total: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(completed: Int, total: Int) {
      lock.lock()
      entries.append(Entry(completed: completed, total: total))
      lock.unlock()
    }

    func snapshot() -> [Entry] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }
}
