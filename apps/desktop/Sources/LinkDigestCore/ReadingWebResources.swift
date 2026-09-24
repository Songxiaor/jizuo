import Foundation

/// 阅读区离屏排版页（公式 / 流程图）随 App 打包的位置。
///
/// 目录里是 `renderer.html` 和它引用的 KaTeX、Mermaid（均 MIT，许可证同目录），
/// 全部本地加载，不联网。
public enum ReadingWebResources {
  public static var rendererURL: URL? {
    CoreResourceBundle.resolved()?.url(forResource: "renderer", withExtension: "html", subdirectory: "reading-web")
  }
}
