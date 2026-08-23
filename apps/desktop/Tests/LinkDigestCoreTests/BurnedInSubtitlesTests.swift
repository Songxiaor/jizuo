import XCTest
@testable import LinkDigestCore

final class BurnedInSubtitlesTests: XCTestCase {
  private func line(_ text: String, _ midY: Double, _ minX: Double = 0) -> RecognizedTextLine {
    RecognizedTextLine(text: text, midY: midY, minX: minX)
  }

  /// 背景里的固定文字不能被当成字幕。
  ///
  /// fixture 照搬实测遇到的情况：讲台横幅上的 "Stanford" 每帧都在，而且位置比
  /// 字幕**更靠下**。任何「取画面下半部分」的做法都会稳稳地选中它。
  func testFixedBackgroundTextIsNotMistakenForSubtitles() {
    // 句子之间必须有真实的差异。用「第 N 句」那种只换一个字的构造，字符集
    // 几乎完全重合，会被相似度判据聚成一类——那是 fixture 失真，不是算法有错。
    let sentences = [
      "关于人工智能领域的职业建议",
      "过去几年我通常自己完成讲座",
      "今天我打算只分享几点想法",
      "然后就把时间交给我的好朋友",
      "他从西雅图特地赶来演讲",
      "为我们分享就业市场的全景图",
      "以及在这个行业发展的建议",
      "不过只有两张幻灯片而已",
      "还有一个想法想同大家分享",
      "那就是现在真的是最好的时机",
      "几个月前社交媒体上有个疑问",
      "就是这个领域是不是在放缓"
    ]
    // 帧数必须过 `minimumFramesForBackgroundDetection`，否则背景判定根本不启用。
    let frames = sentences.enumerated().map { index, sentence in
      VideoFrameText(timeSeconds: Double(index) * 3, lines: [
        line("Stanford", 0.12),  // 背景：位置更低，但贯穿每一帧
        line(sentence, 0.30)     // 字幕：位置更高，每帧都换
      ])
    }
    XCTAssertEqual(BurnedInSubtitles.subtitleBandCenter(in: frames).map { ($0 * 100).rounded() / 100 }, 0.30)

    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.count, sentences.count)
    XCTAssertFalse(
      cues.contains { $0.text.contains("Stanford") },
      "贯穿全片的背景文字必须被剔除"
    )
    XCTAssertEqual(cues.first?.text, sentences[0])
  }

  /// OCR 每帧把同一块背景认错成不同拼法时，仍要判成背景。
  ///
  /// 这是实测踩到的坑：讲台横幅被认成 Stantord/antora/antord/tantord，精确比
  /// 之下它成了「每帧都不同」的高变化内容，恰好骗过按变化频率挑字幕的判据。
  func testMisrecognizedBackgroundVariantsStillCountAsBackground() {
    let variants = ["Stanford", "Stantord", "antora", "antord", "tantord", "Stanfard"]
    let sentences = [
      "第一句完整的字幕内容在这里",
      "第二句讲的是完全不同的事情",
      "第三句又换了一个全新的话题",
      "第四句继续说别的内容",
      "第五句谈到另外一件事",
      "第六句是最后要说的话",
      "第七句其实还没有结束",
      "第八句才是真正的结尾",
      "第九句又多说了一点",
      "第十句到此为止吧",
      "第十一句补充一个细节",
      "第十二句正式收尾"
    ]
    let frames = sentences.enumerated().map { index, sentence in
      VideoFrameText(timeSeconds: Double(index) * 3, lines: [
        line(variants[index % variants.count], 0.12),
        line(sentence, 0.30)
      ])
    }
    XCTAssertTrue(
      BurnedInSubtitles.isSimilarText("Stantord", "antord"),
      "同一块横幅的两种错认必须算作相似"
    )
    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.map(\.text), sentences, "错拼的背景不该混进任何一条字幕")
  }

  /// 双行字幕必须按画面从上到下拼接。
  ///
  /// Vision 的 y 轴 0 在底边，所以「上面那行」是 midY 更大的那条。顺序颠倒
  /// 会让句子读不通，而且这种错在长稿里很难一眼看出来。
  func testTwoLineSubtitleKeepsTopToBottomOrder() {
    // 至少三帧：少于 `minimumFramesForBand` 的带一律不算字幕，那是有意的
    // 噪声门槛，不该在这条用例里被绕过。
    let frames = [
      VideoFrameText(timeSeconds: 0, lines: [
        line("第二行在下面", 0.22),
        line("第一行在上面", 0.30)
      ]),
      VideoFrameText(timeSeconds: 3, lines: [
        line("中间一句的下半", 0.22),
        line("中间一句的上半", 0.30)
      ]),
      VideoFrameText(timeSeconds: 6, lines: [
        line("另一句的下半", 0.22),
        line("另一句的上半", 0.30)
      ])
    ]
    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.first?.text, "第一行在上面 第二行在下面")
    XCTAssertEqual(cues.last?.text, "另一句的上半 另一句的下半")
  }

  /// 一句字幕停留数帧，只应产出一条。
  func testRepeatedFramesOfOneCueCollapse() {
    let frames = [
      VideoFrameText(timeSeconds: 0, lines: [line("同一句话", 0.30), line("LOGO", 0.12)]),
      VideoFrameText(timeSeconds: 3, lines: [line("同一句话", 0.30), line("LOGO", 0.12)]),
      VideoFrameText(timeSeconds: 6, lines: [line("同一句话。", 0.30), line("LOGO", 0.12)]),
      VideoFrameText(timeSeconds: 9, lines: [line("换了一句", 0.30), line("LOGO", 0.12)])
    ]
    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.map(\.text), ["同一句话", "换了一句"])
    XCTAssertEqual(cues.first?.startSeconds, 0, "合并后应保留最早出现的时间")
  }

  /// 同一句在第一帧读成乱码、下一帧读清楚时，应保留清楚版本而不是先到版本。
  func testRepeatedCueKeepsTheBetterChineseRecognition() {
    let frames = [
      VideoFrameText(timeSeconds: 0, lines: [
        line("仕公士自貼欢以物业生于的物业烂以。不过只有两张幻灯片。", 0.30)
      ]),
      VideoFrameText(timeSeconds: 3, lines: [
        line("在人工智能领域职业生涯中的职业建议。不过只有两张幻灯片。", 0.30)
      ]),
      VideoFrameText(timeSeconds: 6, lines: [line("还有一个想法想和大家分享。", 0.30)])
    ]

    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(
      cues.map(\.text),
      ["在人工智能领域职业生涯中的职业建议。不过只有两张幻灯片。", "还有一个想法想和大家分享。"]
    )
    XCTAssertEqual(cues.first?.startSeconds, 0, "择优后仍应保留这句最早出现的时间")
  }

  /// 两句都正常时，即使共用一段长短语也不能被当成乱码版本互相覆盖。
  func testAdjacentGoodCuesSharingALongPhraseAreBothKept() {
    let frames = [
      VideoFrameText(timeSeconds: 0, lines: [line("第一部分先说明为什么要关注人工智能职业生涯。", 0.30)]),
      VideoFrameText(timeSeconds: 3, lines: [line("第二部分再说明怎样规划人工智能职业生涯。", 0.30)]),
      VideoFrameText(timeSeconds: 6, lines: [line("接下来谈谈就业市场。", 0.30)])
    ]

    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.map(\.text), [
      "第一部分先说明为什么要关注人工智能职业生涯。",
      "第二部分再说明怎样规划人工智能职业生涯。",
      "接下来谈谈就业市场。"
    ])
  }

  /// 同一句逐字出现时，质量相当就保留更完整的一版。
  func testRepeatedCueKeepsTheMoreCompleteRendering() {
    XCTAssertTrue(BurnedInSubtitles.preferredCueText("这是完整的一句话", over: "这是完整的一句"))
    XCTAssertFalse(BurnedInSubtitles.preferredCueText("这是完整的一句", over: "这是完整的一句话"))
  }

  /// 逐字打出来的字幕算同一句；不同的句子不算。
  func testPartiallyRenderedCueCountsAsTheSameCue() {
    XCTAssertTrue(BurnedInSubtitles.isSameCue("这是完整的一句话", "这是完整的一句话"))
    XCTAssertTrue(BurnedInSubtitles.isSameCue("这是完整的一句话", "这是完整的一句话。"))
    XCTAssertFalse(BurnedInSubtitles.isSameCue("这是完整的一句话", "完全不同的另一句话"))
    // 前缀但长度差太多：那是下一句刚开始渲染，不该并进上一句。
    XCTAssertFalse(BurnedInSubtitles.isSameCue("这是", "这是完整的一句话啊啊啊"))
  }

  /// 同一句话在相隔很远处再次出现，必须保留。
  ///
  /// 只跟上一条比而不做全局去重，正是为了这个：口头禅和重复强调在长视频里
  /// 很常见，全局去重会把它们悄悄吃掉，且几乎无法察觉。
  func testSameSentenceReappearingLaterIsKept() {
    let frames = [
      VideoFrameText(timeSeconds: 0, lines: [line("我们继续", 0.30), line("台标", 0.12)]),
      VideoFrameText(timeSeconds: 3, lines: [line("中间说了别的", 0.30), line("台标", 0.12)]),
      VideoFrameText(timeSeconds: 6, lines: [line("我们继续", 0.30), line("台标", 0.12)])
    ]
    let cues = BurnedInSubtitles.compose(frames: frames)
    XCTAssertEqual(cues.map(\.text), ["我们继续", "中间说了别的", "我们继续"])
  }

  /// 没有字幕的视频不该硬凑出字幕。
  func testVideoWithoutVaryingTextYieldsNoCues() {
    // 只有一个始终不变的台标：变化度为 1，达不到判为字幕的门槛。
    let frames = (0..<6).map { index in
      VideoFrameText(timeSeconds: Double(index) * 3, lines: [line("台标", 0.12)])
    }
    XCTAssertNil(BurnedInSubtitles.subtitleBandCenter(in: frames))
    XCTAssertEqual(BurnedInSubtitles.compose(frames: frames), [])
    XCTAssertEqual(BurnedInSubtitles.compose(frames: []), [])
  }

  /// 偶发的误识别不该被选成字幕带。
  func testTransientNoiseBandIsIgnored() {
    var frames: [VideoFrameText] = (0..<8).map { index in
      VideoFrameText(timeSeconds: Double(index) * 3, lines: [line("字幕第 \(index) 句", 0.30)])
    }
    // 画面顶部两帧闪过的转场残影：文本各不相同，但只出现 2 帧。
    frames[0] = VideoFrameText(timeSeconds: 0, lines: frames[0].lines + [line("噪声甲", 0.90)])
    frames[1] = VideoFrameText(timeSeconds: 3, lines: frames[1].lines + [line("噪声乙", 0.90)])

    let center = try? XCTUnwrap(BurnedInSubtitles.subtitleBandCenter(in: frames))
    XCTAssertNotNil(center)
    XCTAssertEqual(center.map { ($0 * 100).rounded() / 100 }, 0.30, "只出现两帧的噪声带不该胜出")
  }
}
