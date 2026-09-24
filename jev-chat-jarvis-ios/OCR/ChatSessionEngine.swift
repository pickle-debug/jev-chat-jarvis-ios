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
    /// 在段链里的位置：0 = 含最新消息，越大越早；nil = 没接上链的孤立片段。
    let chainIndex: Int?
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
    /// 单帧版式证据充分，或连续观察到聊天页后为 true。
    let confirmed: Bool
    let conversationID: UUID?
    let title: String?
    /// 实时段内容（side + 文字）变化时递增。展示状态变化不递增。
    let revision: Int
    let segments: [LiveSegmentSummary]
    let currentMessages: [LiveMessage]
    let contextMessages: [LiveMessage]
    /// 兼容展示层，等同 contextMessages。
    let liveMessages: [LiveMessage]
    /// 当前屏尚未和已知消息链对齐，liveMessages 只包含本段，不推断与其他段的先后。
    let currentContextIsIsolated: Bool
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
    private let recognizer = ChatFrameRecognizer()
    private let stitcher = ChatStitcher()
    private var anchors = LayoutAnchors()
    private var epoch: UUID?
    private var currentMessages: [LiveMessage] = []
    private var currentHistoryIDs: Set<UUID> = []

    private var sessionID: UUID?
    private var frameSize: CGSize?

    private var inChat = false
    private var chatStreak = 0
    private var nonChatStreak = 0
    private var interrupted = false
    private var lastRejectReason = "不是聊天页"

    private var conversationID: UUID?
    private var conversationTitle: String?
    private var confirmed = false
    private var pendingTitle: (title: String, count: Int)?
    private var revision = 0
    private var contentHash = 0

    private var framesProcessed = 0
    private var framesSkipped = 0

    func clear() {
        resetConversation()
        sessionID = nil
        frameSize = nil
        inChat = false
        chatStreak = 0
        nonChatStreak = 0
        framesProcessed = 0
        framesSkipped = 0
        epoch = nil
    }

    /// 处理一帧。画中画标记必须组成版式一致的多行簇，才用于排除自己的界面。
    func process(
        jpeg: Data, frameID: UUID, sessionID frameSession: UUID, capturedAt: Date, overlayMarkers: [String], epoch frameEpoch: UUID
    ) async -> EngineOutput? {
        if epoch != frameEpoch || sessionID != frameSession {
            clear()
            sessionID = frameSession
            epoch = frameEpoch
        }
        guard let recognized = await recognizer.recognize(jpeg: jpeg, frameID: frameID, capturedAt: capturedAt,
                                                          anchors: anchors, currentTitle: conversationTitle,
                                                          overlayMarkers: overlayMarkers),
              sessionID == frameSession, epoch == frameEpoch else { return nil }
        let bitmap = recognized.bitmap
        var parsed = recognized.parsed
        let ocrMs = recognized.ocrMilliseconds
        if let frameSize, frameSize != bitmap.size {
            // 旋转或分辨率变化后像素坐标不可比，重新开始。
            resetConversation()
            anchors = LayoutAnchors()
            inChat = false
            chatStreak = 0
        }
        frameSize = bitmap.size

        framesProcessed += 1
        // 整屏都是图片、一条文字消息都没有：只要标题还是这个会话，就是同一个聊天页，不能切断会话。
        if !parsed.isChat, inChat, parsed.messageBubbles.isEmpty, conversationID != nil,
           continuesConversation(parsed) {
            parsed = parsed.continuingChat(reason: "这一屏没有文字消息（可能都是图片）")
        }

        guard parsed.isChat else {
            lastRejectReason = parsed.rejectReason ?? "不是聊天页"
            currentMessages = []
            return EngineOutput(update: nonChatFrame(frameID: frameID, reason: lastRejectReason, skipped: false, ocrMs: ocrMs), longScreenshot: nil)
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
            guard (pendingTitle?.count ?? 0) >= 2 || parsed.hasReliableSingleFrameEvidence else {
                currentMessages = []
                return EngineOutput(update: makeUpdate(frameID: frameID, detection: .waiting, placement: nil, skipped: false, ocrMs: ocrMs), longScreenshot: nil)
            }
            startConversation(title: title)
        } else if reentering && title == nil {
            // 回到聊天页但看不清标题，无法确认还是同一个人：保守地当新会话。
            startConversation(title: nil)
        } else {
            pendingTitle = nil
            if conversationTitle == nil, let title { conversationTitle = title }
        }
        if chatStreak >= 2 || parsed.hasReliableSingleFrameEvidence { confirmed = true }
        interrupted = false

        let placement = stitcher.ingest(parsed, bitmap: bitmap)
        var usedIDs = Set<UUID>()
        var usedEntryIDs = Set<UUID>()
        var matchedHistoryIDs = Set<UUID>()
        let previousMessages = currentMessages
        currentMessages = parsed.messageBubbles.enumerated().map { index, bubble in
            let normalized = TextMatch.normalize(bubble.text)
            let entry = stitcher.currentSegment?.entries.filter {
                $0.kind == .message && !usedEntryIDs.contains($0.id)
                    && ($0.side == bubble.side || $0.side == .unknown || bubble.side == .unknown)
                    && abs($0.top - bubble.rect.minY - (placement?.offset ?? 0)) < max(14, bubble.rect.height)
                    && TextMatch.similarity($0.normalized, normalized) >= 0.7
            }.min { abs($0.top - bubble.rect.minY - (placement?.offset ?? 0)) < abs($1.top - bubble.rect.minY - (placement?.offset ?? 0)) }
            let prior = previousMessages.enumerated().filter {
                !usedIDs.contains($0.element.id) && $0.element.side == bubble.side
                    && TextMatch.similarity(TextMatch.normalize($0.element.text), normalized) >= 0.7
            }.min { abs($0.offset - index) < abs($1.offset - index) }?.element
            let sameSequence = previousMessages.count == parsed.messageBubbles.count
                && previousMessages.indices.contains(index)
                && TextMatch.normalize(previousMessages[index].text) == normalized
                && previousMessages[index].side == bubble.side
                && !usedIDs.contains(previousMessages[index].id)
            let id = sameSequence ? previousMessages[index].id : (entry?.id ?? prior?.id ?? UUID())
            usedIDs.insert(id)
            if let entry {
                usedEntryIDs.insert(entry.id)
                matchedHistoryIDs.insert(entry.id)
            }
            return LiveMessage(id: id, kind: .message,
                        side: bubble.side, sideConfidence: bubble.sideConfidence,
                        text: bubble.text, senderName: bubble.senderName, quote: bubble.quote,
                        observations: entry?.observations ?? ((prior?.observations ?? 0) + 1), clipped: bubble.clipped)
        }
        currentHistoryIDs = matchedHistoryIDs
        let screenshotInput: LongScreenshotInput? = placement.map {
            LongScreenshotInput(epoch: frameEpoch, sessionID: frameSession, conversationID: conversationID,
                                frameID: frameID, bitmap: bitmap, parsed: parsed, placement: $0,
                                activeSegmentIDs: Set(stitcher.segments.map(\.id)), preferredSegmentID: $0.segmentID)
        }
        anchors.record(parsed)

        let detection: EngineUpdate.Detection = currentMessages.isEmpty ? .waiting : .chat
        return EngineOutput(update: makeUpdate(frameID: frameID, detection: detection, placement: placement?.kind, skipped: false, ocrMs: ocrMs), longScreenshot: screenshotInput)
    }

    // MARK: - 内部

    /// 无文字消息的帧必须仍看得清同一个标题，不能仅凭上帧还在聊天页继续沿用。
    private func continuesConversation(_ parsed: ParsedChatFrame) -> Bool {
        guard let current = conversationTitle,
              let title = parsed.title,
              !ChatLayoutParser.isTransientTitle(title) else { return false }
        return TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(current)) >= 0.6
    }

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
        let detection: EngineUpdate.Detection = inChat ? .waiting : .notChat(reason: reason)
        return makeUpdate(frameID: frameID, detection: detection, placement: nil, skipped: skipped, ocrMs: ocrMs)
    }

    private func startConversation(title: String?) {
        resetConversation()
        conversationID = UUID()
        conversationTitle = title
        chatStreak = 1
    }

    private func resetConversation() {
        stitcher.reset()
        currentMessages = []
        currentHistoryIDs = []
        anchors = LayoutAnchors()
        conversationID = nil
        conversationTitle = nil
        confirmed = false
        pendingTitle = nil
        interrupted = false
        contentHash = 0
        revision += 1
    }

    private func makeUpdate(
        frameID: UUID, detection: EngineUpdate.Detection, placement: StitchPlacement.Kind?, skipped: Bool, ocrMs: Int
    ) -> EngineUpdate {
        let chain = stitcher.chain
        let summaries = stitcher.segments.map { segment in
            LiveSegmentSummary(
                id: segment.id, isLive: segment.isLive,
                // 只把文字确认过的消息交给对话列表和分析：画面位移放进来的图片小字不进上下文。
                messages: segment.entries.filter(\.textConfirmed).map(Self.message),
                imageSpan: 0,
                rungCount: 0,
                chainIndex: chain.firstIndex(of: segment.id)
            )
        }
        let isolated = summaries.first { $0.id == stitcher.currentSegmentID && $0.chainIndex == nil }
        // 未对齐的新屏独立分析，不能让旧链的签名替代当前可读内容、持续续期旧候选。
        // 已在链内时仍沿用最新消息，向上滚动只补历史上下文。
        let contextIDs = isolated.map { [$0.id] } ?? Array(chain.reversed())
        var live: [LiveMessage] = []
        for id in contextIDs {
            guard let segment = summaries.first(where: { $0.id == id }) else { continue }
            if !live.isEmpty {
                live.append(LiveMessage(
                    id: segment.id, kind: .gap, side: .unknown, sideConfidence: 0,
                    text: "中间有未识别的聊天记录", senderName: nil, quote: nil, observations: 0, clipped: false
                ))
            }
            live += segment.messages
        }
        let currentTailMissing = currentMessages.last.map { tail in
            !live.contains {
                $0.id == tail.id || (currentHistoryIDs.contains($0.id) && $0.side == tail.side && $0.kind == .message
                    && TextMatch.normalize($0.text) == TextMatch.normalize(tail.text))
            }
        } ?? true
        if currentTailMissing { live = currentMessages }
        var hasher = Hasher()
        hasher.combine(conversationID)
        for message in live where message.kind != .gap {
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
            currentMessages: currentMessages,
            contextMessages: live,
            liveMessages: live,
            currentContextIsIsolated: isolated != nil || currentTailMissing,
            currentSegmentIsLive: stitcher.currentSegment?.isLive ?? false,
            viewingLiveTail: stitcher.isViewingLiveTail,
            placement: placement,
            skippedUnchanged: skipped,
            ocrMilliseconds: ocrMs,
            framesProcessed: framesProcessed,
            framesSkipped: framesSkipped
        )
        return update
    }

    private static func message(_ entry: TranscriptEntry) -> LiveMessage {
        LiveMessage(
            id: entry.id, kind: entry.kind, side: entry.side, sideConfidence: entry.sideConfidence, text: entry.text,
            senderName: entry.senderName, quote: entry.quote, observations: entry.observations, clipped: entry.clipped
        )
    }
}
