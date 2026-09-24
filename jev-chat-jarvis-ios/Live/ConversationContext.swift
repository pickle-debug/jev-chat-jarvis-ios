import Foundation

/// OCR 的纯文字输出。语义分析不依赖截图、拼接段或观察次数。
nonisolated struct ContextMessage: Sendable {
    let id: UUID
    let speaker: Speaker
    let text: String
    var isGap: Bool = false
}

nonisolated struct ConversationContext: Sendable {
    let sessionID: UUID
    let conversationID: UUID
    let revision: Int
    let sourceTitle: String
    let sourceConfirmed: Bool
    let frameID: UUID
    let observedAt: Date
    let messages: [ContextMessage]

    var tailSignature: String {
        guard let last = messages.last(where: { !$0.isGap }) else { return "" }
        return "\(last.id.uuidString)|\(last.speaker.rawValue)|\(last.text)"
    }

    func snapshot(limit: Int) -> ChatSnapshot {
        ChatSnapshot(messages: messages.map {
            ChatMessage(speaker: $0.speaker, text: $0.text, isGap: $0.isGap)
        }, contextLimit: limit)
    }

    func version(for snapshot: ChatSnapshot) -> ContextVersion {
        let fingerprint = snapshot.recentMessages.map {
            "\($0.isGap)|\($0.speaker.rawValue)|\($0.text.utf8.count):\($0.text)"
        }.joined(separator: "|")
        return ContextVersion(sessionID: sessionID, conversationID: conversationID,
                              tailSignature: tailSignature, windowFingerprint: fingerprint)
    }
}

nonisolated struct ContextVersion: Equatable, Sendable {
    let sessionID: UUID
    let conversationID: UUID
    let tailSignature: String
    let windowFingerprint: String
}

nonisolated struct AnalysisRequest: Sendable {
    let id: UUID
    let context: ConversationContext
    let version: ContextVersion
    let snapshot: ChatSnapshot
    let startedAt: Date
    let isContextRefresh: Bool

    var analyzedCount: Int { snapshot.recentMessages.filter { !$0.isGap }.count }
    var analyzedFirstID: UUID? {
        context.messages.filter { !$0.isGap }.suffix(max(1, snapshot.contextLimit)).first?.id
    }
}
