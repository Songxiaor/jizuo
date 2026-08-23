import Foundation
import NaturalLanguage

/// 一帧画面里识别出的一行文字，带归一化位置。
///
/// `midY` 用 Vision 的坐标系：0 是画面底边，1 是顶边。保留位置是这条链路的
/// 全部意义所在——烧录字幕靠的就是「它总出现在画面同一条带上」这个性质，
/// 丢了坐标就只剩一锅混着背景文字的字符串。
public struct RecognizedTextLine: Sendable, Equatable {
  public let text: String
  public let midY: Double
  public let minX: Double
  /// 归一化宽度。字幕横跨画面，角标和图表标注只占一小条——这是把它们分开
  /// 最可靠的一个特征，比文字内容稳定得多。
  public let width: Double

  public init(text: String, midY: Double, minX: Double = 0, width: Double = 1) {
    self.text = text
    self.midY = midY
    self.minX = minX
    self.width = width
  }
}

/// 视频某一时刻整帧的识别结果。
public struct VideoFrameText: Sendable, Equatable {
  public let timeSeconds: Double
  public let lines: [RecognizedTextLine]

  public init(timeSeconds: Double, lines: [RecognizedTextLine]) {
    self.timeSeconds = timeSeconds
    self.lines = lines
  }
}

/// 一条合成好的字幕。
public struct BurnedInSubtitleCue: Sendable, Equatable {
  public let startSeconds: Double
  public let text: String

  public init(startSeconds: Double, text: String) {
    self.startSeconds = startSeconds
    self.text = text
  }
}

/// 把逐帧 OCR 结果合成为烧录字幕稿。
///
/// 为什么值得做：中文博主搬运英文视频时几乎必带烧录字幕，而那份字幕通常是
/// **人工翻译**的——比任何 ASR 加机翻都准，还省掉翻译这一步。
///
/// 这里只做纯逻辑，抽帧和 OCR 留在 adapter，于是整套判据都能用构造数据测。
public enum BurnedInSubtitles {
  /// 两次相邻抽帧最多允许隔这么久，才可能还是同一句字幕。
  ///
  /// 默认每 3 秒抽一帧；6.5 秒容得下一次偶发漏识别，但不会把稍后再次说出的
  /// 同一句话做全局去重。
  static let maximumRepeatedCueObservationGap: Double = 6.5

  /// OCR 严重抖动时，整句字符集合可能已经不像同一句，但通常仍有一截连续文字
  /// 是可靠的。连续 8 个字符足以作为同一句的锚点，又比「不过」「所以」这类
  /// 常见短语严格得多。
  static let minimumSharedCueAnchorLength = 8

  /// y 方向分桶的宽度。字幕行在不同帧之间会有一两个像素的浮动，桶太窄会把
  /// 同一条带切成两半。
  static let bandBucketHeight = 0.04

  /// 以字幕带为中心、上下各纳入多少。
  ///
  /// 0.12 而不是 0.08：双行字幕的两行中心相距约 0.074，每行自身还有约 0.07 的
  /// 高度，±0.08 只够到上行的中线，上半截被切掉——喂给 OCR 的就是残字，识别
  /// 结果随之崩坏（「衡量」认成「復量」这类）。宁可多带进一点背景，那些有
  /// 几何过滤和噪声词表兜底，而被切掉的字没有任何办法补回来。
  ///
  /// 对外可见：adapter 的第二阶段要按这条带去裁剪画面，裁剪范围必须和合成时
  /// 采用的范围完全一致，否则两阶段算出的 y 不在一个尺度上。
  // 0.08 是实测出来的最优值，上下都不能动：
  //
  // - 带心算对时（双行字幕中点 ≈0.100），±0.08 得到 0.02~0.18，正好贴住双行
  //   字幕的上下沿；
  // - 放宽到 ±0.12 会把 y≈0.185 的年份刻度（2020/2022/…）圈进来，多余字符
  //   干扰识别，「衡量」会被认成「復量」；
  // - 收窄则切掉双行字幕的上行，喂进 OCR 的是残字。
  //
  // 裁剪要**贴合**，不是越宽越安全——每多进来一行背景，识别质量都掉一截。
  public static let bandHalfHeight = 0.08

  /// 一条带至少要在这么多帧里出现过，才考虑当字幕。一两帧就消失的多半是
  /// 转场残影或误识别。
  static let minimumFramesForBand = 3

  /// 贴着右边缘开始的文字是角标，不是字幕。
  ///
  /// 实测讲者署名固定落在 x=0.89~1.00，而字幕行从 x≤0.16 起头。用起点位置
  /// 判角标比用文字内容稳：署名每帧都被认成同样几个词，覆盖率却可能达不到
  /// 背景阈值（它只在部分片段出现），于是一路混进字幕末尾。
  static let cornerBadgeMinX = 0.85

  /// 窄于这个宽度的文字不是字幕。
  ///
  /// 字幕是横跨画面的长行（实测 0.66~0.80）；幻灯片上的零散标注只有
  /// 0.03~0.18（`CC-BY`、`METR`、年份刻度）。0.25 把两类分得很开，又给
  /// 短句留了余量。
  static let minimumSubtitleWidth = 0.25

  /// 这一行看起来像不像字幕。
  static func isSubtitleShaped(_ line: RecognizedTextLine) -> Bool {
    line.minX < cornerBadgeMinX && line.width >= minimumSubtitleWidth
  }

  /// 一行文字出现在超过这个比例的帧里，就判为背景而不是字幕。
  ///
  /// 字幕再长也只占几帧；台标、横幅、水印则贯穿全片。0.4 给了很大余量——
  /// 真字幕要越过它，得连续占满四成片长还一字不变。
  static let backgroundFrameRatio = 0.4

  /// 一条带里「内容种类数 ÷ 覆盖帧数」低于这个比值，就算内容基本不变。
  ///
  /// 水印每帧都在但翻来覆去就那么几种识别结果；字幕则几乎每换一帧就是一句
  /// 新的，比值接近 1。0.3 把两者分得很开。
  static let backgroundVarietyRatio = 0.3

  /// 少于这么多帧就不做背景判定。
  ///
  /// 「占了四成帧」这个判据在小样本上毫无意义：一句停留 3 帧的字幕，在 4 帧的
  /// 样本里就占了 75%，会被当成水印剔掉。帧数不够时宁可不判——背景混进来只是
  /// 脏一点，把真字幕判成背景则是整段丢失。
  static let minimumFramesForBackgroundDetection = 10

  /// 两行文字算不算「同一个东西的两次识别」。
  ///
  /// 必须模糊比，不能精确比。实测同一块 "Stanford" 横幅在相邻帧被认成
  /// `Stantord`/`antora`/`antord`/`tantord`——精确比之下它成了「每帧都不同」的
  /// 高变化内容，恰好骗过按变化频率挑字幕的判据，把背景当成字幕选中。
  ///
  /// 用字符集合的 Jaccard 相似度：拼错几个字母仍高度重合，而两句不同的话
  /// 重合度很低。前缀关系另算，那是字幕逐字渲染的形态。
  static func isSimilarText(_ lhs: String, _ rhs: String, threshold: Double = 0.75) -> Bool {
    let a = normalize(lhs)
    let b = normalize(rhs)
    if a == b { return true }
    guard !a.isEmpty, !b.isEmpty else { return false }
    // 长度差一倍以上不可能是同一块文字的两次识别。
    let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
    guard ratio >= 0.5 else { return false }
    let setA = Set(a)
    let setB = Set(b)
    let intersection = setA.intersection(setB).count
    let union = setA.union(setB).count
    guard union > 0 else { return false }
    // 默认 0.75 而不是更松的值：同一块横幅的两次错认（stantord / antord）能到
    // 0.85，而句式雷同、只换了个别字的两句**不同**字幕大约落在 0.75 以下。
    // 阈值定在这中间，才不会把连续的相似字幕整段当成水印剔掉。
    return Double(intersection) / Double(union) >= threshold
  }

  /// 找出贯穿全片的背景文字（台标、横幅、水印）。
  ///
  /// 判据是「**同一条带上、同一段文字**覆盖了大部分帧」，两个条件缺一不可。
  ///
  /// 只按位置整桶判会漏：实测讲台横幅的 "Stanford" 落在 midY≈0.122，而双行
  /// 字幕的上行在 0.135——**同一个桶**。整桶剔掉，每句字幕的上半行跟着消失；
  /// 整桶保留，横幅就混进每一条字幕。
  ///
  /// 只按文本聚类判也漏：OCR 把同一块横幅认成 Stantord/antora/antord，字符
  /// 相似度低到 0.62，聚不到一起。
  ///
  /// 两者结合才稳：先按 y 分桶缩小范围，桶内再按相似度聚类，看哪一类覆盖了
  /// 大半片长。横幅每帧都在（接近 100%），而任何一句字幕只占几帧。
  static func backgroundTexts(in frames: [VideoFrameText]) -> [(bucket: Int, text: String)] {
    guard frames.count >= minimumFramesForBackgroundDetection else { return [] }
    var clustersByBucket: [Int: [(representative: String, frames: Set<Int>)]] = [:]
    for (frameIndex, frame) in frames.enumerated() {
      for line in frame.lines {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalize(text).isEmpty else { continue }
        let bucket = Int((line.midY / bandBucketHeight).rounded(.down))
        var clusters = clustersByBucket[bucket] ?? []
        // 有了同桶这个前提，相似度可以放宽到 0.6：同一条带上长得像的东西，
        // 本来就更可能是同一个东西的反复识别。
        if let hit = clusters.firstIndex(where: { isSimilarText($0.representative, text, threshold: 0.6) }) {
          clusters[hit].frames.insert(frameIndex)
        } else {
          clusters.append((representative: text, frames: [frameIndex]))
        }
        clustersByBucket[bucket] = clusters
      }
    }

    let threshold = Double(frames.count) * backgroundFrameRatio
    var background: [(bucket: Int, text: String)] = []
    for (bucket, clusters) in clustersByBucket {
      for cluster in clusters where Double(cluster.frames.count) >= threshold {
        background.append((bucket: bucket, text: cluster.representative))
      }
    }
    return background
  }

  /// 判定「粘连噪声」时用的覆盖率门槛。
  ///
  /// 比整行剔除的门槛低得多：候选只从**不像字幕**的行里收集，字幕自己的内容
  /// 根本进不了这张表，所以放低阈值不会误删正文。
  ///
  /// 0.1 是被实测逼下来的：幻灯片角标 `METR` 只在讲幻灯片的那几分钟出现，
  /// 按 0.2 算刚好卡在门槛外，于是它在与字幕粘成一行的那些帧里活了下来。
  static let stuckNoiseFrameRatio = 0.1

  /// 从拼好的句子里摘掉粘连的背景词。
  ///
  /// 几何过滤挡不住这一类：OCR 会把靠得太近的两块文字并成**同一行**——实测
  /// `地球上其他人都无法做到的功能，对吧？METR`、以及字幕末尾粘上讲者署名
  /// 的 `…所以几年前PcreWNg`。噪声这时已经和字幕同处一个文本块，只能按
  /// 文本清理。
  ///
  /// 只摘 5 个字符以上、且**贯穿多帧**的固定词（台标、机构名、署名）。
  ///
  /// 门槛从 3 提到 5 是被实测逼的：幻灯片图表上反复出现 `GPT 3.5`、`GPT 4o`
  /// 这类标注，`GPT` 因此进了噪声词表，把字幕里正当的「GPT-5 有那么好吗」
  /// 摘成了「 -5 有那么好吗」。**摘掉正文比留下噪声严重得多**，宁可放过短词。
  /// `Stanford`(8)、`tanford`(7)、`Andrew Ng`(9) 都在门槛之上，不受影响。
  static func strippingStuckNoise(_ text: String, noise: [String]) -> String {
    var cleaned = text
    for word in noise where word.count >= 5 {
      cleaned = cleaned.replacingOccurrences(of: word, with: " ")
    }
    // 摘掉词以后往往留下多余空格。
    while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 贯穿多帧、可能与字幕粘在一起的固定词。
  static func stuckNoiseWords(in frames: [VideoFrameText]) -> [String] {
    guard frames.count >= minimumFramesForBackgroundDetection else { return [] }
    var clusters: [(representative: String, variants: Set<String>, frames: Set<Int>)] = []
    for (index, frame) in frames.enumerated() {
      // 只看**不像字幕**的行：字幕自己的内容不该被当成噪声词摘掉。
      for line in frame.lines where !isSubtitleShaped(line) {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, !normalize(text).isEmpty else { continue }
        if let hit = clusters.firstIndex(where: { isSimilarText($0.representative, text, threshold: 0.7) }) {
          clusters[hit].frames.insert(index)
          clusters[hit].variants.insert(text)
        } else {
          clusters.append((representative: text, variants: [text], frames: [index]))
        }
      }
    }
    let threshold = Double(frames.count) * stuckNoiseFrameRatio
    // 返回聚类里的**每一种写法**，不只代表词。
    //
    // 摘除是精确子串替换，而粘进字幕的往往是残缺变体：横幅 "Stanford" 粘过来
    // 时是 `tanford`（掉了首字母），拿代表词去替换根本匹配不到。长的排前面，
    // 先摘长的，避免短变体先把长的切断。
    return clusters
      .filter { Double($0.frames.count) >= threshold }
      .flatMap { $0.variants }
      .sorted { $0.count > $1.count }
  }

  /// 剔除背景带之后的帧。
  static func removingBackground(from frames: [VideoFrameText]) -> [VideoFrameText] {
    let background = backgroundTexts(in: frames)
    guard !background.isEmpty else { return frames }
    return frames.map { frame in
      VideoFrameText(
        timeSeconds: frame.timeSeconds,
        lines: frame.lines.filter { line in
          let bucket = Int((line.midY / bandBucketHeight).rounded(.down))
          return !background.contains {
            $0.bucket == bucket && isSimilarText($0.text, line.text, threshold: 0.6)
          }
        }
      )
    }
  }

  /// 找出字幕所在的那条横带。
  ///
  /// 判据是**内容变化频率**，不是位置高低：只按「画面下半部分」取会稳稳地把
  /// 背景文字收进来——实测讲台横幅上的 "Stanford" 每帧都在，位置比字幕还低。
  ///
  /// 调用前必须先剔除背景（`removingBackground`），否则被 OCR 抖动伪装成
  /// 高变化内容的背景会跟字幕抢这条带。
  public static func subtitleBandCenter(in frames: [VideoFrameText]) -> Double? {
    bandCenter(in: removingBackground(from: frames))
  }

  /// 定位字幕带本身。输入必须是**已剔除背景**的帧，否则判据会被背景带走。
  static func bandCenter(in frames: [VideoFrameText]) -> Double? {
    var textsByBucket: [Int: Set<String>] = [:]
    var framesByBucket: [Int: Set<Int>] = [:]
    for (frameIndex, frame) in frames.enumerated() {
      // 只让像字幕的行参与定位。幻灯片上的年份刻度每页都在变，变化度不比
      // 字幕低，会把字幕带的包络一路撑到图表中部。
      for line in frame.lines where isSubtitleShaped(line) {
        let normalized = normalize(line.text)
        guard !normalized.isEmpty else { continue }
        let bucket = Int((line.midY / bandBucketHeight).rounded(.down))
        textsByBucket[bucket, default: []].insert(normalized)
        framesByBucket[bucket, default: []].insert(frameIndex)
      }
    }

    // 逐步写开而不是链式：filter→map 成元组→sorted 连在一起会让 Swift 的类型
    // 检查器超时（实测 `error: unable to type-check this expression in
    // reasonable time`），显式标注中间类型可以避免。
    var candidates: [(bucket: Int, variety: Int)] = []
    for (bucket, texts) in textsByBucket {
      let frameCount = framesByBucket[bucket]?.count ?? 0
      guard frameCount >= minimumFramesForBand else { continue }
      candidates.append((bucket: bucket, variety: texts.count))
    }
    // 并列时取靠下的桶（bucket 值小 = 更靠近画面底部）：字幕在下方是绝大
    // 多数视频的排版，用它当平手时的决胜，比随机挑一个稳。
    candidates.sort { lhs, rhs in
      lhs.variety == rhs.variety ? lhs.bucket < rhs.bucket : lhs.variety > rhs.variety
    }

    guard let best = candidates.first, best.variety >= 2 else { return nil }

    // 取所有「变化同样频繁」的桶的**包络中心**，而不是最高那一个桶的中心。
    //
    // 双行字幕分处两个桶：实测上行 midY≈0.135、下行≈0.061，相距 0.074。只认
    // 下行那个桶，再往上下各取 0.08，上边界落在 0.14，而上行文字实际占到
    // 0.17——上沿被切掉，OCR 读不出，于是每句都只剩下半行。
    //
    // 门槛取最高变化度的一半：真字幕的两行出现次数接近，而偶发噪声带远达不到。
    let cutoff = max(2, best.variety / 2)
    let related = candidates.filter { $0.variety >= cutoff }.map(\.bucket)
    guard let lowest = related.min(), let highest = related.max() else {
      return (Double(best.bucket) + 0.5) * bandBucketHeight
    }
    return (Double(lowest) + Double(highest) + 1) / 2 * bandBucketHeight
  }

  /// 逐帧结果 → 字幕稿。
  public static func compose(frames: [VideoFrameText]) -> [BurnedInSubtitleCue] {
    // 先摘掉贯穿全片的背景文字，再定位字幕带。顺序不能反：被 OCR 抖动伪装成
    // 高变化内容的背景会跟字幕抢这条带，而且即便带选对了，同一条带上的背景
    // 也会被拼进每一句字幕里。
    let cleaned = removingBackground(from: frames)
    // 几何过滤挡不住 OCR 把噪声与字幕并成一行的情况，留到文本层再摘一次。
    let noiseWords = stuckNoiseWords(in: frames)
    guard let center = bandCenter(in: cleaned) else { return [] }
    let lower = center - bandHalfHeight
    let upper = center + bandHalfHeight

    var cues: [BurnedInSubtitleCue] = []
    var lastCueObservationTime: Double?
    for frame in cleaned.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
      let banded = frame.lines
        .filter { $0.midY >= lower && $0.midY <= upper }
        .filter { !normalize($0.text).isEmpty }
        // 落在字幕带里不等于就是字幕：右下角的讲者署名、图表底部的零散标注
        // 都可能挤在同一条带上，几何特征才认得出它们。
        .filter(isSubtitleShaped)
        // 画面从上到下 = midY 从大到小。双行字幕颠倒过来就读不通了。
        .sorted { lhs, rhs in
          abs(lhs.midY - rhs.midY) > 0.01 ? lhs.midY > rhs.midY : lhs.minX < rhs.minX
        }
      guard !banded.isEmpty else { continue }
      let joined = banded.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let text = strippingStuckNoise(joined, noise: noiseWords)
      guard !text.isEmpty else { continue }

      // 一句字幕会在画面上停留好几帧，抽帧必然重复抓到它。只跟**上一条**比，
      // 不做全局去重：同一句话在长视频里真的会再次出现（口头禅、重复强调），
      // 全局去重会把它们悄悄吃掉。
      if let last = cues.last {
        let strictlySame = isSameCue(last.text, text)
        let gap = frame.timeSeconds - (lastCueObservationTime ?? last.startSeconds)
        let looselySame = !strictlySame
          && gap >= 0 && gap <= maximumRepeatedCueObservationGap
          && isCorruptedRecognitionOfSameCue(last.text, text)
        if strictlySame || looselySame {
          // 以前遇到重复帧一律保留第一版。这在第一帧恰好被 OCR 读坏时会把坏版
          // 永久留下，后面同一句的清楚版本反而被丢掉。现在保留最早时间，但文本
          // 在有明确质量优势时换成更好的那版。
          if preferredCueText(text, over: last.text) {
            cues[cues.count - 1] = BurnedInSubtitleCue(
              startSeconds: last.startSeconds,
              text: text
            )
          }
          lastCueObservationTime = frame.timeSeconds
          continue
        }
      }
      cues.append(BurnedInSubtitleCue(startSeconds: frame.timeSeconds, text: text))
      lastCueObservationTime = frame.timeSeconds
    }
    return cues
  }

  /// 两版文字整体已经不像，但是否仍可判为「同一句的好版和坏版」。
  ///
  /// 必须同时满足三件事：有一截足够长的连续共同文字、共同文字占比不低、两版
  /// 中文分词质量有明显差距。最后一条很重要——相邻两句都通顺、只是恰好复用
  /// 了一段长短语时不能合并；只有一版明显由大量单字碎片组成时才做择优。
  static func isCorruptedRecognitionOfSameCue(_ lhs: String, _ rhs: String) -> Bool {
    let a = normalize(lhs)
    let b = normalize(rhs)
    guard !a.isEmpty, !b.isEmpty else { return false }
    let shared = longestSharedSubstringLength(a, b)
    let shorterCount = min(a.count, b.count)
    guard shared >= minimumSharedCueAnchorLength,
          Double(shared) / Double(shorterCount) >= 0.25 else { return false }
    return abs(cueTextQuality(lhs) - cueTextQuality(rhs)) >= 0.12
  }

  /// 候选是否明确优于已保留版本。
  static func preferredCueText(_ candidate: String, over current: String) -> Bool {
    let candidateNormalized = normalize(candidate)
    let currentNormalized = normalize(current)
    // 一版完整包含另一版时，这是逐字渲染的明确证据，先保留更完整的版本；
    // 标点差异不参与长度比较。
    if candidateNormalized.hasPrefix(currentNormalized)
        || currentNormalized.hasPrefix(candidateNormalized) {
      return candidateNormalized.count > currentNormalized.count
    }

    let candidateQuality = cueTextQuality(candidate)
    let currentQuality = cueTextQuality(current)
    return candidateQuality - currentQuality >= 0.02
  }

  /// 本地判断一版中文 OCR 像不像正常句子，不调用模型、不上传文字。
  ///
  /// 单看「汉字比例」不够：`仕公士自貼欢以物业生` 也全是汉字。系统中文分词器
  /// 会把正常的「人工智能 / 职业 / 生涯 / 建议」识别成词，而乱码通常碎成大量
  /// 单字。这里按落在多字词里的汉字占比评分，再辅以整体汉字比例。
  static func cueTextQuality(_ text: String) -> Double {
    let meaningful = text.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
        && !CharacterSet.punctuationCharacters.contains($0)
    }
    guard !meaningful.isEmpty else { return 0 }
    let hanCount = meaningful.filter(isHan).count
    let hanRatio = Double(hanCount) / Double(meaningful.count)
    guard hanCount >= 4, hanRatio >= 0.5 else { return hanRatio }

    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    tokenizer.setLanguage(.simplifiedChinese)
    var hanInWords = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let tokenHanCount = text[range].unicodeScalars.filter(isHan).count
      if tokenHanCount >= 2 { hanInWords += tokenHanCount }
      return true
    }
    let wordCoverage = Double(hanInWords) / Double(hanCount)
    return hanRatio * 0.25 + wordCoverage * 0.75
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
    default: false
    }
  }

  /// 最长公共连续片段长度。字幕通常只有几十字，O(n*m) 的两行动态规划足够小，
  /// 也比引入模糊搜索依赖更可控。
  static func longestSharedSubstringLength(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var previous = Array(repeating: 0, count: b.count + 1)
    var best = 0
    for left in a {
      var current = Array(repeating: 0, count: b.count + 1)
      for (index, right) in b.enumerated() where left == right {
        current[index + 1] = previous[index] + 1
        best = max(best, current[index + 1])
      }
      previous = current
    }
    return best
  }

  /// 两帧文本算不算同一句字幕。
  ///
  /// 不用严格相等：OCR 在相邻帧之间会有个把字的抖动（漏字、把「•」认成「：」）。
  /// 也不用编辑距离——一句字幕正在逐字打出来时，前缀关系比距离更能说明问题。
  ///
  /// 对外可见：「这两条是不是同一句」对调用方同样有用——把字幕稿并进别的
  /// 文本、或校验去重效果时都要问这个问题，各自再实现一套只会各自漂移。
  public static func isSameCue(_ lhs: String, _ rhs: String) -> Bool {
    let a = normalize(lhs)
    let b = normalize(rhs)
    if a == b { return true }
    guard !a.isEmpty, !b.isEmpty else { return false }
    let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
    // 短的那条是长的前缀，且长度差不多：同一句的两个渲染阶段。
    if longer.hasPrefix(shorter), Double(shorter.count) / Double(longer.count) >= 0.8 {
      return true
    }
    // 前缀判据挡不住 OCR 抖动。实测同一句字幕的三个渲染阶段被认成
    // 「还有 个想法」「还有一个想法想」「还有 —个想法根」——从「还有」之后就
    // 分叉了，谁也不是谁的前缀，于是同一句被留成三条。
    //
    // 这里的阈值比 `isSimilarText` 的默认值更严（0.85）：字幕去重一旦误判，
    // 丢掉的是一整句正文；而背景剔除误判只是多留一行噪声。宁可少合并。
    return isSimilarText(a, b, threshold: 0.85)
  }

  /// 比对用的归一化：抹掉空白和常见标点差异，只留下判断「是不是同一句」所需的信息。
  static func normalize(_ text: String) -> String {
    let stripped = text.unicodeScalars.filter { scalar in
      !CharacterSet.whitespacesAndNewlines.contains(scalar)
        && !CharacterSet.punctuationCharacters.contains(scalar)
    }
    return String(String.UnicodeScalarView(stripped)).lowercased()
  }
}

extension BurnedInSubtitles {
  /// 字幕稿的时间戳。与听写稿同一种写法（`0:00` / `1:44:39`），这样两层在
  /// 阅读区并排时格式一致，跳转定位的习惯也一样。
  public static func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%02d:%02d", m, s)
  }

  /// 一段字幕攒到这么多字就换段。
  ///
  /// 与听写稿的软换行上限一致，两层读起来才是同一种节奏。
  static let paragraphCharacterTarget = 170

  /// 相邻两条字幕间隔超过这么久，视为话题断开，另起一段。
  static let paragraphGapSeconds: Double = 12

  /// 合成好的字幕 → 可落库的正文。
  ///
  /// 一句一行是字幕的形态，不是文章的形态：逐条列出来又碎又难读，满屏时间码
  /// 反而盖过内容。这里按「攒够字数」或「出现明显停顿」合并成段落，只在段首
  /// 留一个时间码——和听写稿的排版对齐。
  public static func markdown(from cues: [BurnedInSubtitleCue]) -> String {
    guard !cues.isEmpty else { return "" }
    var paragraphs: [String] = []
    var current: [String] = []
    var currentStart = cues[0].startSeconds
    var currentLength = 0
    var previousStart = cues[0].startSeconds

    func flush() {
      guard !current.isEmpty else { return }
      paragraphs.append("\(timestamp(currentStart)) " + current.joined(separator: ""))
      current = []
      currentLength = 0
    }

    for cue in cues {
      let gap = cue.startSeconds - previousStart
      if !current.isEmpty, currentLength >= paragraphCharacterTarget || gap >= paragraphGapSeconds {
        flush()
        currentStart = cue.startSeconds
      }
      if current.isEmpty { currentStart = cue.startSeconds }
      current.append(cue.text)
      currentLength += cue.text.count
      previousStart = cue.startSeconds
    }
    flush()
    return paragraphs.joined(separator: "\n\n")
  }
}

/// 从视频画面里读烧录字幕。
///
/// 放在 Core 只为**依赖方向**：视图层要能持有它而不必依赖某个具体的识别引擎。
public protocol VideoSubtitleReading: Sendable {
  /// 全程本机，不得上传任何画面或音频。
  func readSubtitles(
    fileURL: URL,
    languages: [String],
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> [BurnedInSubtitleCue]
}
