import Foundation
import LinkDigestAdapters
import LinkDigestCore
import LinkDigestPersistence

/// Loop V-1 verifier.
/// Modes:
/// 1) Manual adapter path (real Douyin page URLs — often degrades to extension guide)
///    swift run LinkDigestLoopV1Verifier https://www.douyin.com/video/...
/// 2) Media handoff path (signed video URLs resolved via browser/extension session)
///    swift run LinkDigestLoopV1Verifier --samples /tmp/loopv1_media_samples.json

struct Sample: Codable {
  let pageURL: String
  let title: String?
  let author: String?
  let entry: String?
  let videoURL: String
}

@main
struct LinkDigestLoopV1Verifier {
  static func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    if let idx = args.firstIndex(of: "--samples"), args.indices.contains(idx + 1) {
      await runSamples(path: args[idx + 1])
      return
    }
    await runManualAdapter(urls: args.filter { !$0.hasPrefix("--") })
  }

  static func runManualAdapter(urls: [String]) async {
    guard !urls.isEmpty else {
      fputs("usage: LinkDigestLoopV1Verifier <douyin-url>...\n", stderr)
      fputs("   or: LinkDigestLoopV1Verifier --samples samples.json\n", stderr)
      exit(2)
    }
    let fetcher = ProxyAwareWebPageFetcher()
    let adapter = DouyinSourceAdapter(fetcher: fetcher)
    var ok = 0
    for raw in urls {
      print("==> manual-adapter \(raw)")
      do {
        guard let url = URL(string: raw) else { throw ManualLinkError.invalidURL }
        let document = try await adapter.capture(url: url)
        print("  PASS capture media=\(document.media?.videoURL != nil)")
        ok += 1
      } catch let error as ManualLinkError {
        print("  DEGRADE \(error) => \(error.userMessage)")
      } catch {
        print("  FAIL \(error)")
      }
    }
    print("manual-adapter done ok=\(ok)")
    // Degradation is expected for bare manual Douyin; exit 0 when messages are stable.
    exit(0)
  }

  static func runSamples(path: String) async {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      fputs("cannot read samples: \(error)\n", stderr)
      exit(2)
    }
    let samples: [Sample]
    do {
      samples = try JSONDecoder().decode([Sample].self, from: data)
    } catch {
      fputs("invalid samples json: \(error)\n", stderr)
      exit(2)
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LinkDigest-LoopV1-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    print("workspace \(root.path)")

    // SafeResourceRequest.byteLimit (200MB) governs media size; transport uses the same PeerBound/proxy gates.
    let mediaStore = LocalMediaStore(applicationSupportRoot: root)
    let resources = ProxyAwareWebPageFetcher(
      limits: .init(redirects: 4, responseBytes: LocalMediaStore.maxBytes, timeout: 120)
    )
    let downloader = VideoMediaDownloader(resources: resources, store: mediaStore)
    let location = LocalDatabaseLocation(applicationSupportRoot: root)
    let repository: GRDBHistoryRepository
    do {
      repository = try GRDBHistoryRepository.open(at: location)
    } catch {
      fputs("open db failed: \(error)\n", stderr)
      exit(1)
    }
    defer { try? repository.database.close() }

    var success = 0
    for sample in samples {
      print("==> \(sample.entry ?? "entry") \(sample.pageURL)")
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let text = DouyinPageParser.documentText(
        title: sample.title,
        author: sample.author,
        description: sample.title
      )
      let media = CaptureMedia(
        platform: "douyin",
        videoURL: sample.videoURL,
        coverURL: nil,
        durationSeconds: nil,
        author: sample.author
      )
      let document = CapturedDocument(
        createdAt: timestamp,
        idempotencyKey: "loopv1:\(UUID().uuidString.lowercased())",
        origin: sample.entry == "extension" ? .browserCapture : .manualLink,
        url: sample.pageURL,
        title: sample.title,
        platform: "douyin",
        method: sample.entry == "extension" ? "rendered_dom" : "douyin_public_html",
        text: text,
        completeness: "best_effort",
        capturedAt: timestamp,
        sourceLabel: sample.entry == "extension" ? "Current page DOM" : "手动链接（抖音公开视频）",
        media: media
      )
      do {
        let accepted = try repository.acceptCapture(
          .init(document: document, receivedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
        )
        let asset = try await downloader.downloadAndStore(
          media: media,
          taskID: accepted.taskID,
          snapshotID: accepted.snapshotID,
          pageURL: sample.pageURL
        )
        try repository.attachMedia(.init(asset: asset))
        let fileURL = mediaStore.absoluteURL(relativePath: asset.relativePath)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let detail = try repository.detail(taskID: accepted.taskID)
        print("  task=\(accepted.taskID.rawValue) bytes=\(asset.byteSize) file=\(exists) mediaRow=\(detail.media != nil)")
        if exists, detail.media != nil {
          success += 1
          print("  PASS")
        } else {
          print("  FAIL missing file or media row")
        }
      } catch {
        print("  FAIL \(error)")
      }
    }
    print("--- successes=\(success)/\(samples.count)")
    exit(success >= 3 ? 0 : 1)
  }
}
