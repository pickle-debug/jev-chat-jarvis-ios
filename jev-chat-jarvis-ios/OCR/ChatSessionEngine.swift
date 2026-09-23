import CoreGraphics
import Foundation

/// 拼接后的一条消息，供主线程展示和分析。
nonisolated struct LiveMessage: Sendable, Equatable {
    let id: UUID
    let kind: BubbleKind
    let side: BubbleSide
    let sideConfidence: Double
    let text: String
    let senderName: String?
    let quote: String?
    let observations: Int
    let clipped: Bool
}

/// 一段拼接片段的摘要。
nonisolated struct LiveSegmentSummary: Sendable {
    let id: UUID
    let isLive: Bool
    let messages: [LiveMessage]
    let imageSpan: Int
    /// 长梯当前保留的截图张数（去重后）。
    let rungCount: Int
}

/// 引擎每处理一帧给出的状态快照。只含展示和分析需要的数据，不含像素。
nonisolated struct EngineUpdate: Sendable {
    enum Detection: Sendable, Equatable {
        case waiting
        case notChat(reason: String)
        case chat
    }

    let sessionID: UUID
    let frameID: UUID
    let detection: Detection
    /// 两帧确认后才为 true；单帧误判不会产生可分析的会话。
    let confirmed: Bool
    let conversationID: UUID?
    let title: String?
    /// 实时段内容（side + 文字）变化时递增。展示状态变化不递增。
    let revision: Int
    let segments: [LiveSegmentSummary]
    let liveMessages: [LiveMessage]
    let currentSegmentIsLive: Bool
    /// 画面停在实时段底部（没有在翻历史）。
    let viewingLiveTail: Bool
    let placement: StitchPlacement.Kind?
    let skippedUnchanged: Bool
    let ocrMilliseconds: Int
    let framesProcessed: Int
    let framesSkipped: Int
}

/// 屏幕帧 → 聊天会话的后台引擎。
///
/// actor 串行化所有状态；Vision 识别在自己的队列里跑，await 期间不占用 actor。
/// 采集会话切换时自动重置，旧会话的帧在 OCR 返回后被丢弃，不会写进新会话。
actor ChatSessionEngine {
    private let ocr = VisionOCRService()
    private let parser = ChatLayoutParser()
    private let stitcher = ChatStitcher()
    private var ladders: [UUID: ChatLadder] = [:]
    private var ladderCapacity: Int
    private var anchors = LayoutAnchors()

    private var sessionID: UUID?
    private var frameSize: CGSize?
    private var lastThumbnail: [UInt8]?
    private var lastUpdate: EngineUpdate?

    private var inChat = false
    private var chatStreak = 0
    private var nonChatStreak = 0
    private var interrupted = false
    private var lastFrameWasChat = false
    private var consecutiveSkips = 0
    private var lastRejectReason = "不是聊天页"

    private var conversationID: UUID?
    private var conversationTitle: String?
    private var confirmed = false
    private var pendingTitle: (title: String, count: Int)?
    private var revision = 0
    private var contentHash = 0

    private var framesProcessed = 0
    private var framesSkipped = 0

    init(ladderCapacity: Int = ChatLadder.defaultCapacity) {
        self.ladderCapacity = ladderCapacity
    }

    func setLadderCapacity(_ value: Int) {
        ladderCapacity = max(2, value)
        for ladder in ladders.values { ladder.setCapacity(ladderCapacity) }
    }

    func clear() {
        resetConversation()
        sessionID = nil
        frameSize = nil
        lastThumbnail = nil
        lastUpdate = nil
        inChat = false
        lastFrameWasChat = false
        chatStreak = 0
        nonChatStreak = 0
        framesProcessed = 0
        framesSkipped = 0
    }

    /// 处理一帧。`overlayMarkers`：画中画里会出现的固定前缀，OCR 到以它们开头的行时丢弃，
    /// 避免 Jarvis 自己的提示被当成聊天内容。
    func process(
        jpeg: Data, frameID: UUID, sessionID frameSession: UUID, capturedAt: Date, overlayMarkers: [String]
    ) async -> EngineUpdate? {
        if sessionID != frameSession {
            clear()
            sessionID = frameSession
        }
        guard let bitmap = FrameBitmap(jpegData: jpeg) else { return nil }
        if let frameSize, frameSize != bitmap.size {
            // 旋转或分辨率变化后像素坐标不可比，重新开始。
            resetConversation()
            anchors = LayoutAnchors()
            inChat = false
            chatStreak = 0
        }
        frameSize = bitmap.size

        // 画面几乎没变 → 跳过 OCR，只把可见消息记一次稳定观察。
        let thumbnail = bitmap.thumbnail()
        // 连续跳过有上限：缩略图很粗，版式重复的画面可能误判为“没变”，最多延迟几帧就会重新识别。
        if let lastThumbnail, consecutiveSkips < 4,
           FrameBitmap.thumbnailDistance(thumbnail, lastThumbnail) < 1.5, let lastUpdate {
            framesSkipped += 1
            consecutiveSkips += 1
            if lastFrameWasChat {
                stitcher.confirmStable()
                return makeUpdate(frameID: frameID, detection: lastUpdate.detection, placement: nil, skipped: true, ocrMs: 0)
            }
            // 静止的非聊天页同样要累计，否则离开聊天后永远停在“已检测到聊天页”。
            return nonChatFrame(frameID: frameID, reason: lastRejectReason, skipped: true, ocrMs: 0)
        }

        consecutiveSkips = 0
        let started = Date()
        let rawLines = await ocr.recognize(bitmap.image)
        // await 期间可能已经切到新的采集会话：旧帧直接丢弃。
        guard sessionID == frameSession else { return nil }
        let ocrMs = Int(Date().timeIntervalSince(started) * 1000)
        lastThumbnail = thumbnail
        framesProcessed += 1

        let lines = rawLines.filter { line in
            !overlayMarkers.contains { line.text.hasPrefix($0) }
        }
        let parsed = parser.parse(lines: lines, bitmap: bitmap, frameID: frameID, capturedAt: capturedAt, anchors: anchors)

        lastFrameWasChat = parsed.isChat
        guard parsed.isChat else {
            lastRejectReason = parsed.rejectReason ?? "不是聊天页"
            return nonChatFrame(frameID: frameID, reason: lastRejectReason, skipped: false, ocrMs: ocrMs)
        }
        nonChatStreak = 0
        chatStreak += 1
        let reentering = !inChat && interrupted
        inChat = true

        // 会话身份：标题稳定变化两帧才切换，防止单帧 OCR 误读把整段记录清掉。
        let title = ChatLayoutParser.isTransientTitle(parsed.title) ? nil : parsed.title
        if conversationID == nil {
            startConversation(title: title)
        } else if let title, let current = conversationTitle,
                  TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(current)) < 0.6 {
            if let pending = pendingTitle, TextMatch.normalize(pending.title) == TextMatch.normalize(title) {
                pendingTitle = (title, pending.count + 1)
            } else {
                pendingTitle = (title, 1)
            }
            guard (pendingTitle?.count ?? 0) >= 2 else {
                return makeUpdate(frameID: frameID, detection: .chat, placement: nil, skipped: false, ocrMs: ocrMs)
            }
            startConversation(title: title)
        } else if reentering && title == nil {
            // 回到聊天页但看不清标题，无法确认还是同一个人：保守地当新会话。
            startConversation(title: nil)
        } else {
            pendingTitle = nil
            if conversationTitle == nil, let title { conversationTitle = title }
        }
        if chatStreak >= 2 { confirmed = true }
        interrupted = false

        let placement = stitcher.ingest(parsed, bitmap: bitmap, preferLiveOnNewSegment: reentering)
        if let placement {
            let target = ladder(for: placement.segmentID, width: bitmap.width)
            for (mergedID, shift) in placement.merged {
                if let source = ladders.removeValue(forKey: mergedID) { target.absorb(source, shift: shift) }
            }
            // 标题栏只取本帧识别到标题的；被通知横幅遮住的帧不提供。输入栏只在键盘收起时提供。
            let header: (jpeg: Data, height: Int)? = parsed.titleAnchored
                ? bitmap.jpegStrip(y: 0, height: Int(parsed.headerBottom)).map { ($0, Int(parsed.headerBottom)) } : nil
            let footerTop = Int(parsed.contentBottom.rounded())
            let footer: (jpeg: Data, height: Int)? = parsed.keyboardVisible
                ? nil : bitmap.jpegStrip(y: footerTop, height: bitmap.height - footerTop).map { ($0, bitmap.height - footerTop) }
            target.add(
                bitmap: bitmap, contentTop: parsed.contentTop, contentBottom: parsed.contentBottom,
                offset: placement.offset, bubbleRects: parsed.bubbles.map(\.rect),
                capturedAt: capturedAt, header: header, footer: footer
            )
            let alive = Set(stitcher.segments.map(\.id))
            ladders = ladders.filter { alive.contains($0.key) }
        }
        anchors.record(parsed)

        return makeUpdate(frameID: frameID, detection: .chat, placement: placement?.kind, skipped: false, ocrMs: ocrMs)
    }

    /// 导出某段（默认实时段）的长截图为 JPEG。
    func renderLongScreenshot(segmentID: UUID?, maxPixelHeight: Int) -> Data? {
        guard let id = segmentID ?? stitcher.liveSegment?.id ?? stitcher.currentSegmentID,
              let ladder = ladders[id],
              let image = ladder.render(maxPixelHeight: maxPixelHeight)
        else { return nil }
        return FrameBitmap.encodeJPEG(image, quality: 0.85)
    }

    // MARK: - 内部

    private func nonChatFrame(frameID: UUID, reason: String, skipped: Bool, ocrMs: Int) -> EngineUpdate {
        nonChatStreak += 1
        chatStreak = 0
        if inChat && nonChatStreak >= 2 {
            inChat = false
            interrupted = true
            stitcher.markInterrupted()
            // 只闪了一下、从未确认的会话不保留。
            if !confirmed { resetConversation() }
        }
        let detection: EngineUpdate.Detection = inChat ? .chat : .notChat(reason: reason)
        return makeUpdate(frameID: frameID, detection: detection, placement: nil, skipped: skipped, ocrMs: ocrMs)
    }

    private func startConversation(title: String?) {
        resetConversation()
        conversationID = UUID()
        conversationTitle = title
    }

    private func resetConversation() {
        stitcher.reset()
        ladders = [:]
        conversationID = nil
        conversationTitle = nil
        confirmed = false
        pendingTitle = nil
        interrupted = false
        contentHash = 0
        revision += 1
    }

    private func ladder(for id: UUID, width: Int) -> ChatLadder {
        if let existing = ladders[id], existing.width == width { return existing }
        let ladder = ChatLadder(width: width, capacity: ladderCapacity)
        ladders[id] = ladder
        return ladder
    }

    private func makeUpdate(
        frameID: UUID, detection: EngineUpdate.Detection, placement: StitchPlacement.Kind?, skipped: Bool, ocrMs: Int
    ) -> EngineUpdate {
        let summaries = stitcher.segments.map { segment in
            LiveSegmentSummary(
                id: segment.id, isLive: segment.isLive,
                messages: segment.entries.map(Self.message),
                imageSpan: ladders[segment.id]?.span ?? 0,
                rungCount: ladders[segment.id]?.rungs.count ?? 0
            )
        }
        let live = summaries.first { $0.isLive }?.messages ?? []
        var hasher = Hasher()
        hasher.combine(conversationID)
        for message in live {
            hasher.combine(message.kind.rawValue)
            hasher.combine(message.side.rawValue)
            hasher.combine(TextMatch.normalize(message.text))
            hasher.combine(message.quote)
        }
        let hash = hasher.finalize()
        if hash != contentHash {
            contentHash = hash
            revision += 1
        }
        let update = EngineUpdate(
            sessionID: sessionID ?? UUID(),
            frameID: frameID,
            detection: detection,
            confirmed: confirmed,
            conversationID: conversationID,
            title: conversationTitle,
            revision: revision,
            segments: summaries,
            liveMessages: live,
            currentSegmentIsLive: stitcher.currentSegment?.isLive ?? false,
            viewingLiveTail: stitcher.isViewingLiveTail,
            placement: placement,
            skippedUnchanged: skipped,
            ocrMilliseconds: ocrMs,
            framesProcessed: framesProcessed,
            framesSkipped: framesSkipped
        )
        lastUpdate = update
        return update
    }

    private static func message(_ entry: TranscriptEntry) -> LiveMessage {
        LiveMessage(
            id: entry.id, kind: entry.kind, side: entry.side, sideConfidence: entry.sideConfidence, text: entry.text,
            senderName: entry.senderName, quote: entry.quote, observations: entry.observations, clipped: entry.clipped
        )
    }
}
