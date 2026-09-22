import Foundation

/// 三条互相独立的模型路线。凭据按路线分别保存，不做跨路线回退。
enum APIRoute: String, CaseIterable {
    case judge
    case reply
    case vision

    var displayName: String {
        switch self {
        case .judge: return "判断接口"
        case .reply: return "回复接口"
        case .vision: return "视觉接口"
        }
    }
}

/// 判断路线的服务商。reply/vision 只需要 OpenAI 兼容 base URL，没有这一层。
enum JudgeProvider: String, CaseIterable {
    case openRouter = "openrouter"
    case typeSafe = "typesafe"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .typeSafe: return "TypeSafe"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api"
        case .typeSafe: return "https://api.typesafe.ai"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "typesafe/jev-1.13"
        case .typeSafe: return "jev-latest"
        case .custom: return ""
        }
    }

    /// custom 由用户直接填完整 POST 地址，其余按服务商补路径。
    func endpoint(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .custom:
            return trimmed
        case .typeSafe:
            return trimmed.trimmedTrailingSlash + "/v1/systemone"
        case .openRouter:
            return trimmed.trimmedTrailingSlash + "/alpha/decisions"
        }
    }
}

extension String {
    var trimmedTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
