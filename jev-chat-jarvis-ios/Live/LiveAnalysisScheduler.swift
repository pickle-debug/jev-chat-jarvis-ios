import Foundation

/// 实时语义分析的调度：什么时候调 Jev，什么时候不调。
///
/// 逐条对应安卓 `ChatCaptureService.maybeCapture / runAnalysis / finishOcrSnapshot` 的查询时机：
///
/// | 安卓 | iOS |
/// |---|---|
/// | `snapshot.signature()`：最近 6 条 `side:text` | `signature(of:)`，同样取最近 6 条 |
/// | 签名没变且气泡在 → 什么都不做 | 签名等于 `handledSignature` → 不重复计费 |
/// | 签名变化 → `resetForNewConversation` 清掉旧结论 | 旧结论标记 `stale`，取消在途请求 |
/// | 仅 `latestFrom == "other"` 且开启自动分析才触发 | 同上；另要求会话已确认 |
/// | `postDelayed(debounce, 800)` 合并内容事件 | 800ms 防抖，外加最新一条至少被 2 帧看到（OCR 稳定） |
/// | `analyzing` 期间丢弃新触发 | 新签名直接取消旧请求：旧会话的结论比多花一次调用更危险 |
/// | Judge 与 Reply+Rank 并行，判断先出 | 同上，按 conversationID + requestID 校验后才落地 |
/// | 手动点“分析”总是重新跑 | `analyzeNow()` 忽略签名和发言方 |
///
/// 分析的对象是“稳定长图里最新的聊天记录”：实时段尾部的消息（不含时间分隔线）。
/// 用户从下往上翻历史只会在长图顶部补旧消息，尾部签名不变，不会误触发；
/// 只有尾部真的出现新气泡（对方发来新消息）才会重新评估。
///
/// 额外的刹车：每分钟最多 6 次自动分析，防止 OCR 抖动变成持续计费。
@MainActor
final class LiveAnalysisScheduler {
    enum Phase: Equatable {
        case idle
        case waitingStable
        case debouncing
        case analyzing
        case ready
        case failed(String)
        /// 条件不满足，不自动分析；附原因用于展示。
        case skipped(String)
    }

    /// 这一次判断是否需要更多上下文。画中画据此提示用户上滑聊天记录。
    enum ContextNeed: Equatable {
        case none
        /// 分析时实时段里的消息少于设置的上下文条数。
        case short(have: Int, want: Int)
        /// Jev 判断需要先查历史（对方在考你是否记得某件事）。
        case history
    }

    struct Outcome {
        let conversationID: UUID
        let revision: Int
        let signature: String
        let requestID: UUID
        let startedAt: Date
        var analysis: Analysis?
        var judgeError: String?
        var replies: [RankedReply]?
        var repliesUnranked = false
        var replyError: String?
        /// 会话在分析之后又有新内容。
        var stale = false
        /// 本次分析实际发给模型的消息条数，以及其中最早一条的 ID（用来判断用户是否上滑补了更早的记录）。
        var analyzedCount = 0
        var analyzedFirstID: UUID?
        /// 这是用户上滑补充上下文后的重新分析。
        var isContextRefresh = false
    }

    static let debounce: Duration = .milliseconds(800)
    static let signatureDepth = 6
    static let autoRunsPerMinute = 6
    /// 用户停止上滑多久后，用补充的上下文重新分析。
    static let contextSettle: Duration = .milliseconds(1500)
    /// 同一条最新消息最多因为补充上下文重新分析几次，防止“一直要求查历史”变成持续计费。
    static let maxContextRefreshes = 2
    /// 需要查历史时，一次最多带多少条消息。
    static let historyContextLimit = 50

    private let config: JarvisConfig
    private let judgeClient: JudgeClient
    private let replyClient: ReplyClient

    private(set) var phase: Phase = .idle
    private(set) var outcome: Outcome?
    var onChange: (() -> Void)?

    private var conversationID: UUID?
    private var latest: EngineUpdate?
    private var handledSignature: String?
    private var debounceTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var currentRequestID: UUID?
    private var autoRunTimes: [Date] = []
    private var contextTask: Task<Void, Never>?
    private var contextRefreshes = 0
    private var pendingOlder = 0

    init() {
        let config = JarvisConfig.shared
        self.config = config
        self.judgeClient = JudgeClient(config: config)
        self.replyClient = ReplyClient(config: config)
    }

    var autoAnalyze: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoKey)
            // 重新打开时让当前内容有机会被评估一次。
            if newValue { handledSignature = nil; latest.map(update) }
        }
    }

    private static let autoKey = "jarvis.live.autoAnalyze"

    // MARK: - 输入

    func update(_ engine: EngineUpdate) {
        latest = engine
        guard engine.detection == .chat, let id = engine.conversationID else { return }

        if id != conversationID {
            // 换了会话：旧请求、旧结论全部作废。
            cancelAll()
            conversationID = id
            outcome = nil
            handledSignature = nil
            setPhase(.idle)
        }

        let messages = engine.liveMessages.filter { $0.kind == .message }
        guard let newest = messages.last else { return }
        let signature = Self.signature(of: messages)
        if signature == handledSignature {
            considerContextRefresh(engine)
            return
        }
        contextRefreshes = 0

        if var current = outcome, current.signature != signature, !current.stale {
            current.stale = true
            outcome = current
            onChange?()
        }

        // 下面这些条件不满足时先不记为已处理，内容稳定或回到底部后还会再评估。
        guard engine.confirmed else { return setPhase(.waitingStable) }
        let requiredObservations = newest.clipped ? 4 : 2
        guard newest.observations >= requiredObservations else {
            debounceTask?.cancel()
            return setPhase(.waitingStable)
        }

        // 以下是“这个签名已经评估过”的终态，不再重复评估。
        handledSignature = signature
        guard autoAnalyze else { return setPhase(.skipped("自动分析已关闭，可手动分析")) }
        guard newest.side == .other, newest.sideConfidence >= 0.6 else {
            let reason = newest.side == .me ? "最新一条是我发的，等待对方回复" : "最新一条无法判断发言人，可手动分析"
            return setPhase(.skipped(reason))
        }
        guard config.isConfigured(.judge) else { return setPhase(.failed("未配置判断接口，去 BYOK 设置里填写")) }
        let now = Date()
        autoRunTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard autoRunTimes.count < Self.autoRunsPerMinute else {
            return setPhase(.skipped("自动分析过于频繁，已暂停一分钟内的新请求"))
        }

        cancelAll()
        setPhase(.debouncing)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            // 防抖期间内容又变了，交给下一次 update 处理。
            guard let latest = self.latest, Self.signature(of: latest.liveMessages) == signature else { return }
            self.autoRunTimes.append(Date())
            self.run(latest, signature: signature, limit: self.config.contextMessageCount)
        }
    }

    /// 手动分析：不看签名、不看发言方，但仍要求有内容和判断接口。
    func analyzeNow() {
        guard let latest, latest.conversationID != nil, latest.liveMessages.contains(where: { $0.kind == .message }) else {
            return setPhase(.failed("还没有可分析的聊天内容"))
        }
        guard config.isConfigured(.judge) else { return setPhase(.failed("未配置判断接口，去 BYOK 设置里填写")) }
        let signature = Self.signature(of: latest.liveMessages)
        handledSignature = signature
        cancelAll()
        let limit = outcome?.analysis?.bestAction?.choice == "check_history"
            ? Self.historyContextLimit : config.contextMessageCount
        run(latest, signature: signature, limit: limit)
    }

    /// 当前结论是否需要更多上下文。
    var contextNeed: ContextNeed {
        guard let outcome, !outcome.stale, phase == .ready || phase == .analyzing else { return .none }
        if outcome.analysis?.bestAction?.choice == "check_history", contextRefreshes < Self.maxContextRefreshes {
            return .history
        }
        let want = config.contextMessageCount
        if outcome.analyzedCount > 0, outcome.analyzedCount < want, contextRefreshes < Self.maxContextRefreshes {
            return .short(have: outcome.analyzedCount, want: want)
        }
        return .none
    }

    /// 用户按提示上滑、长图顶部补进了更早的消息：停下来 1.5 秒后，用补充的上下文重新分析同一条最新消息。
    private func considerContextRefresh(_ engine: EngineUpdate) {
        guard phase == .ready, let current = outcome, !current.stale,
              let firstID = current.analyzedFirstID else { return }
        let need = contextNeed
        guard need != .none else { return }
        let messages = engine.liveMessages.filter { $0.kind == .message }
        guard let firstIndex = messages.firstIndex(where: { $0.id == firstID }) else { return }
        let older = firstIndex
        let enough: Bool
        switch need {
        case .none: enough = false
        case .short(let have, let want): enough = have + older >= want
        case .history: enough = older >= 3
        }
        guard older > 0, older != pendingOlder || contextTask == nil else { return }
        pendingOlder = older
        contextTask?.cancel()
        contextTask = Task { [weak self] in
            try? await Task.sleep(for: Self.contextSettle)
            guard !Task.isCancelled, let self, let latest = self.latest,
                  latest.conversationID == current.conversationID,
                  Self.signature(of: latest.liveMessages) == current.signature else { return }
            let nowOlder = latest.liveMessages.filter { $0.kind == .message }.firstIndex { $0.id == firstID } ?? 0
            // 仍在继续上滑就再等；够了或者停住了都用现有内容重新分析。
            guard nowOlder == older || enough else { return }
            self.contextTask = nil
            self.pendingOlder = 0
            self.contextRefreshes += 1
            let limit = need == .history
                ? Self.historyContextLimit : self.config.contextMessageCount
            self.run(latest, signature: current.signature, limit: limit, contextRefresh: true)
        }
    }

    func reset() {
        cancelAll()
        contextRefreshes = 0
        conversationID = nil
        latest = nil
        outcome = nil
        handledSignature = nil
        setPhase(.idle)
    }

    /// 停止采集：在途请求取消，已有结论标记过期（不能再当作实时）。
    func captureStopped() {
        cancelAll()
        if var current = outcome { current.stale = true; outcome = current }
        setPhase(.idle)
    }

    // MARK: - 执行

    private func run(_ engine: EngineUpdate, signature: String, limit: Int, contextRefresh: Bool = false) {
        guard let conversationID = engine.conversationID else { return }
        analysisTask?.cancel()
        let requestID = UUID()
        currentRequestID = requestID
        var snapshot = Self.snapshot(from: engine.liveMessages)
        snapshot.contextLimit = limit
        let sent = engine.liveMessages.filter { $0.kind == .message }.suffix(max(1, limit))
        var next = Outcome(
            conversationID: conversationID, revision: engine.revision, signature: signature,
            requestID: requestID, startedAt: Date()
        )
        next.analyzedCount = sent.count
        next.analyzedFirstID = sent.first?.id
        next.isContextRefresh = contextRefresh
        outcome = next
        setPhase(.analyzing)
        let relationship = config.relationship

        analysisTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.runJudge(snapshot, relationship: relationship, requestID: requestID) }
                group.addTask { await self.runReplies(snapshot, relationship: relationship, requestID: requestID) }
            }
            guard self.currentRequestID == requestID, let result = self.outcome else { return }
            if result.analysis == nil && result.replies == nil {
                self.setPhase(.failed(result.judgeError ?? result.replyError ?? "分析失败"))
            } else {
                self.setPhase(.ready)
            }
        }
    }

    private func runJudge(_ snapshot: ChatSnapshot, relationship: String, requestID: UUID) async {
        do {
            let analysis = try await judgeClient.judge(snapshot: snapshot, relationship: relationship)
            commit(requestID) { $0.analysis = analysis }
        } catch is CancellationError {
        } catch {
            commit(requestID) { $0.judgeError = error.localizedDescription }
        }
    }

    private func runReplies(_ snapshot: ChatSnapshot, relationship: String, requestID: UUID) async {
        guard config.isConfigured(.reply) else {
            return commit(requestID) { $0.replyError = "未配置回复接口，只显示判断结果" }
        }
        let candidates: [String]
        do {
            candidates = try await replyClient.draft(snapshot: snapshot, relationship: relationship)
        } catch is CancellationError {
            return
        } catch {
            return commit(requestID) { $0.replyError = error.localizedDescription }
        }
        guard !Task.isCancelled else { return }
        do {
            let ranked = try await judgeClient.rank(snapshot: snapshot, relationship: relationship, candidates: candidates)
            commit(requestID) { $0.replies = ranked }
        } catch is CancellationError {
        } catch {
            // 排序失败：保留生成顺序展示“未排序”，不冒充已排序结果。
            commit(requestID) {
                $0.replies = candidates.map { RankedReply(text: $0, probability: 0) }
                $0.repliesUnranked = true
                $0.replyError = "排序失败：\(error.localizedDescription)"
            }
        }
    }

    /// 结果只写回仍然是当前请求的 outcome，旧请求即使没及时取消也不会覆盖新会话。
    private func commit(_ requestID: UUID, _ change: (inout Outcome) -> Void) {
        guard currentRequestID == requestID, var current = outcome, current.requestID == requestID,
              current.conversationID == conversationID else { return }
        change(&current)
        outcome = current
        onChange?()
    }

    private func cancelAll() {
        debounceTask?.cancel()
        debounceTask = nil
        contextTask?.cancel()
        contextTask = nil
        pendingOlder = 0
        analysisTask?.cancel()
        analysisTask = nil
        currentRequestID = nil
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        onChange?()
    }

    // MARK: - 转换

    static func signature(of messages: [LiveMessage]) -> String {
        messages.filter { $0.kind == .message }.suffix(signatureDepth)
            .map { "\($0.side.rawValue):\(TextMatch.normalize($0.text))" }
            .joined(separator: "|")
    }

    static func snapshot(from messages: [LiveMessage]) -> ChatSnapshot {
        ChatSnapshot(messages: messages.filter { $0.kind == .message }.map { message in
            let speaker: Speaker
            switch message.side {
            case .me: speaker = .me
            case .other: speaker = .other
            case .unknown: speaker = .unknown
            }
            // 引用回复对理解语气很关键（“没有呀”是在回应哪句话），附在正文后面。
            let text = message.quote.map { "\(message.text)（引用：\($0)）" } ?? message.text
            return ChatMessage(speaker: speaker, text: text)
        })
    }
}
