import AVFoundation
import SQLite3
import XCTest
@testable import LinkDigestAdapters

/// 语音备忘录读取与本地文件读取。录音库是仿造的：真实库在需要「完全磁盘访问」
/// 的系统目录里，测试不能也不该去碰。
final class LocalImportAdaptersTests: XCTestCase {
  private var workspace: URL!

  override func setUpWithError() throws {
    workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workspace)
  }

  // MARK: 语音备忘录

  func testReadsRecordingsFromDatabaseNewestFirstAndSkipsRecentlyDeleted() throws {
    let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    // 文件大小要像真的录音（每秒远超 1 KB），否则会被当成 iCloud 占位文件。
    for name in ["old.m4a", "new.m4a", "deleted.m4a"] {
      try Data(count: 64_000).write(to: recordings.appendingPathComponent(name))
    }
    try makeDatabase(at: recordings.appendingPathComponent("CloudRecordings.db"), rows: [
      ("ID-OLD", "/private/var/old.m4a", "旧录音", 100, 10, nil),
      ("ID-NEW", "new.m4a", nil, 200, 20, nil),
      ("ID-DEL", "deleted.m4a", "已删除", 300, 30, 400),
    ])

    let result = try VoiceMemosLibrary(recordingsDirectory: recordings).recordings()
    XCTAssertEqual(result.map(\.id), ["ID-NEW", "ID-OLD"])
    guard result.count == 2 else { return }
    XCTAssertEqual(result[1].title, "旧录音")
    XCTAssertEqual(result[1].fileURL.lastPathComponent, "old.m4a")
    XCTAssertEqual(result[0].durationSeconds, 20)
    XCTAssertEqual(result[0].recordedAt, Date(timeIntervalSinceReferenceDate: 200))
    XCTAssertTrue(result[0].isDownloaded)
  }

  func testMissingAudioFileIsReportedAsNotDownloaded() throws {
    let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try makeDatabase(at: recordings.appendingPathComponent("CloudRecordings.db"), rows: [
      ("ID-CLOUD", "cloud.m4a", "云端录音", 100, 10, nil),
    ])
    let result = try VoiceMemosLibrary(recordingsDirectory: recordings).recordings()
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.title, "云端录音")
    XCTAssertEqual(result.first?.isDownloaded, false)
  }

  func testFallsBackToAudioFilesWithoutDatabase() throws {
    let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try Data([0]).write(to: recordings.appendingPathComponent("20260901 101010.m4a"))
    try Data([0]).write(to: recordings.appendingPathComponent("notes.txt"))
    let result = try VoiceMemosLibrary(recordingsDirectory: recordings).recordings()
    XCTAssertEqual(result.map(\.id), ["20260901 101010"])
  }

  func testMissingLibraryIsExplainedAsNotFound() {
    let library = VoiceMemosLibrary(recordingsDirectory: workspace.appendingPathComponent("nope/Recordings"))
    XCTAssertThrowsError(try library.recordings()) { error in
      XCTAssertEqual(error as? VoiceMemosLibraryError, .libraryNotFound)
    }
  }

  func testTitleExpressionHandlesAnyNumberOfTitleColumns() {
    XCTAssertEqual(VoiceMemosLibrary.titleExpression([]), "NULL")
    XCTAssertEqual(VoiceMemosLibrary.titleExpression(["ZCUSTOMLABEL"]), "NULLIF(ZCUSTOMLABEL, '')")
    XCTAssertTrue(VoiceMemosLibrary.titleExpression(["A", "B"]).hasPrefix("COALESCE("))
  }

  // MARK: 本地文件

  func testTextFileBecomesCompleteText() async throws {
    let url = workspace.appendingPathComponent("灵感.md")
    try "# 标题\n\n正文一段".write(to: url, atomically: true, encoding: .utf8)
    let content = try await LocalFileImportReader().read(url)
    XCTAssertEqual(content, .text("# 标题\n\n正文一段", method: "local_file_text", completeness: "complete"))
  }

  func testEmptyTextFileIsRejectedWithReason() async throws {
    let url = workspace.appendingPathComponent("空.txt")
    try "   \n".write(to: url, atomically: true, encoding: .utf8)
    do {
      _ = try await LocalFileImportReader().read(url)
      XCTFail("空文件不该导入")
    } catch {
      XCTAssertEqual(error as? LocalFileImportError, .noText)
    }
  }

  func testUnsupportedExtensionIsNamed() async throws {
    let url = workspace.appendingPathComponent("a.zip")
    try Data([1, 2, 3]).write(to: url)
    XCTAssertFalse(LocalFileImportReader.isSupported(url))
    do {
      _ = try await LocalFileImportReader().read(url)
      XCTFail("不支持的文件不该导入")
    } catch {
      XCTAssertEqual(error as? LocalFileImportError, .unsupportedType("zip"))
    }
  }

  /// WAV 这类非 MPEG-4 音频要转成 M4A，媒体库、播放器和转写才认。
  func testAudioIsNormalizedToMPEG4Audio() async throws {
    let url = workspace.appendingPathComponent("录音.wav")
    try makeWAV(at: url, seconds: 1)
    let content = try await LocalFileImportReader().read(url)
    guard case let .media(data, duration, hasVideo) = content else { return XCTFail("应当读成媒体") }
    XCTAssertFalse(hasVideo)
    XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
    XCTAssertEqual(try XCTUnwrap(duration), 1, accuracy: 0.2)
  }

  func testContentHashIsStableAcrossNames() throws {
    let a = workspace.appendingPathComponent("a.txt"), b = workspace.appendingPathComponent("b.txt")
    try "same".write(to: a, atomically: true, encoding: .utf8)
    try "same".write(to: b, atomically: true, encoding: .utf8)
    XCTAssertEqual(try LocalFileImportReader.contentSHA256(of: a), try LocalFileImportReader.contentSHA256(of: b))
  }

  // MARK: 夹具

  private func makeDatabase(
    at url: URL,
    rows: [(id: String, path: String, title: String?, date: Double, duration: Double, eviction: Double?)]
  ) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, """
      CREATE TABLE ZCLOUDRECORDING (
        Z_PK INTEGER PRIMARY KEY, ZUNIQUEID TEXT, ZPATH TEXT, ZCUSTOMLABEL TEXT,
        ZDATE REAL, ZDURATION REAL, ZEVICTIONDATE REAL
      )
      """, nil, nil, nil), SQLITE_OK)
    for row in rows {
      let title = row.title.map { "'\($0)'" } ?? "NULL"
      let eviction = row.eviction.map { String($0) } ?? "NULL"
      let sql = "INSERT INTO ZCLOUDRECORDING (ZUNIQUEID, ZPATH, ZCUSTOMLABEL, ZDATE, ZDURATION, ZEVICTIONDATE) VALUES ('\(row.id)', '\(row.path)', \(title), \(row.date), \(row.duration), \(eviction))"
      XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
  }

  private func makeWAV(at url: URL, seconds: Double) throws {
    let sampleRate = 16_000.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw XCTSkip("无法创建音频格式")
    }
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw XCTSkip("无法创建缓冲") }
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] {
      for index in 0..<Int(frames) {
        channel[index] = 0.1 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
      }
    }
    try file.write(from: buffer)
  }

  /// iCloud 上没下载的录音在本机只留几百字节的占位文件，不能当成「已下载、没声音」。
  func testCloudPlaceholderRecordingIsNotTreatedAsDownloaded() {
    XCTAssertFalse(VoiceMemoRecording.looksDownloaded(fileSize: 726, durationSeconds: 347.5))
    XCTAssertFalse(VoiceMemoRecording.looksDownloaded(fileSize: 12_415, durationSeconds: 1_761))
    XCTAssertTrue(VoiceMemoRecording.looksDownloaded(fileSize: 1_400_000, durationSeconds: 178))
    // 极短录音不按大小判断：0.8 秒的文件本来就只有一两 KB。
    XCTAssertTrue(VoiceMemoRecording.looksDownloaded(fileSize: 1_075, durationSeconds: 0.8))
    XCTAssertTrue(VoiceMemoRecording.looksDownloaded(fileSize: nil, durationSeconds: 60))
  }
}
