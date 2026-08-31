import AppKit
import SwiftUI
import LinkDigestCore

struct HistoryRowView: View {
  // 只收值输入，不再整体观察 ViewModel：以前每行都挂着 @ObservedObject，
  // 任何无关的 @Published 变化（转写流式输出、图标到货、导航计数……）
  // 都会让列表逐行整体重算。现在行体只在自己的输入变化时才重算（见文件
  // 下方的 Equatable 扩展），选中/图标由父层算好传进来。
  let row: HistoryRowProjection
  let isSelected: Bool
  let faviconURL: URL?
  let theme: HistoryThemeTokens
  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 图24 式状态点：已有总结产物为绿色，未总结为橙色。
  private var isSummarized: Bool {
    row.artifactPreview?.trimmedNonEmpty != nil
  }

  /// 高对比主题改用形状编码：实心 = 已总结，空心 = 未总结。
  /// 尺寸和其它主题保持一致，换主题时行内文字不会跟着挪位。
  @ViewBuilder private var statusIndicator: some View {
    if theme.encodesStatusByShape {
      if isSummarized {
        Circle().fill(theme.primaryText)
      } else {
        Circle().strokeBorder(theme.primaryText, lineWidth: 1.5)
      }
    } else {
      Circle().fill(isSummarized ? theme.success : theme.warning)
    }
  }

  /// 这一行显示哪个时间。
  ///
  /// 发布时间优先——判断"这条素材新不新鲜"看的是它。抓不到发布时间
  /// （很多网页没有可靠的时间标记）才回落到入库时间，并标明是"存于"，
  /// 免得让人误以为原文是那天发的。
  private var capturedTitle: String {
    CapturedDocumentTitle.display(row.title, for: row.canonicalURL)
  }

  private var cleanedArtifactPreview: String? {
    guard let preview = row.artifactPreview?.trimmedNonEmpty else { return nil }
    let cleaned = MarkdownNoteFrontmatter.strippingCapturedEnvelope(from: preview)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  private var rowPrimaryTitle: String {
    HistoryReadingTitle.primaryTitle(captured: capturedTitle, artifactPreview: cleanedArtifactPreview)
  }

  private var rowPreviewLine: String? {
    HistoryReadingTitle.listPreview(
      artifactPreview: cleanedArtifactPreview,
      primaryTitle: rowPrimaryTitle,
      authorFallback: row.author
    )
  }

  private var rowTimeText: String {
    if let published = row.published?.trimmedNonEmpty {
      return HistoryPublishedTimestampFormatter.text(published)
    }
    return "存于 \(HistoryRelativeTime.text(row.createdAtMilliseconds ?? row.updatedAtMilliseconds))"
  }

  /// 整行作为一个可访问元素，读屏只报标题、来源、时间和处理状态；正文预览
  /// 留在视觉层，不再把几百字摘要当作列表项 value 一口气念完。
  private var rowAccessibilityLabel: String { rowPrimaryTitle }

  private var rowAccessibilityValue: String {
    var values = [
      "来源：\(HistoryPlatformDisplay.name(forHost: row.host))",
      rowTimeText,
      isSummarized ? "已总结" : "未总结",
    ]
    if row.hasTranscript == true {
      values.append("已转写")
    } else if row.hasMedia == true {
      values.append("有视频，还没转写")
    }
    if row.hasMindMap == true { values.append("已生成脑图") }
    return values.joined(separator: "，")
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // 左侧锚点：状态点 + 平台标记竖排。
      //
      // 平台标记从标题右侧挪过来。放在右边有两个问题：位置和「关闭按钮」
      // 撞车，语义容易误解；而且列表纯文字堆叠时扫视没有落点——眼睛需要
      // 一个每行都在同一位置、且颜色各不相同的东西来定位。
      //
      // 没有用缩略图：36 条里只有 22 条正文带图（61%），而且那些图是远程
      // URL——列表里加载等于每次开 App 就朝各平台发几十个请求，既违背
      // local-first，也把「我在看这条」暴露给了内容平台。平台色块零网络、
      // 100% 覆盖，扫视效果反而更稳定。
      VStack(spacing: 6) {
        statusIndicator
          .frame(width: 7, height: 7)
          .help(isSummarized ? "已总结" : "未总结")
          // label 说「这是什么」，value 说「现在是什么值」。
          // 把状态塞进 label（原来的写法）时，VoiceOver 只念一句「已总结」，
          // 听不出这是一个状态指示器；分开之后念的是「总结状态，已总结」。
          .accessibilityLabel("总结状态")
          .accessibilityValue(isSummarized ? "已总结" : "未总结")
        favicon
      }
      .padding(.top, 4)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 8) {
          Text(rowPrimaryTitle)
            .themedFont(.body, weight: .semibold)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 4)
        }
        if let preview = rowPreviewLine {
          Text(preview)
            .themedFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        // 时间合成一排。
        //
        // 原本是两排——"发布 2026年8月5日 14:37" 和 "创建 2026年8月5日"，
        // 吃掉近一半行高，而这是整行最次要的信息。而且"创建"时间对用户
        // 几乎没有意义（他知道自己什么时候存的），判断素材新不新鲜看的是
        // 发布时间。所以只留发布时间，没抓到才回落到入库时间。
        HStack(alignment: .bottom, spacing: 6) {
          Text(rowTimeText)
            .themedFont(.footnote)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          Spacer(minLength: 4)
          // 处理状态徽标：一眼分清生料和成品，自动管线跑完什么立刻可见。
          // 这一排是裸 Image，不是 Label——`.help()` 只喂给鼠标悬停的 tooltip，
          // VoiceOver 读不到，所以每个都要自己声明可访问名称。工具栏那些按钮
          // 用的是 `Label(文字, systemImage:)`，文字本身就是名称，不用补。
          HStack(spacing: 4) {
            if row.hasTranscript == true {
              Image(systemName: "waveform")
                .help("已转写")
                .accessibilityLabel("已转写")
            } else if row.hasMedia == true {
              // 只标异常，不标常态：有视频却还没转写的条目，正文往往只有一百来字的
              // 站点描述，在列表里和几千字的长文长得一模一样，点进去才发现是空的。
              // 不判「字数少」这类阈值——「有视频且无转写稿」是可判定的事实。
              Image(systemName: "waveform.slash")
                .foregroundStyle(theme.warning)
                .help("有视频，还没转写")
                .accessibilityLabel("有视频，还没转写")
                .accessibilityIdentifier("history-row-needs-transcript")
            }
            if row.hasSummary == true {
              Image(systemName: "text.alignleft")
                .help("已总结")
                .accessibilityLabel("已总结")
            }
            if row.hasMindMap == true {
              Image(systemName: "brain")
                .help("已生成脑图")
                .accessibilityLabel("已生成脑图")
            }
          }
          .font(.system(size: BadgeTypography.size))
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("history-row-status-badges")
        }
      }
    }
    .padding(.horizontal, DesignTokens.Space.md)
    .padding(.vertical, DesignTokens.Space.sm)
    .frame(minHeight: 68, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(rowBackground)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Capsule()
          .fill(theme.accent)
          .frame(width: 3, height: 30)
          .padding(.leading, DesignTokens.Space.xxs)
      }
    }
    .animation(
      DesignTokens.Motion.resolved(DesignTokens.Motion.quick, reduceMotion: reduceMotion),
      value: isHovering
    )
    .onHover { isHovering = $0 }
    // 新到行在 macOS List 里可能沿用估算行高并把内容压扁；
    // 固定纵向 intrinsic 高度 + 内容变化换 identity，强制按真实内容测量。
    .fixedSize(horizontal: false, vertical: true)
    .id("\(row.taskID.rawValue)-\(row.updatedAtMilliseconds)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityValue(rowAccessibilityValue)
  }

  private var rowBackground: Color {
    if isSelected { return theme.accent.opacity(0.04) }
    if isHovering { return theme.primaryText.opacity(0.035) }
    return .clear
  }

  @ViewBuilder private var favicon: some View {
    if row.host == HistoryPlatformDisplay.noteHost {
      // 笔记没有站点图标可取。给它侧边栏同一个符号，一眼能和抓来的东西分开。
      Image(systemName: "square.and.pencil")
        .font(.system(size: DesignTokens.IconSize.inline, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 18, height: 18)
        .accessibilityLabel("笔记")
    } else if let image = PlatformIconCatalog.image(for: row.host) {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        .accessibilityLabel("\(row.host) 图标")
    } else if let url = faviconURL {
      HistoryFaviconDiskImage(url: url, host: row.host, taskID: row.taskID) {
        fallbackBadge
      }
    } else {
      fallbackBadge
    }
  }

  /// Deterministic initial mark. A source with neither a bundled icon nor a
  /// reachable favicon still gets a stable, identifiable badge.
  private var fallbackBadge: some View {
    Text(PlatformIconCatalog.fallbackInitial(for: row.host))
      .font(.system(size: BadgeTypography.size, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 16, height: 16)
      .background(PlatformIconCatalog.fallbackColor(for: row.host), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
      .padding(.top, 1)
      .accessibilityLabel("\(row.host) 图标")
  }
}

/// 行体只随自己的输入变化重算。theme 参与比较：主题切换时行必须换色，
/// 而行拿的是传值不是环境，比较里漏掉它会让旧配色滞留到下一次输入变化。
extension HistoryRowView: Equatable {
  // nonisolated：Equatable 是非隔离协议，比较的又都是传值的存储属性，
  // 不碰主线程状态；不标的话 Swift 6 视为跨隔离一致性拒绝编译。
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row
      && lhs.isSelected == rhs.isSelected
      && lhs.faviconURL == rhs.faviconURL
      && lhs.theme == rhs.theme
  }
}

/// 磁盘上的站点图标：内存缓存命中就直接画；未命中先画占位徽标，文件读取
/// 放到后台，读完入缓存再切换。以前是在行 body 里同步读盘构造图像——
/// 列表滚动或整表重建时，几十行图标的磁盘读取全部压在主线程上。
struct HistoryFaviconDiskImage<Fallback: View>: View {
  let url: URL
  let host: String
  let taskID: TaskID
  @ViewBuilder var fallback: () -> Fallback
  @State private var loaded: NSImage?

  var body: some View {
    if let image = HistoryFaviconImageMemoryCache.cachedImage(host: host, taskID: taskID, url: url) ?? loaded {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        .accessibilityHidden(true)
    } else {
      fallback()
        .task(id: url) {
          loaded = await HistoryFaviconImageMemoryCache.decodeImage(at: url, host: host, taskID: taskID)
        }
    }
  }
}

/// SwiftUI can recompute a row's body many times while selection, scrolling,
/// or favicon callbacks change. This process-local cache keeps disk image
/// decoding out of that hot path. `NSCache` is thread-safe and bounded, so it
/// remains safe when AppKit asks for a view from a different rendering thread.
///
/// body 里只允许查内存（`cachedImage`）；磁盘读取一律走 `decodeImage`——
/// 文件 I/O 在后台完成，只把字节变成 NSImage 这一步留在主线程（小图标
/// 的解码本身是微秒级，贵的是读盘）。
enum HistoryFaviconImageMemoryCache {
  nonisolated(unsafe) private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    return cache
  }()

  private static func keys(url: URL, host: String, taskID: TaskID) -> (host: NSString, task: NSString) {
    (
      "host:\(PlatformIconCatalog.normalizedHost(host))" as NSString,
      "task:\(taskID.rawValue):\(url.absoluteString)" as NSString
    )
  }

  static func cachedImage(host: String, taskID: TaskID, url: URL) -> NSImage? {
    let keys = keys(url: url, host: host, taskID: taskID)
    return images.object(forKey: keys.task) ?? images.object(forKey: keys.host)
  }

  @MainActor
  static func decodeImage(at url: URL, host: String, taskID: TaskID) async -> NSImage? {
    if let cached = cachedImage(host: host, taskID: taskID, url: url) { return cached }
    let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
    guard let bytes, let decoded = NSImage(data: bytes) else { return nil }
    let keys = keys(url: url, host: host, taskID: taskID)
    images.setObject(decoded, forKey: keys.host)
    images.setObject(decoded, forKey: keys.task)
    return decoded
  }
}

