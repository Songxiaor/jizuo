import AppKit
import AVFoundation
import CryptoKit
import Foundation
import LinkDigestCore
import PDFKit

/// 读完一个本地文件后得到的东西：要么是一段正文，要么是一份可播放、可转写的媒体。
public enum LocalFileImportContent: Sendable, Equatable {
  case text(String, method: String, completeness: String)
  /// `data` 已是 MPEG-4 容器（视频原样，音频统一转成 M4A），可直接进媒体库。
  case media(data: Data, durationSeconds: Double?, hasVideo: Bool)
  /// 图片本身就是素材：保留原图，识别出的文字作为附带正文。没识别到文字时为 nil。
  case image(data: Data, recognizedText: String?)
}

public enum LocalFileImportError: Error, Sendable, Equatable {
  case unsupportedType(String)
  case unreadable
  case noText
  case tooLarge
  case noAudio

  public var userMessage: String {
    switch self {
    case let .unsupportedType(ext):
      return ext.isEmpty ? "不支持这种文件。" : "暂不支持 .\(ext) 文件。"
    case .unreadable: return "文件读不出来，可能已损坏或没有读取权限。"
    case .noText: return "文件里没有读到文字（扫描件或纯图片 PDF 暂不支持）。"
    case .tooLarge: return "文件太大，超过了媒体库的单个文件上限。"
    case .noAudio: return "这个音视频文件里没有声音。"
    }
  }
}

/// 把用户拖进来的文件读成汲作能存的内容。只读源文件，从不修改或移动它。
public struct LocalFileImportReader: Sendable {
  public static let textExtensions: Set<String> = ["txt", "md", "markdown", "text"]
  public static let documentExtensions: Set<String> = ["pdf", "docx", "doc", "rtf"]
  public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
  public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
  public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aif", "aiff", "caf", "flac", "qta"]

  public static var supportedExtensions: Set<String> {
    textExtensions.union(documentExtensions).union(imageExtensions).union(videoExtensions).union(audioExtensions)
  }

  public static func isSupported(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  private let byteLimit: Int
  private let recognizer: any LocalImageTextRecognizing

  public init(
    byteLimit: Int = LocalMediaStore.maximumDownloadLimitBytes,
    recognizer: any LocalImageTextRecognizing = AppleVisionTextRecognizer()
  ) {
    self.byteLimit = byteLimit
    self.recognizer = recognizer
  }

  public func read(_ url: URL) async throws -> LocalFileImportContent {
    let ext = url.pathExtension.lowercased()
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard size <= byteLimit else { throw LocalFileImportError.tooLarge }
    if Self.textExtensions.contains(ext) {
      guard let data = try? Data(contentsOf: url) else { throw LocalFileImportError.unreadable }
      let text = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .utf16)
        ?? String(decoding: data, as: UTF8.self)
      // .md 本身就是 Markdown，原样保留；.txt 是纯文字，按行保留。
      let body = ["md", "markdown"].contains(ext) ? text : LocalImportDocument.preservingLineBreaks(text)
      return .text(try Self.bounded(body), method: "local_file_text", completeness: "complete")
    }
    if ext == "pdf" {
      guard let document = PDFDocument(url: url) else { throw LocalFileImportError.unreadable }
      var pages: [String] = []
      for index in 0..<document.pageCount {
        if let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
          pages.append(text)
        }
      }
      let body = LocalImportDocument.preservingLineBreaks(pages.joined(separator: "\n\n"))
      return .text(try Self.bounded(body), method: "local_file_pdf", completeness: "complete")
    }
    if Self.documentExtensions.contains(ext) {
      let type: NSAttributedString.DocumentType = switch ext {
      case "docx": .officeOpenXML
      case "doc": .docFormat
      default: .rtf
      }
      // HTML 不在支持列表里：它的导入走 WebKit、只能在主线程，网页请用「添加链接」。
      guard let string = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
      else { throw LocalFileImportError.unreadable }
      return .text(try Self.bounded(LocalImportDocument.documentParagraphs(string.string)), method: "local_file_document", completeness: "complete")
    }
    if Self.imageExtensions.contains(ext) {
      guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
        throw LocalFileImportError.unreadable
      }
      // 识图是尽力而为：没认出字不算失败，图本身照样收进来。
      let recognized = try? await recognizer.recognizeText(in: [url], languages: ["zh-Hans", "zh-Hant", "en-US"])
      return .image(data: data, recognizedText: recognized.flatMap { try? Self.bounded($0) })
    }
    if Self.videoExtensions.contains(ext) || Self.audioExtensions.contains(ext) {
      return try await readMedia(url, ext: ext)
    }
    throw LocalFileImportError.unsupportedType(ext)
  }

  /// 读语音备忘录这类只有声音的文件，统一转成 M4A。
  public func readAudio(_ url: URL) async throws -> LocalFileImportContent {
    try await readMedia(url, ext: url.pathExtension.lowercased(), forceAudio: true)
  }

  private func readMedia(_ url: URL, ext: String, forceAudio: Bool = false) async throws -> LocalFileImportContent {
    let asset = AVURLAsset(url: url)
    let videoTracks = forceAudio ? [] : ((try? await asset.loadTracks(withMediaType: .video)) ?? [])
    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    let hasVideo = !videoTracks.isEmpty
    let hasAudio = !audioTracks.isEmpty
    guard hasVideo || hasAudio else { throw LocalFileImportError.noAudio }
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

    // mp4/mov 视频原样入库：它们本来就是播放器和转写认识的容器，转码只会掉画质。
    if hasVideo, Self.videoExtensions.contains(ext) {
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw LocalFileImportError.unreadable }
      guard data.count <= byteLimit else { throw LocalFileImportError.tooLarge }
      return .media(data: data, durationSeconds: duration, hasVideo: true)
    }
    guard hasAudio else { throw LocalFileImportError.noAudio }
    // 其余一律抽出声音存成 M4A（MPEG-4 音频）。媒体库、播放器和转写都按 MPEG-4
    // 容器工作，B 站的纯音轨也是这么存的，统一格式就不用给每种后缀各开一条路。
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("linkdigest-local-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let audioURL: URL
    do {
      audioURL = try await AppleSpeechVideoTranscriber.extractAudio(from: url, workspaceURL: workspace)
    } catch {
      throw LocalFileImportError.unreadable
    }
    guard let data = try? Data(contentsOf: audioURL) else { throw LocalFileImportError.unreadable }
    guard data.count <= byteLimit else { throw LocalFileImportError.tooLarge }
    return .media(data: data, durationSeconds: duration, hasVideo: false)
  }

  /// 文件原始字节的 SHA-256。它是本地文件条目的身份：同一个文件拖两次只收一次。
  public static func contentSHA256(of url: URL) throws -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { throw LocalFileImportError.unreadable }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func bounded(_ raw: String) throws -> String {
    let text = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw LocalFileImportError.noText }
    guard text.unicodeScalars.count <= CaptureValidator.maxTextScalars else { throw LocalFileImportError.tooLarge }
    return text
  }
}
