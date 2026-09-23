import UIKit
import VisynCapture

/// 实时会话协调器：Visyn 帧 → 引擎（OCR + 拼接） → 调度器（Jev 查询时机） → 界面与画中画。
///
/// `onFrame` 在主线程回调；这里只做背压（最多保留一帧待处理，新帧覆盖旧帧），
/// 解码、OCR、版式和拼接都在 `ChatSessionEngine` 里跑。
@MainActor
final class LiveChatCoordinator {
    static let shared = LiveChatCoordinator()

    /// 画中画里每行文字都以 “Jarvis” 开头，引擎只剔除以它开头的 OCR 行，
    /// 不做全局文字过滤——用户把推荐回复发出去后，同样的文字会成为真正的聊天气泡。
    static let overlayMarkers = ["Jarvis"]

    let scheduler = LiveAnalysisScheduler()
    private let engine = ChatSessionEngine()

    private(set) var latest: EngineUpdate?
    private(set) var captureState: VisynBroadcastState = .stopped
    private(set) var framesReceived = 0
    private(set) var framesDropped = 0

    private var processing = false
    private var pending: VisynCapturedFrame?
    private var currentSession: UUID?
    private var observers: [UUID: () -> Void] = [:]

    private let pipStatusLabel = UILabel()
    private let pipDetailLabel = UILabel()
    private lazy var pipView: UIView = makePiPView()

    private init() {
        scheduler.onChange = { [weak self] in self?.notify() }
        applyLadderCapacity()
        NotificationCenter.default.addObserver(
            forName: JarvisConfig.liveSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLadderCapacity() }
        }
    }

    private func applyLadderCapacity() {
        let capacity = JarvisConfig.shared.ladderCapacity
        let engine = engine
        Task { await engine.setLadderCapacity(capacity) }
    }

    // MARK: - 采集输入

    func captureStateChanged(_ state: VisynBroadcastState) {
        captureState = state
        switch state {
        case .broadcasting:
            break
        case .paused:
            pending = nil
        case .stopped:
            pending = nil
            currentSession = nil
            framesReceived = 0
            framesDropped = 0
            scheduler.captureStopped()
        }
        notify()
    }

    func receive(_ frame: VisynCapturedFrame) {
        if frame.sessionID != currentSession {
            // 新的一次录屏：上一轮的会话、长图和结论都不再沿用。
            currentSession = frame.sessionID
            latest = nil
            scheduler.reset()
        }
        framesReceived += 1
        if pending != nil { framesDropped += 1 }
        pending = frame
        pump()
    }

    /// 用户主动清空当前识别结果（内存中的会话文字和长截图）。
    func clear() {
        pending = nil
        latest = nil
        scheduler.reset()
        Task { await engine.clear() }
        notify()
    }

    private func pump() {
        guard !processing, let frame = pending else { return }
        pending = nil
        processing = true
        let engine = engine
        Task { [weak self] in
            let update = await engine.process(
                jpeg: frame.jpegData, frameID: frame.id, sessionID: frame.sessionID,
                capturedAt: frame.capturedAt, overlayMarkers: Self.overlayMarkers
            )
            guard let self else { return }
            self.processing = false
            if let update, update.sessionID == self.currentSession {
                self.latest = update
                self.scheduler.update(update)
                self.notify()
            }
            self.pump()
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
        guard let data = await engine.renderLongScreenshot(segmentID: nil, maxPixelHeight: maxPixelHeight) else { return nil }
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
            let rungs = latest.segments.first(where: \.isLive)?.rungCount ?? 0
            let gap = latest.segments.count > 1 ? " · \(latest.segments.count) 段" : ""
            return "已检测到\(who) · \(count) 条消息 · 长图 \(rungs) 张\(gap)"
        }
    }

    var analysisLine: String {
        switch scheduler.phase {
        case .idle: return latest?.detection == .chat ? "等待对方新消息" : ""
        case .waitingStable: return "等待画面稳定…"
        case .debouncing: return "对方有新消息，准备分析…"
        case .analyzing: return "正在分析…"
        case .ready:
            return scheduler.outcome?.stale == true ? "会话有更新，结论可能已过时" : "分析完成"
        case .failed(let reason): return reason
        case .skipped(let reason): return reason
        }
    }

    private func notify() {
        updatePiP()
        for handler in observers.values { handler() }
    }

    private func updatePiP() {
        pipStatusLabel.text = "Jarvis · \(statusLine)"
        if let outcome = scheduler.outcome, !outcome.stale, let best = outcome.replies?.first {
            pipDetailLabel.text = "Jarvis 推荐：\(best.text)"
        } else if let action = scheduler.outcome?.analysis?.bestAction, scheduler.outcome?.stale == false {
            pipDetailLabel.text = "Jarvis 建议：\(action.choice)"
        } else {
            let line = analysisLine
            pipDetailLabel.text = "Jarvis \(line.isEmpty ? "待命" : line)"
        }
    }

    private func makePiPView() -> UIView {
        let container = UIView()
        container.backgroundColor = .white
        pipStatusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        pipDetailLabel.font = .systemFont(ofSize: 15)
        for label in [pipStatusLabel, pipDetailLabel] {
            label.textColor = .black
            // 单行截断：换行会让画中画文字被 OCR 成不以标记开头的碎片。
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        pipStatusLabel.text = "Jarvis · 待命"
        pipDetailLabel.text = "Jarvis 开始录屏后自动识别聊天页"
        let stack = UIStackView(arrangedSubviews: [pipStatusLabel, pipDetailLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}
