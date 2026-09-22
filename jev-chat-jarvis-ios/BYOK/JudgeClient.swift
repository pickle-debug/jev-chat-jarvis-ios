import Foundation

/// Jev decisions 接口的响应。answers 的键由请求中的 questions 决定。
struct DecisionsResponse: Decodable {
    let answers: [String: Answer]

    struct Answer: Decodable {
        let choice: String?
        let confidence: Double?
        let noul: Double?
        let score: Double?
        let probabilities: [String: Double]?
        let legend: [String: String]?
    }
}

/// Jev 判断路线：7 道判断题和候选排序题。判断与排序共用同一套凭据。
struct JudgeClient {
    private let config: JarvisConfig
    private let client: JarvisAPIClient

    init(config: JarvisConfig = .shared, client: JarvisAPIClient = .shared) {
        self.config = config
        self.client = client
    }

    func judge(snapshot: ChatSnapshot, relationship: String) async throws -> Analysis {
        let started = Date()
        let answers = try await send(
            state: JevQuestions.buildState(snapshot: snapshot, relationship: relationship),
            questions: JevQuestions.judge()
        )
        return Analysis(
            trueIntent: Self.parseChoice(answers["true_intent"]),
            dangerLevel: Self.parseScore(answers["danger_level"]),
            sheNeeds: Self.parseChoice(answers["she_needs"]),
            shouldReplyNow: answers["should_reply_now"]?.noul,
            bestAction: Self.parseChoice(answers["best_action"]),
            tensionResolved: answers["tension_resolved"]?.noul,
            literalQuestion: answers["literal_question"]?.noul,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    /// 对 3 条候选排序，返回按推荐程度降序的列表。
    func rank(
        snapshot: ChatSnapshot,
        relationship: String,
        candidates: [String]
    ) async throws -> [RankedReply] {
        let answers = try await send(
            state: JevQuestions.buildState(snapshot: snapshot, relationship: relationship),
            questions: JevQuestions.rankQuestion(candidates: candidates)
        )
        guard let best = answers["best_reply"], let probabilities = best.probabilities else {
            throw APIError(route: .judge, status: nil, detail: "排序接口未返回 best_reply 概率")
        }
        let ranked = candidates.enumerated().map { index, text in
            RankedReply(text: text, probability: probabilities[JevQuestions.rankKeys[index]] ?? 0)
        }
        return ranked.sorted { $0.probability > $1.probability }
    }

    private func send(state: JSONValue, questions: [String: JSONValue]) async throws -> [String: DecisionsResponse.Answer] {
        let body = JSONValue.object([
            "model": .string(config.judgeModel),
            "state": state,
            "questions": .object(questions)
        ])
        let response = try await client.post(
            route: .judge,
            urlString: config.judgeEndpoint,
            key: config.secrets.key(for: .judge),
            body: body,
            as: DecisionsResponse.self
        )
        return response.answers
    }

    private static func parseChoice(_ answer: DecisionsResponse.Answer?) -> Choice? {
        guard let answer, let choice = answer.choice else { return nil }
        return Choice(
            choice: choice,
            confidence: answer.confidence ?? 0,
            probabilities: answer.probabilities ?? [:]
        )
    }

    private static func parseScore(_ answer: DecisionsResponse.Answer?) -> Score? {
        guard let answer, let score = answer.score else { return nil }
        let maxLevel = answer.legend?.keys.compactMap(Int.init).max() ?? 9
        return Score(score: score, confidence: answer.confidence ?? 0, maxLevel: maxLevel)
    }
}
