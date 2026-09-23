import Foundation

/// 把实时分析的候选回复发布给 Jarvis 键盘（`ReplyBundle`，架构文档 §8.3）。
///
/// - 只有“会话已确认 + 标题可读 + 三条有效候选 + 已完成排序 + 结论未过期”才写 ready；
/// - 主 App 仍看到同一会话、同一内容时才续期 `validUntil`（最长不超过 `expiresAt`），不靠定时器无条件续期；
/// - 停采、换会话、离开聊天页、内容更新：写 invalid 并清空候选；
/// - 键盘自己也按时间失效：主 App 被挂起或终止时来不及写 invalid。
@MainActor
final class ReplyBundlePublisher {
    /// 推荐的最长有效时间。
    static let maxLifetime: TimeInterval = 120
    /// 来源新鲜度窗口：这么久没有再确认同一会话同一内容，键盘就不再允许插入。
    static let freshness: TimeInterval = 15
    /// 续期写文件的最小间隔。
    static let renewInterval: TimeInterval = 3

    private var published: ReplyBundle?
    private var lastWrite = Date.distantPast
    private(set) var isReady = false

    init() {
        // 启动时清掉上次残留的 ready：那时的会话状态已无法确认。
        ReplyBundleStore.write(.invalid(note: "Jarvis 已重新启动，等待新的建议"))
    }

    func refresh(latest: EngineUpdate?, scheduler: LiveAnalysisScheduler, capturing: Bool) {
        let now = Date()
        guard capturing, let latest, latest.detection == .chat, latest.confirmed,
              let title = latest.title, !ChatLayoutParser.isTransientTitle(title),
              let outcome = scheduler.outcome, !outcome.stale, !outcome.repliesUnranked,
              // 同一内容 = 尾部签名不变。用户往上翻只在长图顶部补旧消息，revision 会变但尾部不变，仍然有效。
              outcome.conversationID == latest.conversationID,
              LiveAnalysisScheduler.signature(of: latest.liveMessages) == outcome.signature,
              let replies = outcome.replies, replies.count == 3,
              Set(replies.map(\.text)).count == 3, replies.allSatisfy({ !$0.text.isEmpty })
        else {
            invalidate(reason: Self.reason(latest: latest, scheduler: scheduler, capturing: capturing))
            return
        }

        if var current = published, current.status == .ready, current.analysisRequestID == outcome.requestID.uuidString {
            // 同一份结论：只续期来源新鲜度。
            guard now.timeIntervalSince(lastWrite) >= Self.renewInterval else { return }
            current.validUntil = min(current.expiresAt, now.addingTimeInterval(Self.freshness))
            write(current, now: now)
            return
        }

        // `replies` 是按推荐程度降序；键盘上 rank 1 最低、3 最高。
        let candidates = replies.reversed().enumerated().map { index, reply in
            ReplyBundle.Candidate(id: UUID().uuidString, rank: index + 1, text: reply.text)
        }
        let bundle = ReplyBundle(
            bundleID: UUID().uuidString, status: .ready,
            sessionID: latest.sessionID.uuidString,
            conversationID: outcome.conversationID.uuidString,
            revision: outcome.revision,
            analysisRequestID: outcome.requestID.uuidString,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(Self.maxLifetime),
            validUntil: now.addingTimeInterval(Self.freshness),
            sourceTitle: title, sourceConfidence: "confirmed",
            summary: outcome.analysis.map(JudgeLabels.summary),
            candidates: candidates, note: nil
        )
        write(bundle, now: now)
    }

    private func invalidate(reason: String) {
        guard published?.status != .invalid else { return }
        write(.invalid(note: reason), now: Date())
    }

    private func write(_ bundle: ReplyBundle, now: Date) {
        ReplyBundleStore.write(bundle)
        published = bundle
        lastWrite = now
        isReady = bundle.status == .ready
    }

    private static func reason(latest: EngineUpdate?, scheduler: LiveAnalysisScheduler, capturing: Bool) -> String {
        guard capturing else { return "录屏已停止" }
        guard let latest, latest.detection == .chat else { return "当前不在聊天页" }
        guard latest.confirmed, latest.title != nil else { return "还没确认当前会话" }
        guard let outcome = scheduler.outcome else { return "等待对方新消息" }
        if outcome.stale { return "会话有新内容，正在等待新的建议" }
        if outcome.repliesUnranked { return "候选排序失败，未发布到键盘" }
        return "候选回复生成中"
    }
}
