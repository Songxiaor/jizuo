import Foundation
import Combine
import SwiftUI
import WebKit

/// App 内会话抓取：用户主动打开页面（可登录），点「抓取本页」抽出当前 DOM 正文。
/// Cookie 仅存在于本 WKWebView 会话，不读系统浏览器 Cookie 库。
public struct SessionCaptureSheet: View {
  @Bindable var model: NotesViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var address = "https://www.xiaohongshu.com"
  @State private var currentURL = ""
  @State private var pageTitle = ""
  @State private var extractedBody = ""
  @State private var status = "输入地址后前往；登录完成后点「抓取本页」。"
  @State private var isExtracting = false
  @State private var webBridge = SessionCaptureWebBridge()

  public init(model: NotesViewModel) {
    self.model = model
  }

  public var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          TextField("https://…", text: $address)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
          Button("前往") {
            webBridge.load(address)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(12)

        SessionCaptureWebView(bridge: webBridge) { title, url in
          pageTitle = title
          currentURL = url
          address = url
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        VStack(alignment: .leading, spacing: 8) {
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
          if !extractedBody.isEmpty {
            Text(extractedBody)
              .font(.caption)
              .lineLimit(6)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.bar)
      }
      .navigationTitle("应用内打开抓取")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await extractAndSave() }
          } label: {
            if isExtracting { ProgressView() } else { Text("抓取本页") }
          }
          .disabled(isExtracting)
        }
      }
      .onAppear {
        webBridge.load(address)
      }
    }
  }

  @MainActor
  private func extractAndSave() async {
    isExtracting = true
    defer { isExtracting = false }
    do {
      let payload = try await webBridge.extractPage()
      let url = payload.url.isEmpty ? currentURL : payload.url
      let title = payload.title.isEmpty ? pageTitle : payload.title
      var body = payload.text
      if body.unicodeScalars.count < 40 {
        status = "正文过短。请确认已登录并打开具体内容页后再抓。"
        return
      }
      if !body.hasPrefix("【来自当前页】") {
        body = "【来自当前页】\n\n\(body)"
      }
      await model.createLinkNote(
        url: url.isEmpty ? address : url,
        title: title.isEmpty ? nil : title,
        body: body,
        summary: nil
      )
      status = "已保存到汲作（\(body.unicodeScalars.count) 字）"
      extractedBody = body
      try? await Task.sleep(nanoseconds: 700_000_000)
      dismiss()
    } catch {
      status = "抓取失败：\(error.localizedDescription)"
    }
  }
}

@MainActor
final class SessionCaptureWebBridge: ObservableObject {
  fileprivate weak var webView: WKWebView?

  func attach(_ webView: WKWebView) {
    self.webView = webView
  }

  func load(_ raw: String) {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    if !trimmed.contains("://") { trimmed = "https://\(trimmed)" }
    guard let url = URL(string: trimmed) else { return }
    webView?.load(URLRequest(url: url))
  }

  struct Extracted: Sendable {
    var title: String
    var url: String
    var text: String
  }

  func extractPage() async throws -> Extracted {
    guard let webView else {
      throw NSError(domain: "SessionCapture", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "网页尚未就绪",
      ])
    }
    let js = """
    (function(){
      function collapse(t){return String(t||'').replace(/\\u00a0/g,' ').replace(/\\s+/g,' ').trim();}
      function textFrom(node){
        if(!node) return '';
        var c=node.cloneNode(true);
        c.querySelectorAll('script,style,noscript,svg,nav,header,footer,aside').forEach(function(n){try{n.remove()}catch(e){}});
        return collapse(c.innerText||c.textContent||'');
      }
      var title=collapse((document.querySelector('meta[property=\"og:title\"]')||{}).content||document.title||'');
      var url=String(document.URL||location.href||'');
      var body='';
      ['article','main','#js_content','.RichText','#v_desc','[role=main]'].forEach(function(sel){
        if(body.length>=40) return;
        var t=textFrom(document.querySelector(sel));
        if(t.length>=40) body=t;
      });
      if(!body) body=textFrom(document.body);
      if(!body) body=collapse((document.querySelector('meta[property=\"og:description\"]')||{}).content||'');
      if(body.length>120000) body=body.slice(0,120000);
      return {title:title,url:url,text:body};
    })();
    """
    let result = try await webView.evaluateJavaScript(js)
    guard let dict = result as? [String: Any] else {
      throw NSError(domain: "SessionCapture", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "无法解析页面脚本结果",
      ])
    }
    return Extracted(
      title: dict["title"] as? String ?? "",
      url: dict["url"] as? String ?? "",
      text: dict["text"] as? String ?? ""
    )
  }
}

#if os(iOS) || os(macOS)
struct SessionCaptureWebView: View {
  @ObservedObject var bridge: SessionCaptureWebBridge
  var onNavigate: (String, String) -> Void

  var body: some View {
    SessionCaptureWKRepresentable(bridge: bridge, onNavigate: onNavigate)
  }
}

#if os(iOS)
private struct SessionCaptureWKRepresentable: UIViewRepresentable {
  @ObservedObject var bridge: SessionCaptureWebBridge
  var onNavigate: (String, String) -> Void

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    bridge.attach(webView)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

  final class Coordinator: NSObject, WKNavigationDelegate {
    let onNavigate: (String, String) -> Void
    init(onNavigate: @escaping (String, String) -> Void) { self.onNavigate = onNavigate }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigate(webView.title ?? "", webView.url?.absoluteString ?? "")
    }
  }
}
#else
private struct SessionCaptureWKRepresentable: NSViewRepresentable {
  @ObservedObject var bridge: SessionCaptureWebBridge
  var onNavigate: (String, String) -> Void

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView(frame: .zero)
    webView.navigationDelegate = context.coordinator
    bridge.attach(webView)
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

  final class Coordinator: NSObject, WKNavigationDelegate {
    let onNavigate: (String, String) -> Void
    init(onNavigate: @escaping (String, String) -> Void) { self.onNavigate = onNavigate }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigate(webView.title ?? "", webView.url?.absoluteString ?? "")
    }
  }
}
#endif
#endif
