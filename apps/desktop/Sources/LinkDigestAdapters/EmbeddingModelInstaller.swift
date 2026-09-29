import CryptoKit
import Foundation
import LinkDigestCore

extension BGETextEmbedder: TextEmbedding {}

/// 把「按意思搜」的模型文件下载到本机（2026-09-29）。
///
/// 文件钉在 Hugging Face 上的固定版本，并核对 SHA-256：地址被劫持或下到一半的文件都不会被当成模型用。
/// 先走官方站，连不上再走国内镜像 hf-mirror.com；两边内容相同，靠校验值保证。
public struct EmbeddingModelInstaller: Sendable {
  public struct ModelFile: Sendable, Equatable {
    public let name: String
    public let sha256: String
    public let byteCount: Int64
  }

  public static let modelID = "bge-small-zh-v1.5"
  static let revision = "7999e1d3359715c523056ef9478215996d62a620"
  public static let files: [ModelFile] = [
    ModelFile(name: "vocab.txt", sha256: "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c", byteCount: 109_540),
    ModelFile(name: "model.safetensors", sha256: "354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026", byteCount: 95_827_648),
  ]
  static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

  public enum InstallError: Error, Equatable {
    case downloadFailed(String)
    case checksumMismatch(String)
  }

  public let directory: URL
  private let session: URLSession

  public init(directory: URL, session: URLSession = .shared) {
    self.directory = directory
    self.session = session
  }

  /// 两个文件都在、且大小对得上（完整校验在下载时做过）。
  public var isInstalled: Bool {
    Self.files.allSatisfy { file in
      let url = directory.appendingPathComponent(file.name)
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
      return size == file.byteCount
    }
  }

  /// 下载缺的文件。`progress` 报 0...1（按总字节数）。
  public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let total = Double(Self.files.reduce(0) { $0 + $1.byteCount })
    var finished: Int64 = 0
    for file in Self.files {
      let target = directory.appendingPathComponent(file.name)
      let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
      if size != file.byteCount {
        let base = finished
        try await download(file, to: target) { received in progress(Double(base + received) / total) }
      }
      finished += file.byteCount
      progress(Double(finished) / total)
    }
  }

  private func download(_ file: ModelFile, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
    var lastError = "无法连接"
    for host in Self.hosts {
      guard let url = URL(string: "\(host)/BAAI/bge-small-zh-v1.5/resolve/\(Self.revision)/\(file.name)") else { continue }
      let partial = target.appendingPathExtension("part")
      do {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          lastError = "服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)"
          continue
        }
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        do {
          for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
              try handle.write(contentsOf: buffer)
              hasher.update(data: buffer)
              received += Int64(buffer.count)
              buffer.removeAll(keepingCapacity: true)
              progress(received)
            }
          }
          if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            received += Int64(buffer.count)
          }
          try handle.close()
        } catch {
          try? handle.close()
          throw error
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
          try? FileManager.default.removeItem(at: partial)
          throw InstallError.checksumMismatch(file.name)
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
        return
      } catch let error as InstallError {
        throw error
      } catch {
        try? FileManager.default.removeItem(at: partial)
        lastError = error.localizedDescription
      }
    }
    throw InstallError.downloadFailed(lastError)
  }
}
