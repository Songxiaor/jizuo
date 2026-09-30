import AppKit
import AVFoundation
import CoreServices
import CryptoKit
import Darwin
import Foundation
import LinkDigestCore
import PDFKit

/// 读完一个本地文件后得到的东西：要么是一段正文，要么是一份可播放、可转写的媒体。
public enum LocalFileImportContent: Sendable, Equatable {
  case text(String, method: String, completeness: String)
  /// `data` 已是 MPEG-4 容器（音频统一转成 M4A），会复制进媒体库。只剩语音备忘录走这条：
  /// 录音在系统受保护的目录里，引用它等于每次播放都要「完全磁盘访问」。
  case media(data: Data, durationSeconds: Double?, hasVideo: Bool)
  /// 拖进来 / 选中的音视频：**不读进内存、不复制**，条目只记原文件的位置（2026-09-29）。
  /// 这里只报告它能不能播、多长、有没有画面。
  case mediaFile(durationSeconds: Double?, hasVideo: Bool)
  /// 图片本身就是素材：保留原图，识别出的文字作为附带正文。没识别到文字时为 nil。
  case image(data: Data, recognizedText: String?)
}

/// 导入时按四类数、按四类说明。
public enum LocalFileKind: String, Sendable, Equatable, CaseIterable {
  case video
  case audio
  case document
  case image
}

public enum LocalFileImportError: Error, Sendable, Equatable {
  case unsupportedType(String)
  case unreadable
  case noText
  case tooLarge
  case noAudio
  /// 带版权保护（DRM）的视频：系统不让第三方 App 解码，播放和转写都做不了。
  case protectedContent

  public var userMessage: String {
    switch self {
    case let .unsupportedType(ext):
      if ext.isEmpty { return "不支持这种文件。" }
      if LocalFileImportReader.unsupportedVideoExtensions.contains(ext) {
        return "暂不支持 .\(ext) 视频：汲作能播放和转写的视频是 MP4、MOV、M4V。"
      }
      return "暂不支持 .\(ext) 文件。"
    case .unreadable: return "文件读不出来，可能已损坏或没有读取权限。"
    case .noText: return "文件里没有读到文字（扫描件或纯图片 PDF 暂不支持）。"
    case .tooLarge: return "文件太大，超过了单个文件的上限。"
    case .noAudio: return "这个音视频文件里没有声音。"
    case .protectedContent: return "这个音视频有版权保护（DRM），汲作没法播放或转写。"
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

  /// 常见但播不了的视频容器：结果里单独说明「只认 MP4、MOV、M4V」，而不是一句「不支持」。
  public static let unsupportedVideoExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "rmvb", "rm", "ts", "mts", "m2ts", "3gp", "mpg", "mpeg", "vob", "ogv"]

  public static var supportedExtensions: Set<String> {
    textExtensions.union(documentExtensions).union(imageExtensions).union(videoExtensions).union(audioExtensions)
  }

  /// 能直接引用原文件播放和转写的音视频后缀。
  public static var mediaExtensions: Set<String> { videoExtensions.union(audioExtensions) }

  public static func isSupported(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  public static func kind(of url: URL) -> LocalFileKind? {
    let ext = url.pathExtension.lowercased()
    if videoExtensions.contains(ext) { return .video }
    if audioExtensions.contains(ext) { return .audio }
    if imageExtensions.contains(ext) { return .image }
    if textExtensions.contains(ext) || documentExtensions.contains(ext) { return .document }
    return nil
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
    // 音视频只引用原文件，不进内存也不复制，所以不受单个文件上限约束。
    if Self.mediaExtensions.contains(ext) {
      return try await probeMedia(url, ext: ext)
    }
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
    throw LocalFileImportError.unsupportedType(ext)
  }

  /// 拖进来的音视频：确认读得出、有声音或画面、没有版权保护，量出时长。一个字节都不复制。
  private func probeMedia(_ url: URL, ext: String) async throws -> LocalFileImportContent {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { throw LocalFileImportError.unreadable }
    let asset = AVURLAsset(url: url)
    if (try? await asset.load(.hasProtectedContent)) == true { throw LocalFileImportError.protectedContent }
    let videoTracks = Self.videoExtensions.contains(ext) ? ((try? await asset.loadTracks(withMediaType: .video)) ?? []) : []
    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    let hasVideo = !videoTracks.isEmpty
    guard hasVideo || !audioTracks.isEmpty else {
      // 一条轨都没读出来：多半是文件坏了或者根本不是这个格式，而不是「没声音」。
      let playable = (try? await asset.load(.isPlayable)) ?? false
      throw playable ? LocalFileImportError.noAudio : LocalFileImportError.unreadable
    }
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    return .mediaFile(durationSeconds: duration, hasVideo: hasVideo)
  }

  /// 读语音备忘录这类只有声音的文件，统一转成 M4A（会复制进媒体库，见 `.media`）。
  public func readAudio(_ url: URL) async throws -> LocalFileImportContent {
    let asset = AVURLAsset(url: url)
    let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    guard hasAudio else { throw LocalFileImportError.noAudio }
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    // 抽出声音存成 M4A（MPEG-4 音频）。媒体库、播放器和转写都按 MPEG-4
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

  // MARK: 下载来源

  /// 读 macOS 给下载文件打的来源标记。没有 `com.apple.quarantine` 就返回 nil（按自有处理）；
  /// 有的话再从 `kMDItemWhereFroms` 补上下载网址。只读扩展属性，不改文件。
  public static func provenance(of url: URL) -> LocalFileProvenance? {
    guard let raw = extendedAttribute(url, name: "com.apple.quarantine"),
          let quarantine = LocalFileProvenance.parseQuarantine(String(decoding: raw, as: UTF8.self))
    else { return nil }
    return LocalFileProvenance(
      agentName: quarantine.agentName,
      sourceURL: LocalFileProvenance.preferredWhereFrom(whereFroms(of: url))
    )
  }

  /// `kMDItemWhereFroms` 本身存在扩展属性里（二进制 plist 字符串数组）；读不到再问一次 Spotlight。
  static func whereFroms(of url: URL) -> [String] {
    if let data = extendedAttribute(url, name: "com.apple.metadata:kMDItemWhereFroms"),
       let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
      return values
    }
    guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
          let values = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String]
    else { return [] }
    return values
  }

  static func extendedAttribute(_ url: URL, name: String) -> Data? {
    url.withUnsafeFileSystemRepresentation { path -> Data? in
      guard let path else { return nil }
      let size = getxattr(path, name, nil, 0, 0, 0)
      guard size > 0, size <= 64 * 1024 else { return nil }
      var buffer = [UInt8](repeating: 0, count: size)
      let read = getxattr(path, name, &buffer, size, 0, 0)
      guard read > 0 else { return nil }
      return Data(buffer.prefix(read))
    }
  }

  // MARK: 文件夹展开

  /// 同一文件夹里按文件名「自然排序」：01、2、10 的顺序和访达一致。
  public static func naturallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    switch lhs.localizedStandardCompare(rhs) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs < rhs
    }
  }

  /// 一次扫描里最多收这么多个文件：拖进整个主目录时不至于卡住，也不会一口气建几万条。
  public static let scanFileLimit = 2_000
  /// 不支持的文件最多逐个列这么多条，其余只报数量。
  public static let scanSkippedListLimit = 300

  /// 把拖进来 / 选中的文件和文件夹展开成导入清单。
  ///
  /// - 文件夹递归展开（含子文件夹），同一层按自然排序，文件和子文件夹按名字穿插；
  /// - 跳过隐藏文件、不拆包（.app、.photoslibrary 这类「看起来是一个文件」的文件夹），
  ///   跟随指向文件夹的替身/符号链接但记住走过的真实路径，链接成环也不会打转；
  /// - 只收 `isSupported` 的文件，其余逐个记下原因，不拦整批。
  /// 只读目录，不打开、不改动任何文件。
  public static func scanForImport(
    _ urls: [URL],
    fileManager: FileManager = .default,
    fileLimit: Int = scanFileLimit
  ) -> LocalImportScan {
    var scan = LocalImportScan()
    var visitedDirectories = Set<String>()
    var seenFiles = Set<String>()
    let roots = urls.filter(\.isFileURL).sorted { naturallyPrecedes($0.lastPathComponent, $1.lastPathComponent) }

    func skip(_ url: URL, display: String, reason: String) {
      scan.skippedCount += 1
      if scan.skipped.count < scanSkippedListLimit {
        scan.skipped.append(.init(url: url, displayName: display, reason: reason))
      }
    }

    func visit(_ url: URL, display: String, folderIndex: Int?, depth: Int, explicit: Bool) {
      guard scan.entries.count < fileLimit else {
        scan.truncated = true
        return
      }
      guard let values = try? url.resourceValues(forKeys: scanKeys) else {
        skip(url, display: display, reason: LocalFileImportError.unreadable.userMessage)
        return
      }
      if !explicit, values.isHidden == true || url.lastPathComponent.hasPrefix(".") { return }
      guard let target = resolvedLinkTarget(url, values: values, fileManager: fileManager) else {
        skip(url, display: display, reason: "这是一个替身，它指向的文件已经不在了。")
        return
      }
      let keys = scanKeys
      let targetValues = target == url ? values : ((try? target.resourceValues(forKeys: keys)) ?? values)
      if targetValues.isDirectory == true {
        if targetValues.isPackage == true {
          let ext = target.pathExtension.lowercased()
          skip(url, display: display, reason: ext.isEmpty
            ? "这是一个应用或资料库包，不会拆开导入。"
            : "暂不支持 .\(ext)：它是一个应用或资料库包，不会拆开导入。")
          return
        }
        let canonical = target.resolvingSymlinksInPath().standardizedFileURL.path
        // 链接成环（或同一个文件夹被拖了两次）：走过的不再走。
        guard visitedDirectories.insert(canonical).inserted, depth < 32 else { return }
        let children: [URL]
        do {
          children = try fileManager.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
          )
        } catch {
          skip(url, display: display, reason: "这个文件夹读不出来，可能没有访问权限。")
          return
        }
        for child in children.sorted(by: { naturallyPrecedes($0.lastPathComponent, $1.lastPathComponent) }) {
          visit(child, display: display + "/" + child.lastPathComponent, folderIndex: folderIndex, depth: depth + 1, explicit: false)
          if scan.truncated { return }
        }
        return
      }
      guard targetValues.isRegularFile == true else {
        skip(url, display: display, reason: LocalFileImportError.unsupportedType("").userMessage)
        return
      }
      guard let kind = kind(of: target) else {
        skip(url, display: display, reason: LocalFileImportError.unsupportedType(target.pathExtension.lowercased()).userMessage)
        return
      }
      // 同一个文件经替身又出现一次：只收一次。
      guard seenFiles.insert(target.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { return }
      scan.entries.append(.init(
        url: target,
        displayName: display,
        kind: kind,
        byteSize: Int64(targetValues.fileSize ?? 0),
        folderIndex: folderIndex
      ))
    }

    for root in roots {
      if scan.truncated { break }
      let resolvedRoot = (try? root.resourceValues(forKeys: scanKeys))
        .flatMap { resolvedLinkTarget(root, values: $0, fileManager: fileManager) } ?? root
      let isDirectory = (try? resolvedRoot.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
        .map { $0.isDirectory == true && $0.isPackage != true } ?? false
      if isDirectory {
        let index = scan.folders.count
        scan.folders.append(.init(url: root, name: root.lastPathComponent))
        visit(root, display: root.lastPathComponent, folderIndex: index, depth: 0, explicit: true)
      } else {
        visit(root, display: root.lastPathComponent, folderIndex: nil, depth: 0, explicit: true)
      }
    }
    return scan
  }

  private static let scanKeys: Set<URLResourceKey> = [
    .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isHiddenKey, .isRegularFileKey, .fileSizeKey,
  ]

  /// 符号链接和访达替身都换成它指向的真实位置；指向的东西不在了返回 nil。不是链接原样返回。
  private static func resolvedLinkTarget(_ url: URL, values: URLResourceValues, fileManager: FileManager) -> URL? {
    let target: URL
    if values.isSymbolicLink == true {
      target = url.resolvingSymlinksInPath()
    } else if values.isAliasFile == true {
      guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
      target = resolved
    } else {
      return url
    }
    return fileManager.fileExists(atPath: target.path) ? target : nil
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

/// 一次导入要处理哪些文件：确认框里的「找到 N 个文件…」和导入顺序都来自它。
public struct LocalImportScan: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public let url: URL
    /// 结果里显示的名字：顶层文件是文件名，文件夹里的是「文件夹/子文件夹/文件名」。
    public let displayName: String
    public let kind: LocalFileKind
    public let byteSize: Int64
    /// 来自第几个顶层文件夹（`folders` 的下标）；直接拖进来的文件为 nil。
    public let folderIndex: Int?

    public init(url: URL, displayName: String, kind: LocalFileKind, byteSize: Int64, folderIndex: Int?) {
      self.url = url
      self.displayName = displayName
      self.kind = kind
      self.byteSize = byteSize
      self.folderIndex = folderIndex
    }
  }

  public struct Folder: Sendable, Equatable {
    public let url: URL
    public let name: String
  }

  public struct Skipped: Sendable, Equatable {
    public let url: URL
    public let displayName: String
    public let reason: String
  }

  /// 按导入顺序排好：顶层按自然排序，文件夹内按自然排序深度优先。
  public var entries: [Entry] = []
  public var folders: [Folder] = []
  /// 不支持、读不出来的文件（最多列 `scanSkippedListLimit` 条）。
  public var skipped: [Skipped] = []
  public var skippedCount = 0
  /// 超过 `scanFileLimit`，后面的没有收进来。
  public var truncated = false

  public init() {}

  public func count(_ kind: LocalFileKind) -> Int { entries.filter { $0.kind == kind }.count }
  public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteSize } }
  public var mediaCount: Int { count(.video) + count(.audio) }
}
