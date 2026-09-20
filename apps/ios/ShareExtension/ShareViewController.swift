import UIKit
import UniformTypeIdentifiers

/// Share Extension：Safari 当前页经 JS 预处理抽出标题/URL/正文；其它 App 分享 URL/文本仍可用。
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  private static let appGroupID = "group.com.syc.linkdigest"
  private static let fileName = "share-inbox.json"
  private static let pasteboardType = "com.syc.linkdigest.share-inbox"
  private static let openURL = URL(string: "linkdigest://import")!
  private static let renderedDOMSource = "safari_rendered_dom"
  private static let minimumUsefulBodyCharacters = 40

  private let statusLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.text = "正在从当前页分享到汲作…"
    view.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    Task { await processShare() }
  }

  private func processShare() async {
    let payload = await extractPayload()
    guard let payload, !payload.isEmpty else {
      await MainActor.run {
        statusLabel.text = "没有可分享的链接或文本"
      }
      try? await Task.sleep(nanoseconds: 800_000_000)
      extensionContext?.cancelRequest(withError: ShareError.empty)
      return
    }

    let ok = enqueue(payload)
    let deep = payload.isDeepCapture
    await MainActor.run {
      if ok {
        statusLabel.text = deep
          ? "已抓取当前页正文，正在打开汲作…"
          : "已暂存，正在打开汲作…"
      } else {
        statusLabel.text = "暂存失败"
      }
    }

    openHostApp()
    try? await Task.sleep(nanoseconds: 400_000_000)
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  private struct Payload {
    var url: String?
    var text: String?
    var title: String?
    var source: String?

    var isEmpty: Bool {
      (url?.isEmpty ?? true) && (text?.isEmpty ?? true)
    }

    var isDeepCapture: Bool {
      source == ShareViewController.renderedDOMSource
        && (text?.unicodeScalars.count ?? 0) >= ShareViewController.minimumUsefulBodyCharacters
    }
  }

  private enum ShareError: Error {
    case empty
  }

  private func extractPayload() async -> Payload? {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
    var payload = Payload()

    for item in items {
      if let attributed = item.attributedContentText?.string,
         !attributed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        // 仅作弱标题/摘要；正文优先 JS / 附件。
        if payload.title == nil {
          payload.title = attributed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
      guard let attachments = item.attachments else { continue }
      for provider in attachments {
        if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
          if let value = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
             let dict = value as? [String: Any]
          {
            let resultsKey = "NSExtensionJavaScriptPreprocessingResultsKey"
            let results =
              (dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any])
              ?? (dict[resultsKey] as? [String: Any])
              ?? dict
            payload = merge(payload, from: results, markRendered: true)
          }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          if let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
            if let loaded = value as? URL {
              payload.url = loaded.absoluteString
            } else if let loaded = value as? String, looksLikeHTTPURL(loaded) {
              payload.url = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
          }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          if let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
            if let loaded = value as? String {
              applyPlainText(&payload, loaded)
            } else if let loaded = value as? URL {
              payload.url = loaded.absoluteString
            }
          }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
          if let value = try? await provider.loadItem(forTypeIdentifier: UTType.html.identifier) {
            if let data = value as? Data, let html = String(data: data, encoding: .utf8) {
              let text = plainTextApproximate(fromHTML: html)
              if text.unicodeScalars.count >= (payload.text?.unicodeScalars.count ?? 0) {
                payload.text = text
              }
            } else if let html = value as? String {
              let text = plainTextApproximate(fromHTML: html)
              if text.unicodeScalars.count >= (payload.text?.unicodeScalars.count ?? 0) {
                payload.text = text
              }
            }
          }
        }
      }
    }

    if payload.url == nil, let text = payload.text, looksLikeHTTPURL(text) {
      payload.url = text.trimmingCharacters(in: .whitespacesAndNewlines)
      payload.text = nil
    }

    return payload
  }

  private func merge(_ base: Payload, from dict: [String: Any], markRendered: Bool) -> Payload {
    var next = base
    if let url = stringValue(dict["url"] ?? dict["URL"]), looksLikeHTTPURL(url) {
      next.url = url
    }
    if let title = stringValue(dict["title"] ?? dict["Title"]) {
      next.title = title
    }
    if let text = stringValue(dict["text"] ?? dict["body"] ?? dict["content"]) {
      if text.unicodeScalars.count >= (next.text?.unicodeScalars.count ?? 0) {
        next.text = text
      }
    }
    if markRendered {
      next.source = stringValue(dict["source"]) ?? Self.renderedDOMSource
    }
    return next
  }

  private func applyPlainText(_ payload: inout Payload, _ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if looksLikeHTTPURL(trimmed) {
      if payload.url == nil { payload.url = trimmed }
      return
    }
    if (payload.text?.unicodeScalars.count ?? 0) < trimmed.unicodeScalars.count {
      payload.text = trimmed
    }
  }

  private func stringValue(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return nil
  }

  private func plainTextApproximate(fromHTML html: String) -> String {
    let stripped = html
      .replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped
  }

  private func looksLikeHTTPURL(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }

  @discardableResult
  private func enqueue(_ payload: Payload) -> Bool {
    var envelope = loadEnvelope()
    var text = payload.text
    if payload.isDeepCapture, let body = text, !body.hasPrefix("【来自当前页】") {
      text = "【来自当前页】\n\n\(body)"
    }
    var dict: [String: Any] = [
      "createdAtMilliseconds": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let url = payload.url { dict["url"] = url }
    if let text { dict["text"] = text }
    if let title = payload.title { dict["title"] = title }
    envelope.append(dict)
    return saveEnvelope(envelope)
  }

  private func loadEnvelope() -> [[String: Any]] {
    if let url = inboxFileURL(),
       let data = try? Data(contentsOf: url),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let items = json["items"] as? [[String: Any]]
    {
      return items
    }
    if let data = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let items = json["items"] as? [[String: Any]]
    {
      return items
    }
    return []
  }

  private func saveEnvelope(_ items: [[String: Any]]) -> Bool {
    let root: [String: Any] = ["items": items]
    guard let data = try? JSONSerialization.data(withJSONObject: root) else { return false }
    var wroteFile = false
    if let url = inboxFileURL() {
      do {
        try data.write(to: url, options: [.atomic])
        wroteFile = true
      } catch {
        wroteFile = false
      }
    }
    UIPasteboard.general.setData(data, forPasteboardType: Self.pasteboardType)
    return wroteFile || true
  }

  private func inboxFileURL() -> URL? {
    guard let group = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    else { return nil }
    do {
      try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
      let probe = group.appendingPathComponent(".linkdigest-write-probe")
      try Data().write(to: probe, options: [.atomic])
      try? FileManager.default.removeItem(at: probe)
      return group.appendingPathComponent(Self.fileName)
    } catch {
      return nil
    }
  }

  private func openHostApp() {
    let url = Self.openURL
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:], completionHandler: nil)
        return
      }
      let selector = sel_registerName("openURL:")
      if current.responds(to: selector) {
        _ = current.perform(selector, with: url)
        return
      }
      responder = current.next
    }
    extensionContext?.open(url, completionHandler: nil)
  }
}
