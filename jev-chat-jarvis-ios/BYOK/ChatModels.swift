import Foundation

/// 消息的发言方。`unknown` 表示版式无法可靠分边，不擅自归成 `other`。
enum Speaker: String {
    case me
    case other
    case unknown
}

struct ChatMessage {
    let speaker: Speaker
    let text: String
}

/// 一次分析的输入。首版来自用户手动粘贴，后续接 OCR 会话层。
struct ChatSnapshot {
    let messages: [ChatMessage]

    /// 发给模型的只取最近 10 条，和安卓参考实现一致。
    var recentMessages: [ChatMessage] {
        Array(messages.suffix(10))
    }
}

/// Jev choice 类型的答案。
struct Choice {
    let choice: String
    let confidence: Double
    let probabilities: [String: Double]
}

/// Jev score 类型的答案。
struct Score {
    let score: Double
    let confidence: Double
    let maxLevel: Int
}

/// 排序后的候选回复。`probability` 是 Jev 给出的相对优劣，不是"正确率"。
struct RankedReply {
    let text: String
    let probability: Double
}

/// 一次判断的完整结果。字段为 nil 表示模型没有返回该项。
struct Analysis {
    let trueIntent: Choice?
    let dangerLevel: Score?
    let sheNeeds: Choice?
    let shouldReplyNow: Double?
    let bestAction: Choice?
    let tensionResolved: Double?
    let literalQuestion: Double?
    let latencyMs: Int
}
