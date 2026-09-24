import Foundation

/// 将独立完成的回复候选发布给键盘，不等待 Jev 判断或长图拼接。
@MainActor
final class ReplyBundlePublisher {
    static let maxLifetime: TimeInterval = 120
    static let freshness: TimeInterval = 15
    static let renewInterval: TimeInterval = 3

    private var published: ReplyBundle?
    private var lastWrite = Date.distantPast
    private var writeFailed = false

    var isReady: Bool { !writeFailed && published?.isUsable() == true }
    var unavailableReason: String {
        if writeFailed { return "候选共享写入失败，请返回 Jarvis 检查" }
        guard let published else { return "等待回复候选" }
        if published.status == .invalid { return published.note ?? "等待回复候选" }
        if Date() >= published.expiresAt { return "候选已过期，请重新分析" }
        if Date() >= published.validUntil { return "等待当前聊天画面更新" }
        return "候选暂不可用"
    }

    init() { write(.invalid(note: "Jarvis 已启动，等待回复候选")) }

    func refresh(context: ConversationContext?, currentRequest: AnalysisRequest?,
                 judge: LiveAnalysisScheduler.Outcome?, replies: ReplySuggestionScheduler.Outcome?,
                 replyPhase: ReplySuggestionScheduler.Phase, capturing: Bool, captureNote: String) {
        guard capturing else { return invalidate(captureNote) }
        guard let context, !context.tailSignature.isEmpty else {
            return invalidate("本屏尚未识别到可读聊天文字")
        }
        let now = Date()
        guard now >= context.observedAt.addingTimeInterval(-5), now < context.observedAt.addingTimeInterval(Self.freshness) else {
            return invalidate("等待当前聊天画面更新")
        }
        switch replyPhase {
        case .idle: return invalidate("等待回复任务")
        case .generating: return invalidate("正在生成候选文案…")
        case .ranking: return invalidate("正在排序候选文案…")
        case .failed(let reason): return invalidate(reason)
        case .ready: break
        }
        guard let request = currentRequest, let replies, !replies.stale,
              replies.request.id == request.id, replies.request.version == request.version,
              request.version.sessionID == context.sessionID, request.version.conversationID == context.conversationID,
              request.version.tailSignature == context.tailSignature else {
            return invalidate("当前聊天已更新，等待新的回复候选")
        }
        guard !replies.repliesUnranked, replies.error == nil else {
            return invalidate(replies.error ?? "候选排序尚未完成")
        }
        guard ReplyBundle.hasValidCandidateTexts(replies.replies.map(\.text)) else {
            return invalidate("需要三条不同、长度有效的候选回复")
        }
        let generatedAt = replies.completedAt
        let expiresAt = generatedAt.addingTimeInterval(Self.maxLifetime)
        guard now >= generatedAt.addingTimeInterval(-5), now < expiresAt else {
            return invalidate("候选已过期，请重新分析")
        }
        let validUntil = min(expiresAt, context.observedAt.addingTimeInterval(Self.freshness))
        let summary = judge.flatMap { result -> String? in
            guard !result.stale, result.request.id == request.id,
                  result.request.version == request.version else { return nil }
            return result.analysis.map(JudgeLabels.summary)
        }
        let confidence = context.sourceConfirmed ? "confirmed" : "recognized"
        if var current = published, current.status == .ready, current.analysisRequestID == request.id.uuidString,
           current.sourceTitle == context.sourceTitle, current.sourceConfidence == confidence {
            guard writeFailed || current.summary != summary
                || (validUntil > current.validUntil && now.timeIntervalSince(lastWrite) >= Self.renewInterval) else { return }
            current.summary = summary
            current.validUntil = validUntil
            write(current)
            return
        }
        let candidates = replies.replies.reversed().enumerated().map {
            ReplyBundle.Candidate(id: UUID().uuidString, rank: $0.offset + 1, text: $0.element.text)
        }
        write(ReplyBundle(bundleID: UUID().uuidString, status: .ready, sessionID: context.sessionID.uuidString,
                          conversationID: context.conversationID.uuidString, revision: request.context.revision,
                          analysisRequestID: request.id.uuidString, generatedAt: generatedAt, expiresAt: expiresAt,
                          validUntil: validUntil, sourceTitle: context.sourceTitle, sourceConfidence: confidence,
                          summary: summary, candidates: candidates, note: nil))
    }

    private func invalidate(_ reason: String) {
        guard writeFailed || published?.status != .invalid || published?.note != reason else { return }
        write(.invalid(note: reason))
    }

    private func write(_ bundle: ReplyBundle) {
        guard ReplyBundleStore.write(bundle) else {
            writeFailed = true
            return
        }
        writeFailed = false
        published = bundle
        lastWrite = Date()
    }
}
