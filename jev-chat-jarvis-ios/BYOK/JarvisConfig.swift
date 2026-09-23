import Foundation

/// 三路模型的非敏感配置。密钥在 `SecretStore`。
///
/// 每路凭据显式绑定到自己的服务，不沿用安卓 "reply key 为空就继承 judge key"
/// 的隐式跨域回退——那会把 A 家的密钥发到 B 家的域名。
final class JarvisConfig {
    static let shared = JarvisConfig()

    private let defaults: UserDefaults
    let secrets: SecretStore

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.secrets = SecretStore(defaults: defaults)
    }

    // MARK: - Judge

    var judgeProvider: JudgeProvider {
        get {
            let raw = defaults.string(forKey: Keys.judgeProvider) ?? ""
            return JudgeProvider(rawValue: raw) ?? .openRouter
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.judgeProvider) }
    }

    var judgeBaseURL: String {
        get { defaults.trimmedString(Keys.judgeBaseURL) ?? judgeProvider.defaultBaseURL }
        set { defaults.setTrimmed(newValue, forKey: Keys.judgeBaseURL) }
    }

    var judgeModel: String {
        get { defaults.trimmedString(Keys.judgeModel) ?? judgeProvider.defaultModel }
        set { defaults.setTrimmed(newValue, forKey: Keys.judgeModel) }
    }

    var judgeEndpoint: String {
        judgeProvider.endpoint(baseURL: judgeBaseURL)
    }

    // MARK: - Reply

    var replyBaseURL: String {
        get { defaults.trimmedString(Keys.replyBaseURL) ?? Defaults.replyBaseURL }
        set { defaults.setTrimmed(newValue, forKey: Keys.replyBaseURL) }
    }

    var replyModel: String {
        get { defaults.trimmedString(Keys.replyModel) ?? Defaults.replyModel }
        set { defaults.setTrimmed(newValue, forKey: Keys.replyModel) }
    }

    var replyEndpoint: String {
        replyBaseURL.trimmedTrailingSlash + "/chat/completions"
    }

    // MARK: - Vision（可选，默认关闭）

    var visionEnabled: Bool {
        get { defaults.bool(forKey: Keys.visionEnabled) }
        set { defaults.set(newValue, forKey: Keys.visionEnabled) }
    }

    var visionBaseURL: String {
        get { defaults.trimmedString(Keys.visionBaseURL) ?? Defaults.visionBaseURL }
        set { defaults.setTrimmed(newValue, forKey: Keys.visionBaseURL) }
    }

    var visionModel: String {
        get { defaults.trimmedString(Keys.visionModel) ?? Defaults.visionModel }
        set { defaults.setTrimmed(newValue, forKey: Keys.visionModel) }
    }

    var visionEndpoint: String {
        visionBaseURL.trimmedTrailingSlash + "/chat/completions"
    }

    // MARK: - 分析上下文

    var relationship: String {
        get { defaults.trimmedString(Keys.relationship) ?? Defaults.relationship }
        set { defaults.setTrimmed(newValue, forKey: Keys.relationship) }
    }

    // MARK: - 长截图与上下文

    /// 长截图保留的不重复画面张数。越多越占内存（每张约 100 KB JPEG），导出的长图越长。
    var ladderCapacity: Int {
        get { Self.clamp(defaults.object(forKey: Keys.ladderCapacity) as? Int, Defaults.ladderCapacity, Defaults.ladderCapacityRange) }
        set {
            defaults.set(Self.clamp(newValue, Defaults.ladderCapacity, Defaults.ladderCapacityRange), forKey: Keys.ladderCapacity)
            NotificationCenter.default.post(name: JarvisConfig.liveSettingsDidChange, object: self)
        }
    }

    /// 每次分析发给模型的最近聊天条数（不含时间分隔线）。越多上下文越完整，token 消耗也越多。
    var contextMessageCount: Int {
        get { Self.clamp(defaults.object(forKey: Keys.contextMessageCount) as? Int, Defaults.contextMessageCount, Defaults.contextMessageRange) }
        set {
            defaults.set(Self.clamp(newValue, Defaults.contextMessageCount, Defaults.contextMessageRange), forKey: Keys.contextMessageCount)
            NotificationCenter.default.post(name: JarvisConfig.liveSettingsDidChange, object: self)
        }
    }

    static let liveSettingsDidChange = Notification.Name("jarvis.liveSettingsDidChange")

    private static func clamp(_ value: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value ?? fallback, range.lowerBound), range.upperBound)
    }

    // MARK: - 组合读取

    func endpoint(for route: APIRoute) -> String {
        switch route {
        case .judge: return judgeEndpoint
        case .reply: return replyEndpoint
        case .vision: return visionEndpoint
        }
    }

    func model(for route: APIRoute) -> String {
        switch route {
        case .judge: return judgeModel
        case .reply: return replyModel
        case .vision: return visionModel
        }
    }

    /// 该路线是否已填齐可发请求的最小配置。
    func isConfigured(_ route: APIRoute) -> Bool {
        secrets.hasKey(for: route)
            && !endpoint(for: route).isEmpty
            && !model(for: route).isEmpty
    }

    /// 切换判断服务商时，把 base URL 和 model 一并换成该服务商的默认值，
    /// 避免把 OpenRouter 的模型名发到 TypeSafe。
    func applyJudgeProvider(_ provider: JudgeProvider) {
        judgeProvider = provider
        defaults.removeObject(forKey: Keys.judgeBaseURL)
        defaults.removeObject(forKey: Keys.judgeModel)
    }

    private enum Keys {
        static let judgeProvider = "jarvis.judge.provider"
        static let judgeBaseURL = "jarvis.judge.baseURL"
        static let judgeModel = "jarvis.judge.model"
        static let replyBaseURL = "jarvis.reply.baseURL"
        static let replyModel = "jarvis.reply.model"
        static let visionEnabled = "jarvis.vision.enabled"
        static let visionBaseURL = "jarvis.vision.baseURL"
        static let visionModel = "jarvis.vision.model"
        static let relationship = "jarvis.relationship"
        static let ladderCapacity = "jarvis.live.ladderCapacity"
        static let contextMessageCount = "jarvis.live.contextMessageCount"
    }

    enum Defaults {
        static let replyBaseURL = "https://openrouter.ai/api/v1"
        static let replyModel = "deepseek/deepseek-chat-v3.1"
        static let visionBaseURL = "https://openrouter.ai/api/v1"
        static let visionModel = "qwen/qwen2.5-vl-72b-instruct"
        static let relationship = "对方是我的伴侣；from=me 的是我发的，from=other 的是对方发的"
        nonisolated static let ladderCapacity = 10
        nonisolated static let ladderCapacityRange = 3...30
        nonisolated static let contextMessageCount = 10
        nonisolated static let contextMessageRange = 4...50
    }
}

private extension UserDefaults {
    /// 空白值等同未设置，让调用方落到默认值而不是拿到空串去拼 URL。
    func trimmedString(_ key: String) -> String? {
        guard let raw = string(forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func setTrimmed(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeObject(forKey: key)
        } else {
            set(trimmed, forKey: key)
        }
    }
}
