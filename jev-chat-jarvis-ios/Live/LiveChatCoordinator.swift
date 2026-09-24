import UIKit
import VisynCapture

/// 协调四条独立业务：屏幕识别、长图存档、Jev 判断、回复候选。
/// 图片存档使用独立单槽队列，不作为文本分析或键盘发布的前置条件。
@MainActor
final class LiveChatCoordinator {
    static let shared = LiveChatCoordinator()

    /// 画中画固定标记由引擎结合几何区域排除；聊天里提到 Jarvis 的消息仍应保留。
    static let overlayMarkers = ["Jarvis"]

    let scheduler = LiveAnalysisScheduler()
    let replyScheduler = ReplySuggestionScheduler()
    private let engine = ChatSessionEngine()
    private let longScreenshots = LongScreenshotStore()

    private(set) var latest: EngineUpdate?
    private(set) var captureState: VisynBroadcastState = .stopped
    private(set) var framesReceived = 0
    private(set) var framesDropped = 0
    private(set) var currentContext: ConversationContext?
    private(set) var longScreenshotSummary: [UUID: LongScreenshotSummary] = [:]
    private(set) var isSavingLongScreenshot = false

    private var processing = false
    private var pending: VisynCapturedFrame?
    private var currentSession: UUID?
    private var captureGeneration = 0
    private var screenshotEpoch = UUID()
    private var pendingScreenshot: LongScreenshotInput?
    private var pendingScreenshotMerges: [LongScreenshotMerge] = []
    private var screenshotResetTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]
    private var presentationTimer: Timer?

    /// 正在分析的数据与最后完成的展示分开，滚动/新消息不会先清空 PiP。
    private struct CompletedPresentation {
        let outcome: LiveAnalysisScheduler.Outcome
        let sourceTitle: String
    }
    private var completedPresentation: CompletedPresentation?

    private let pipView = JarvisPiPView()
    private let publisher = ReplyBundlePublisher()

    private init() {
        scheduler.onRequest = { [weak self] request in self?.replyScheduler.start(request) }
        scheduler.onInvalidate = { [weak self] in self?.replyScheduler.invalidate() }
        scheduler.onChange = { [weak self] in self?.notify() }
        replyScheduler.onChange = { [weak self] in self?.notify() }
        applyLadderCapacity()
        NotificationCenter.default.addObserver(
            forName: JarvisConfig.liveSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLadderCapacity() }
        }
    }

    private func applyLadderCapacity() {
        let capacity = JarvisConfig.shared.ladderCapacity
        let store = longScreenshots
        Task { await store.setCapacity(capacity) }
    }

    // MARK: - 采集输入

    func captureStateChanged(_ state: VisynBroadcastState) {
        let previousState = captureState
        captureState = state
        switch state {
        case .broadcasting:
            if previousState == .paused {
                // 暂停期间的结论不能在恢复首帧被静默复用；重新走稳定/分析流程。
                scheduler.reset()
            }
            if presentationTimer == nil {
                // 即使没有新帧也更新过期提示；发布器只允许新 frameID 延长来源有效期。
                presentationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.notify() }
                }
            }
        case .paused:
            captureGeneration += 1
            pending = nil
            currentContext = nil
            scheduler.captureStopped()
            presentationTimer?.invalidate()
            presentationTimer = nil
        case .stopped:
            captureGeneration += 1
            presentationTimer?.invalidate()
            presentationTimer = nil
            pending = nil
            currentSession = nil
            currentContext = nil
            framesReceived = 0
            framesDropped = 0
            scheduler.captureStopped()
        }
        notify()
    }

    func receive(_ frame: VisynCapturedFrame) {
        guard captureState == .broadcasting else { return }
        if frame.sessionID != currentSession {
            captureGeneration += 1
            // 新的一次录屏重新识别；PiP 仅保留带来源的上次结果供查看。
            currentSession = frame.sessionID
            latest = nil
            currentContext = nil
            resetLongScreenshots()
            scheduler.reset()
        }
        framesReceived += 1
        if pending != nil { framesDropped += 1 }
        pending = frame
        pump()
    }

    /// 用户主动清空当前识别结果（内存中的会话文字和长截图）。
    func clear() {
        captureGeneration += 1
        pending = nil
        latest = nil
        currentContext = nil
        completedPresentation = nil
        resetLongScreenshots()
        scheduler.reset()
        Task { await engine.clear() }
        notify()
    }

    private func pump() {
        guard captureState == .broadcasting, !processing, let frame = pending else { return }
        pending = nil
        processing = true
        let engine = engine
        let generation = captureGeneration
        let epoch = screenshotEpoch
        Task { [weak self] in
            let output = await engine.process(
                jpeg: frame.jpegData, frameID: frame.id, sessionID: frame.sessionID,
                capturedAt: frame.capturedAt, overlayMarkers: Self.overlayMarkers, epoch: epoch
            )
            guard let self else { return }
            self.processing = false
            if let output, self.captureState == .broadcasting,
               generation == self.captureGeneration, output.update.sessionID == self.currentSession {
                let update = output.update
                self.latest = update
                self.currentContext = self.makeContext(from: update, observedAt: frame.capturedAt)
                self.scheduler.update(self.currentContext)
                self.notify()
            }
            // 旧采集 generation 不得启动模型，但同 epoch 的已识别图片和合并事件必须存完。
            // 只有清空或新一次录屏更换 epoch，才丢弃这份图片输出。
            if self.screenshotEpoch == epoch, let input = output?.longScreenshot {
                self.pendingScreenshotMerges.append(contentsOf: input.placement.merged.map {
                    LongScreenshotMerge(conversationID: input.conversationID, sourceID: $0.id,
                                        targetID: input.placement.segmentID, shift: $0.shift)
                })
                self.pendingScreenshot = input
                self.pumpLongScreenshot()
            }
            self.pump()
        }
    }

    private func makeContext(from update: EngineUpdate, observedAt: Date) -> ConversationContext? {
        guard update.detection == .chat, let conversationID = update.conversationID else { return nil }
        let messages = update.contextMessages.filter { $0.kind == .message || $0.kind == .gap }.map { message in
            let speaker: Speaker
            switch message.side {
            case .me: speaker = .me
            case .other: speaker = .other
            case .unknown: speaker = .unknown
            }
            let text: String
            if message.kind == .gap {
                text = "【聊天记录缺口：中间有未采集的消息，不要将前后两段视为连续对话】"
            } else {
                text = message.text + (message.quote.map { "（引用：\($0)）" } ?? "")
                    + (message.clipped ? "（此条仅部分可见，请勿推测缺失文字）" : "")
            }
            return ContextMessage(id: message.id, speaker: speaker, text: text, isGap: message.kind == .gap)
        }
        return ConversationContext(sessionID: update.sessionID, conversationID: conversationID,
                                   revision: update.revision, sourceTitle: update.title ?? "当前会话",
                                   sourceConfirmed: update.confirmed, frameID: update.frameID,
                                   observedAt: observedAt, messages: messages)
    }

    private func resetLongScreenshots() {
        screenshotEpoch = UUID()
        pendingScreenshot = nil
        pendingScreenshotMerges = []
        longScreenshotSummary = [:]
        let store = longScreenshots, epoch = screenshotEpoch
        let previousReset = screenshotResetTask
        screenshotResetTask = Task {
            await previousReset?.value
            await store.reset(to: epoch)
        }
    }

    private func pumpLongScreenshot() {
        guard !isSavingLongScreenshot, let input = pendingScreenshot else { return }
        pendingScreenshot = nil
        isSavingLongScreenshot = true
        let epoch = screenshotEpoch
        let merges = pendingScreenshotMerges
        pendingScreenshotMerges = []
        let store = longScreenshots, reset = screenshotResetTask
        Task { [weak self] in
            await reset?.value
            guard let self else { return }
            // 停录/暂停只停止新采集；已识别图片和不可丢的合并事件允许完成。
            // 清空或新录屏会换 epoch，旧存档结果不得回写新会话。
            if self.screenshotEpoch == epoch {
                await store.ingest(input, merges: merges)
                let summary = await store.summary()
                if self.screenshotEpoch == epoch {
                    self.longScreenshotSummary = summary
                }
            }
            self.isSavingLongScreenshot = false
            self.notify()
            self.pumpLongScreenshot()
        }
    }

    // MARK: - 输出

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func renderLongScreenshot(maxPixelHeight: Int = 16_000) async -> UIImage? {
        let epoch = screenshotEpoch
        await screenshotResetTask?.value
        guard epoch == screenshotEpoch,
              let data = await longScreenshots.render(maxPixelHeight: maxPixelHeight),
              epoch == screenshotEpoch else { return nil }
        return UIImage(data: data)
    }

    /// 画中画内容视图。Visyn 每 0.5 秒重新光栅化一次，改文字即可刷新。
    func makePiPContent() -> UIView { pipView }

    /// 一行状态，用于首页和画中画。
    var statusLine: String {
        switch captureState {
        case .stopped: return "未在录屏"
        case .paused: return "录屏已暂停"
        case .broadcasting: break
        }
        guard let latest else { return "等待屏幕画面…" }
        switch latest.detection {
        case .waiting: return "等待屏幕画面…"
        case .notChat(let reason):
            return "未检测到聊天页 · \(reason)"
        case .chat:
            let who = latest.title.map { "「\($0)」" } ?? "聊天页"
            let count = latest.liveMessages.filter { $0.kind == .message }.count
            let gap = latest.segments.count > 1 ? " · \(latest.segments.count) 段" : ""
            return "已识别\(who) · 当前屏 \(latest.currentMessages.count) 条 · 上下文 \(count) 条\(gap)"
        }
    }

    var analysisLine: String {
        switch scheduler.phase {
        case .idle: return latest?.detection == .chat ? "等待对方新消息" : ""
        case .waitingContent: return "本屏尚未识别到可读聊天文字"
        case .debouncing: return "聊天内容有更新，准备分析…"
        case .analyzing: return scheduler.isRefreshingContext ? "正在补充上下文分析…" : "正在分析…"
        case .ready:
            if scheduler.outcome?.stale == true { return "会话有更新，结论可能已过时" }
            return "Jev 判断已完成 · \(replyLine)"
        case .failed(let reason): return reason
        case .skipped(let reason): return reason
        }
    }

    var replyLine: String {
        switch replyScheduler.phase {
        case .idle: return "等待回复任务"
        case .generating: return "正在生成候选文案"
        case .ranking: return "正在排序候选文案"
        case .ready: return publisher.isReady ? "三条候选已就绪" : publisher.unavailableReason
        case .failed(let reason): return reason
        }
    }

    private func notify() {
        if captureState == .broadcasting, scheduler.phase == .ready,
           let outcome = scheduler.outcome, !outcome.stale,
           let context = currentContext,
           outcome.request.version.sessionID == context.sessionID,
           outcome.conversationID == context.conversationID,
           outcome.signature == context.tailSignature,
           completedPresentation?.outcome.requestID != outcome.requestID {
            completedPresentation = CompletedPresentation(outcome: outcome, sourceTitle: outcome.request.context.sourceTitle)
        }
        publisher.refresh(
            context: currentContext, currentRequest: scheduler.currentRequest,
            judge: scheduler.outcome, replies: replyScheduler.outcome,
            replyPhase: replyScheduler.phase, capturing: captureState == .broadcasting,
            captureNote: captureState == .paused ? "录屏已暂停" : "录屏已停止"
        )
        updatePiP()
        for handler in observers.values { handler() }
    }

    /// 候选已写给键盘、键盘可以插入。
    var keyboardReady: Bool { publisher.isReady }

    /// Jev 完成即可替换判断，回复候选和长图进度独立展示。
    private func updatePiP() {
        let displayed = completedPresentation
        let outcome = displayed?.outcome
        let analysis = outcome?.analysis
        let matchesCurrent = outcome != nil && outcome?.conversationID == currentContext?.conversationID
            && outcome?.request.version.sessionID == currentContext?.sessionID
            && outcome?.signature == currentContext?.tailSignature
        let currentResult = matchesCurrent && scheduler.phase == .ready
            && outcome?.requestID == scheduler.outcome?.requestID && scheduler.outcome?.stale == false
        let source = displayed?.sourceTitle ?? latest?.title ?? "当前会话"
        let count = outcome?.analyzedCount ?? latest?.liveMessages.filter { $0.kind == .message }.count ?? 0
        var status = "Jarvis · \(source.prefix(8))"
        if displayed != nil && !currentResult { status += " · 上次结果" }
        var tone: JarvisPiPView.Tone = .neutral
        if let danger = analysis?.dangerLevel {
            let level = max(0, min(danger.maxLevel, Int(danger.score.rounded())))
            status += " · \(JudgeLabels.emotion(level: level, maxLevel: danger.maxLevel)) \(level)/\(danger.maxLevel)"
            let scaled = Double(level) * 9 / Double(max(danger.maxLevel, 1))
            tone = scaled >= 6 ? .danger : (scaled >= 3 ? .warn : .calm)
        }
        status += " · \(count) 条"
        let judge: String
        if let analysis {
            judge = "Jarvis 意图：\(JudgeLabels.intentSummary(analysis))"
        } else if let error = outcome?.judgeError {
            judge = "Jarvis 判断失败：\(error)"
        } else {
            judge = "Jarvis 识别到一屏聊天即可分析，无需凑满条数"
        }
        let advice = analysis.map { "Jarvis 建议：\(JudgeLabels.advice($0))" }
            ?? "Jarvis 分析完成后显示需求、行动与情绪信息"
        var prompt = false
        let progress: String
        if captureState != .broadcasting {
            progress = "Jarvis \(statusLine)" + (displayed == nil ? "" : " · 保留上次结果")
        } else if latest?.detection != .chat {
            progress = "Jarvis 等待聊天画面 · 已暂停分析与候选插入"
        } else if scheduler.phase == .analyzing || scheduler.phase == .debouncing {
            progress = publisher.isReady ? "Jarvis 候选已就绪 · Jev 判断仍在分析中…"
                : "Jarvis Jev 分析中 · \(replyLine)"
        } else if case .failed(let reason) = scheduler.phase {
            progress = publisher.isReady ? "Jarvis Jev 判断失败 · 候选可在键盘选用" : "Jarvis 判断：\(reason) · \(replyLine)"
        } else if case .skipped(let reason) = scheduler.phase {
            progress = "Jarvis \(reason)"
        } else if currentResult {
            let candidates = publisher.isReady ? "候选已就绪 · " : ""
            if latest?.currentContextIsIsolated == true {
                progress = publisher.isReady ? "Jarvis 已单屏分析 · 候选已就绪，历史尚未接上"
                    : "Jarvis 已单屏分析 · \(publisher.unavailableReason)"
                prompt = true
            } else {
                switch scheduler.contextNeed {
                case .history:
                    progress = "Jarvis \(candidates)可上滑补充历史；键盘选回复"
                    prompt = true
                case .short(let have, let want):
                    progress = "Jarvis \(candidates)已分析 \(have) 条，可上滑补至 \(want) 条"
                    prompt = true
                case .none:
                    progress = publisher.isReady ? "Jarvis 三条候选已就绪 · 切键盘确认会话后插入"
                        : "Jarvis \(publisher.unavailableReason)"
                }
            }
        } else {
            progress = "Jarvis \(analysisLine.isEmpty ? "等待可分析的聊天内容" : analysisLine)"
        }
        pipView.show(status: status, judge: judge, advice: advice, action: progress, tone: tone, prompt: prompt)
    }
}
