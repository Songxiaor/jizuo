import Foundation
import LinkDigestCore

/// Sends transcript text (never audio, never the media URL) to the user's
/// configured chat provider for 听写还原. Title and caption ride along as
/// context on every chunk. Chunks are tidied independently; a failed chunk
/// keeps its original text so a partial outage can never lose transcript content.
public final class OpenAICompatibleTranscriptTidier: TranscriptTidying, @unchecked Sendable {
  /// 同时在飞的整理请求数。整理和翻译一样是输出受限的活（产出与原文同量级，
  /// 模型只能逐 token 吐），分片之间互不依赖，串行等于把耗时按片数线性叠加：
  /// 半小时视频的转写稿切 6 片、每片几十秒，串行就是三五分钟白等。
  /// 取 3 而不是翻译那样可调到更高：整理经常在自动管线里与总结/翻译同时跑，
  /// 再抬高会和它们抢同一个服务商的速率配额。
  /// 同时在飞的校对请求数。
  ///
  /// **不要照抄翻译的 6。** 校对和翻译确实都是输出受限的活，但两者的请求形状
  /// 不同：校对每片都要额外带上标题与配文作为上下文，单请求更重，6 路并发实测
  /// 直接被服务端限流——一次 7 段的校对里 6 段失败，失败分片静默回填原文，
  /// 界面显示「已保存」而错字一个没改，比慢得多更糟。
  ///
  /// 3 是实测能稳定跑完的值。真要更快，该换更快的模型，而不是加并发。
  public static let maximumConcurrentChunkRequests = 3

  /// 单片最多这么多字。
  ///
  /// **这是为了不撞请求超时（180 秒），不是为了省 token。**
  ///
  /// 校对的输出和输入同量级：6000 字的片要模型吐出 6000 字，按常见速度正好逼近
  /// 180 秒。实测一次 7 段的校对里 6 段失败、总耗时 175 秒——几乎就是超时线，
  /// 而失败的片会静默回填原文，界面显示「已保存」而错字一个没改。
  ///
  /// 切到 2000 字，单片生成约几十秒，离超时留出数倍余量。片数变多了，但它们是
  /// 并发跑的；宁可多跑几波，也不要一波里大半超时。
  ///
  /// 再降到 1200（2026-09-28）：服务商网关自己还有一道约 120 秒的限制，诊断日志里
  /// 1700 字的片要 60–110 秒，最慢的开头片三次里两次在 125 秒时被网关掐掉，重试同样
  /// 大小的片还是会撞上。1200 字约 40–65 秒，离这道线留出余量。
  private static let maximumChunkCharacters = 1_200

  /// 清单模式（听写稿）的单片字数。
  ///
  /// 和整段模式一样取 1200（2026-10-04 实测）：输出虽然只剩改动，但关不掉思考的线路上，
  /// 耗时的大头是模型的思考，而思考量随原文长度涨——1870 字的片思考 3800–5400 token、
  /// 要 80–96 秒，第三片在 127 秒时被服务商网关掐断。片放大只对能关思考的线路有好处，
  /// 那种线路每片本来就只要几秒，片小一点也不慢。
  static let editListChunkCharacters = 1_200

  private let configurationService: ProviderConfigurationService
  private let provider: OpenAICompatibleProvider

  public init(
    configurationService: ProviderConfigurationService,
    provider: OpenAICompatibleProvider = OpenAICompatibleProvider()
  ) {
    self.configurationService = configurationService
    self.provider = provider
  }

  /// 取凭据，并把「没配」和「这次读不出来」分开。
  ///
  /// 分开是因为用户动作相反：前者要去设置里填，后者只需重试。原来两者都报
  /// 「请先在设置中保存文本模型」——实测点一次校对失败，配置却完好无损，
  /// 人被指向了一个根本没问题的地方。
  ///
  /// 超时额外自动重试一次：钥匙串首读慢是**一次性**的（App 重新签名后系统要
  /// 重新评估一次代码签名，之后就有缓存）。让用户手动重试一次才能用，等于把
  /// 一个已知的一次性延迟变成每次部署后必踩的坑。
  static func loadCredentials(
    from configurationService: ProviderConfigurationService,
    model: String? = nil
  ) async throws -> (profile: ProviderProfile, apiKey: String) {
    var timedOutOnce = false
    while true {
      do {
        guard let loaded = try await configurationService.loadCredentials(forModel: model) else {
          // 真的没有 profile，这时「去设置里配」才是对的指引。
          throw TranscriptTidyError.modelNotConfigured
        }
        return loaded
      } catch let error as TranscriptTidyError {
        throw error
      } catch ProviderConfigurationError.secretStoreReadTimedOut where !timedOutOnce {
        timedOutOnce = true
        continue
      } catch {
        throw TranscriptTidyError.credentialsUnavailable
      }
    }
  }

  public func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    // 老接口只认两个数：补跑阶段没法表达，照旧只报成功段数。
    var phase: (@Sendable (TranscriptTidyPhase) -> Void)?
    if let progress {
      phase = { value in
        if case let .tidying(succeeded, total) = value { progress(succeeded, total) }
      }
    }
    return try await tidy(text: text, model: model, style: style, context: context, phase: phase)
  }

  /// 这份稿子会被切成几段。估时和真正执行用同一份切法，免得界面说的段数和实际对不上。
  static func chunks(for text: String, style: TidyStyle = .transcript) -> [String] {
    let maximum = style.usesEditList ? Self.editListChunkCharacters : Self.maximumChunkCharacters
    // 片长按并发反算，让片数落在并发的整数倍上。
    //
    // 耗时 ≈ ⌈片数 ÷ 并发⌉ × 单片耗时。片数不是并发整数倍时，最后一波多数通道
    // 在空转：34,406 字按固定 6000 切出 6 片、并发 6 本可一波跑完，而 110,228 字
    // 会切出 19 片，第 4 波只剩 1 片在跑、另外 5 条通道白等——这一波的时间不花
    // 任何额外配额就能省掉。
    //
    // 但**整篇装得下就绝不能切**。这个反算只在片数多于并发时才有意义；稿子短到
    // 一片就够时，它反而会把不该切的切开：`chunkLimit` 的下限是 1500，于是一份
    // 1557 字的字幕稿（上限本是 2000，整篇发绰绰有余）被切成两片——大片失败、
    // 只剩几十字的尾巴片成功，用户看到的是「校对完几乎没变」，还白扣一次配额。
    // 实测那次 prompt_tokens=409、completion=38，正是那条尾巴。
    let trimmedCharacterCount = text.trimmingCharacters(in: .whitespacesAndNewlines).count
    let chunkLimit = trimmedCharacterCount <= maximum
      ? maximum
      // 通用反算有 1500 字的下限（给翻译用的），会压过校对这里更低的上限，再夹一道。
      : min(maximum, ChunkedTranslationStreamer.chunkLimit(
          forCharacterCount: trimmedCharacterCount,
          concurrency: Self.maximumConcurrentChunkRequests,
          maximum: maximum
        ))
    return TranscriptTidyChunker.chunks(of: text, limit: chunkLimit)
  }

  /// 预计要跑多久（秒）：⌈段数 ÷ 并发⌉ 波 × 每波约 50 秒。
  ///
  /// 为什么给这个（2026-10-01 体检）：界面原来写死「通常 1–5 分钟」，一小时的
  /// 听写稿切出 30 多段、要跑十来分钟，用户等到第 6 分钟就以为卡死了。每段 1200 字
  /// 实测 40–65 秒（见 maximumChunkCharacters），取 50 秒做中位估计；补跑不计入，
  /// 它只在出错时发生，算进去会让每次都报得偏长。
  public static func estimatedSeconds(forText text: String, style: TidyStyle = .transcript) -> Int {
    estimatedSeconds(chunkCount: chunks(for: text, style: style).count, secondsPerWave: 50)
  }

  public static func estimatedSeconds(
    chunkCount: Int,
    concurrency: Int = maximumConcurrentChunkRequests,
    secondsPerWave: Int = 50
  ) -> Int {
    guard chunkCount > 0 else { return 0 }
    let waves = (chunkCount + max(1, concurrency) - 1) / max(1, concurrency)
    return waves * secondsPerWave
  }

  public func tidy(
    text: String,
    model: String?,
    style: TidyStyle,
    context: TranscriptTidyContext,
    phase: (@Sendable (TranscriptTidyPhase) -> Void)?
  ) async throws -> TranscriptTidyOutcome {
    let chunks = Self.chunks(for: text, style: style)
    guard !chunks.isEmpty else { throw TranscriptTidyError.emptyTranscript }

    // 选了别家的模型就用那一家的地址和密钥（见 `loadCredentials(forModel:)`）。
    let credentials = try await Self.loadCredentials(from: configurationService, model: model)
    let trimmedOverride = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveModel = trimmedOverride?.isEmpty == false ? trimmedOverride! : credentials.profile.model

    // 分片并发执行，结果按分片序号还原——绝不能按完成顺序，那会把文稿打乱。
    // 单片失败不拖垮整体（该片保留原文），但取消必须立刻贯穿全部在飞请求。
    let runID = String(UUID().uuidString.prefix(8))
    let requestChunk: @Sendable (Int, Int) async throws -> TranscriptTidyOutcome = { [provider, credentials, effectiveModel, style, context] index, attempt in
      // 笔记不带上下文头：它本来就是自己写的，标题配文帮不上忙。
      // 听写稿和字幕稿都需要——专有名词全靠上下文才认得回来。
      let body = style.usesEditList ? TranscriptTidyEdits.numbered(chunks[index]) : chunks[index]
      let payload = style == .note
        ? body
        : TranscriptTidyPrompt.userMessage(chunk: body, context: context)
      let started = Date()
      let inputStamp = TranscriptTidyChunkCheck.timestamps(in: chunks[index]).first ?? "-"
      let head = "run=\(runID) model=\(effectiveModel) chunk=\(index + 1)/\(chunks.count) attempt=\(attempt) in=\(chunks[index].count) ts=\(inputStamp)"
      do {
        var outcome = try await provider.tidyTranscriptChunk(
          profile: credentials.profile,
          apiKey: credentials.apiKey,
          model: effectiveModel,
          text: payload,
          systemPrompt: style.requestPrompt
        )
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        // 清单模式：模型回的是修改清单，这里套进原文，后面的核对与拼接照旧按整段走。
        var editNote = ""
        if style.usesEditList {
          let edits = TranscriptTidyEdits.parse(outcome.text)
          let applied = TranscriptTidyEdits.apply(edits, to: chunks[index])
          editNote = "edits=\(edits.count) applied=\(applied.applied) missed=\(applied.missed) rawOut=\(outcome.text.count)"
          outcome = TranscriptTidyOutcome(
            text: applied.text,
            promptTokens: outcome.promptTokens,
            completionTokens: outcome.completionTokens,
            totalTokens: outcome.totalTokens,
            reasoningTokens: outcome.reasoningTokens,
            requestNote: outcome.requestNote
          )
        }
        // 听写稿和字幕稿逐段核对：回的不是这一段就当失败重试，绝不放进稿子。
        if style.normalizesParagraphs {
          let cleaned = TranscriptTidyChunkCheck.repairingLeadingStamp(
            output: TranscriptTidyNormalizer.normalize(
              TranscriptTidyPrompt.stripEchoedContext(outcome.text, chunk: chunks[index], context: context)
            ),
            for: chunks[index]
          )
          guard TranscriptTidyChunkCheck.belongs(output: cleaned, to: chunks[index]) else {
            let outStamp = TranscriptTidyChunkCheck.timestamps(in: cleaned).first ?? "-"
            Self.logDiagnostic("\(head) result=mismatch out=\(cleaned.count) outTs=\(outStamp) ms=\(elapsed)")
            throw TranscriptTidyChunkMismatch()
          }
        }
        // 思考占多少、每秒出多少 token：换模型时靠这两项比较快慢。
        let completion = outcome.completionTokens.map(String.init) ?? "-"
        let reasoning = outcome.reasoningTokens.map(String.init) ?? "-"
        let rate = outcome.completionTokens.map { elapsed > 0 ? String($0 * 1_000 / elapsed) : "-" } ?? "-"
        Self.logDiagnostic(
          "\(head) result=ok out=\(outcome.text.count) ms=\(elapsed) completionTok=\(completion) reasoningTok=\(reasoning) tokPerSec=\(rate) \(editNote) \(outcome.requestNote ?? "")"
        )
        return outcome
      } catch let error as TranscriptTidyChunkMismatch {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch where Task.isCancelled {
        // 取消时服务商那层可能把被掐断的请求报成「网络中断」。按失败记下就会
        // 被补跑——用户点了停止，后台却又发出新请求（2026-10-01 体检）。
        throw CancellationError()
      } catch {
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        let code = (error as? ModelProviderFailure)?.code.rawValue ?? String(describing: type(of: error))
        Self.logDiagnostic("\(head) result=error code=\(code) ms=\(elapsed)")
        throw error
      }
    }
    // 每段已经发过几次（0 = 只发过首发）。池内补跑与收尾补跑共用这个计数，
    // 一段最多发 1 + chunkRetryAttempts 次。
    var attemptsUsed: [Int: Int] = [:]
    var results = try await withThrowingTaskGroup(
      of: (Int, Result<TranscriptTidyOutcome, Error>).self
    ) { group -> [Int: Result<TranscriptTidyOutcome, Error>] in
      var collected: [Int: Result<TranscriptTidyOutcome, Error>] = [:]
      var succeeded = 0
      var next = 0
      // 池内补跑排在新段前面：先把掉了的段补上，进度不会卡在中间某段。
      var pendingRetries: [Int] = []
      // 段号由子任务自己带回（显式捕获成常量），不经嵌套函数的参数转一手：
      // 2026-09-28 正式版里第 7 段的结果被记到了第 1 段名下，调试版测试复现不出，
      // 只能按「这一处不可信」来写。收回来之后拼接前还会再按内容核一遍。
      func launch(_ requested: Int, attempt requestedAttempt: Int) {
        let chunkIndex = requested
        let attempt = requestedAttempt
        attemptsUsed[chunkIndex] = attempt
        group.addTask { [chunkIndex, attempt] in
          do {
            if attempt > 0 {
              try await Task.sleep(for: .seconds(Double(attempt) * Self.chunkRetryBaseDelaySeconds))
            }
            let outcome = try await requestChunk(chunkIndex, attempt)
            return (chunkIndex, .success(outcome))
          } catch is CancellationError {
            // 让取消走 TaskGroup 的抛出路径，而不是被计成“这片失败了”。
            throw TranscriptTidyError.cancelled
          } catch {
            if Task.isCancelled { throw TranscriptTidyError.cancelled }
            return (chunkIndex, .failure(error))
          }
        }
      }
      func launchNext() {
        if !pendingRetries.isEmpty {
          let index = pendingRetries.removeFirst()
          launch(index, attempt: (attemptsUsed[index] ?? 0) + 1)
        } else if next < chunks.count {
          launch(next, attempt: 0)
          next += 1
        }
      }
      while next < min(Self.maximumConcurrentChunkRequests, chunks.count) {
        launchNext()
      }
      do {
        while let finished = try await group.next() {
          let index = finished.0
          let result = finished.1
          if case .success = collected[index] {
            Self.logDiagnostic("run=\(runID) duplicate-result chunk=\(index + 1)/\(chunks.count)")
          }
          collected[index] = result
          if case .success = result { succeeded += 1 }
          // 失败段**在池里**补跑（2026-10-04）：原来等整轮跑完再一段一段串行补，
          // Day2 实测网关两次成批掐断请求、12 段失败，串行补跑一段约 60 秒，
          // 光收尾就多等了 13 分钟。网络中断、服务商抖动、回错段这类失败隔几秒
          // 重发就好，不必等；限流例外——留到收尾一次一个，不再和别的请求抢配额。
          if case let .failure(error) = result,
             Self.isRetryable(error), !Self.isRateLimited(error),
             (attemptsUsed[index] ?? 0) < Self.chunkRetryAttempts {
            pendingRetries.append(index)
          }
          // 每落地一片就报一次。分片是并发跑的，完成顺序不定，所以按**片数**报
          // 进度，而不是按 index——否则进度会来回跳。
          //
          // 只数**成功**的片（2026-10-01 体检）：原来失败片也算「已完成」，一波里
          // 有几段失败时界面照样走到「N/N」，接着补跑十几分钟一动不动。
          phase?(.tidying(succeeded: succeeded, total: chunks.count))
          // 取消后不再发新片：已在飞的会被 TaskGroup 一起取消。
          if Task.isCancelled { throw TranscriptTidyError.cancelled }
          launchNext()
        }
      } catch is CancellationError {
        throw TranscriptTidyError.cancelled
      }
      return collected
    }

    // 收尾补跑：池里补完仍失败、且还有次数的段（主要是限流），一次只发一个请求、
    // 先等几秒，不再和别的请求抢配额。Key 无效、没权限这类重试没用的错误不重试。
    //
    // 补跑时报「正在补跑第 k 段（共 m 段）」，并且每一步都先看是否已取消：用户点了
    // 停止就立刻抛出，不再发下一次补跑（2026-10-01 体检）。
    let retryIndices = chunks.indices.filter { index in
      guard case let .failure(error)? = results[index] else { return false }
      return Self.isRetryable(error) && (attemptsUsed[index] ?? 0) < Self.chunkRetryAttempts
    }
    var succeededCount = 0
    for result in results.values { if case .success = result { succeededCount += 1 } }
    for (position, index) in retryIndices.enumerated() {
      guard !Task.isCancelled else { throw TranscriptTidyError.cancelled }
      phase?(.retrying(attempt: position + 1, failed: retryIndices.count, total: chunks.count))
      for attempt in ((attemptsUsed[index] ?? 0) + 1)...Self.chunkRetryAttempts {
        do {
          try await Task.sleep(for: .seconds(Double(attempt) * Self.chunkRetryBaseDelaySeconds))
          results[index] = .success(try await requestChunk(index, attempt))
          succeededCount += 1
          break
        } catch is CancellationError {
          throw TranscriptTidyError.cancelled
        } catch {
          if Task.isCancelled { throw TranscriptTidyError.cancelled }
          results[index] = .failure(error)
          guard Self.isRetryable(error) else { break }
        }
      }
    }
    if !retryIndices.isEmpty {
      phase?(.tidying(succeeded: succeededCount, total: chunks.count))
    }
    if Task.isCancelled { throw TranscriptTidyError.cancelled }

    var outputs: [String] = []
    var failedChunkCount = 0
    var firstFailure: Error?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    for (index, chunk) in chunks.enumerated() {
      // 拼接前按内容再核一遍：这个位置上的校对稿必须是这一段的，否则当失败、保留原文。
      if case let .success(outcome)? = results[index], style.normalizesParagraphs {
        let cleaned = TranscriptTidyChunkCheck.repairingLeadingStamp(
          output: TranscriptTidyNormalizer.normalize(
            TranscriptTidyPrompt.stripEchoedContext(outcome.text, chunk: chunk, context: context)
          ),
          for: chunk
        )
        if !TranscriptTidyChunkCheck.belongs(output: cleaned, to: chunk) {
          let outStamp = TranscriptTidyChunkCheck.timestamps(in: cleaned).first ?? "-"
          Self.logDiagnostic("run=\(runID) misplaced chunk=\(index + 1)/\(chunks.count) outTs=\(outStamp)")
          results[index] = .failure(TranscriptTidyChunkMismatch())
        }
      }
      if results[index] == nil {
        Self.logDiagnostic("run=\(runID) missing chunk=\(index + 1)/\(chunks.count)")
      }
      switch results[index] {
      case let .success(outcome):
        // 归一化换行方言：Markdown 阅读区把单换行折叠成空格，
        // 不归一化就会出现“句号后一坨空格 + 整篇不分段”。
        //
        // 笔记不能走这一步：它的产物是 Markdown，换行本身有语义。归一化会把
        // 段内单换行拼回一行，`- a\n- b` 这样的列表会被拼成 `- a - b`。
        let cleaned: String = style.normalizesParagraphs
          ? TranscriptTidyChunkCheck.repairingLeadingStamp(
              output: TranscriptTidyNormalizer.normalize(
                TranscriptTidyPrompt.stripEchoedContext(
                  outcome.text, chunk: chunk, context: context
                )
              ),
              for: chunk
            )
          : outcome.text.replacingOccurrences(of: "\r\n", with: "\n")
              .trimmingCharacters(in: .whitespacesAndNewlines)
        outputs.append(cleaned.isEmpty ? chunk : cleaned)
        promptTokens = Self.summed(promptTokens, outcome.promptTokens)
        completionTokens = Self.summed(completionTokens, outcome.completionTokens)
        totalTokens = Self.summed(totalTokens, outcome.totalTokens)
      case let .failure(error):
        failedChunkCount += 1
        // 首个失败按分片序号取（并发下完成顺序不定，报错必须可复现）。
        if firstFailure == nil { firstFailure = error }
        outputs.append(chunk)
      case nil:
        // TaskGroup 正常收尾后每片必有结果；缺席只可能是实现错误。
        failedChunkCount += 1
        outputs.append(chunk)
      }
    }
    // Every chunk failing is a configuration/outage problem, not a partial
    // result; surface it instead of returning the input as a fake success.
    if failedChunkCount == chunks.count, let firstFailure {
      throw Self.mapped(firstFailure)
    }
    return TranscriptTidyOutcome(
      text: outputs.joined(separator: "\n\n"),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      failedChunkCount: failedChunkCount,
      chunkCount: chunks.count,
      failureReason: failedChunkCount > 0 ? (firstFailure.map(Self.failureReason) ?? "部分段没有返回结果") : nil
    )
  }

  /// 每段校对的结果记一行（只有段号、字数、时间戳、耗时和错误类别，不含正文），
  /// 出了「N 段失败」能直接查原因：`diagnostics/transcript-tidy.log`。nil 表示不记（测试）。
  nonisolated(unsafe) static var diagnosticsLogURL: URL? = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
    .appendingPathComponent("LinkDigest/diagnostics/transcript-tidy.log", isDirectory: false)
  private static let diagnosticsLock = NSLock()
  private static let diagnosticsMaximumBytes = 256 * 1_024

  static func logDiagnostic(_ line: String) {
    guard let url = diagnosticsLogURL else { return }
    diagnosticsLock.lock()
    defer { diagnosticsLock.unlock() }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let data = Data("\(stamp) \(line)\n".utf8)
    let manager = FileManager.default
    try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > diagnosticsMaximumBytes,
       let existing = try? Data(contentsOf: url) {
      // 超过上限只留后一半，日志不无限长大。
      try? existing.suffix(diagnosticsMaximumBytes / 2).write(to: url, options: .atomic)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  /// 失败段补跑的次数与间隔（第 n 次先等 n × 间隔秒）。
  public static let chunkRetryAttempts = 2
  nonisolated(unsafe) static var chunkRetryBaseDelaySeconds: Double = 3

  static func isRateLimited(_ error: Error) -> Bool {
    (error as? ModelProviderFailure)?.code == .rateLimited
  }

  static func isRetryable(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    guard let failure = error as? ModelProviderFailure else { return true }
    switch failure.code {
    case .authInvalid, .authForbidden, .baseURLInvalid, .endpointNotFound, .modelNotFound,
         .providerBillingLimited, .freeTierRestricted, .inputTooLarge:
      return false
    default:
      return true
    }
  }

  /// 给界面看的失败原因，只用错误类别，不带服务商原文。
  static func failureReason(_ error: Error) -> String {
    if error is TranscriptTidyChunkMismatch { return "模型返回的内容和这一段对不上" }
    guard let failure = error as? ModelProviderFailure else { return "请求出错" }
    switch failure.code {
    case .rateLimited: return "服务繁忙被限流"
    case .networkInterrupted: return "网络中断或请求超时"
    case .providerUnavailable: return "服务商暂时不可用"
    case .inputTooLarge: return "这一段超出了模型的长度限制"
    case .providerBillingLimited: return "账户余额不足"
    case .authInvalid, .authForbidden: return "密钥无效或没有权限"
    case .streamMalformed, .protocolIncompatible: return "模型返回的格式异常"
    default: return "服务商拒绝了请求"
    }
  }

  /// nil 表示服务商没报用量；只要有一片报了就累计，不把 nil 当 0。
  private static func summed(_ left: Int?, _ right: Int?) -> Int? {
    switch (left, right) {
    case (nil, nil): return nil
    case let (value?, nil), let (nil, value?): return value
    case let (lhs?, rhs?): return lhs + rhs
    }
  }

  private static func mapped(_ error: Error) -> TranscriptTidyError {
    guard let failure = error as? ModelProviderFailure else { return .responseRejected }
    switch failure.code {
    case .authInvalid: return .authInvalid
    case .networkInterrupted: return .networkInterrupted
    default: return .responseRejected
    }
  }
}

/// 模型回的不是这一段的校对稿（时间戳或字数对不上）。
struct TranscriptTidyChunkMismatch: Error {}
