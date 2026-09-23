import UIKit

/// 画中画内容：三行，只读。PiP 窗口约 414×80pt，内容是视频像素，不能点击。
///
///     Jarvis · 小王 · 危险 6/9                 ← 会话、识别状态、危险程度（颜色）
///     Jarvis 判断：在试探你是否在乎 → 需要关心    ← Jev 判断结论
///     Jarvis ↑ 上滑聊天记录，补到 10 条再判断      ← 需要上下文时的提示 / 候选已就绪 / 当前状态
///
/// 每行都以 “Jarvis” 开头：引擎在 OCR 结果里找到这个标记后，把整块画中画区域从聊天识别中排除。
@MainActor
final class JarvisPiPView: UIView {
    private let statusLabel = UILabel()
    private let judgeLabel = UILabel()
    private let actionLabel = UILabel()
    private let badge = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        badge.layer.cornerRadius = 4
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        judgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        actionLabel.font = .systemFont(ofSize: 13)
        for label in [statusLabel, judgeLabel, actionLabel] {
            label.textColor = .black
            // 单行截断：换行会让画中画文字被 OCR 成不以标记开头的碎片。
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        let stack = UIStackView(arrangedSubviews: [statusLabel, judgeLabel, actionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(stack)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.widthAnchor.constraint(equalToConstant: 5),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        show(status: "Jarvis · 待命", judge: "Jarvis 开始录屏后，打开聊天窗口即可", action: "Jarvis 对方发来新消息时自动判断", tone: .neutral)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    enum Tone { case neutral, calm, warn, danger, prompt }

    func show(status: String, judge: String, action: String, tone: Tone) {
        statusLabel.text = status
        judgeLabel.text = judge
        actionLabel.text = action
        let color: UIColor
        switch tone {
        case .neutral: color = .systemGray3
        case .calm: color = .systemGreen
        case .warn: color = .systemOrange
        case .danger: color = .systemRed
        case .prompt: color = .systemBlue
        }
        badge.backgroundColor = color
        actionLabel.textColor = tone == .prompt ? .systemBlue : .black
        actionLabel.font = .systemFont(ofSize: 13, weight: tone == .prompt ? .semibold : .regular)
    }
}

/// Jev 判断键 → 画中画里能一眼看懂的中文。
enum JudgeLabels {
    static func intent(_ key: String) -> String {
        [
            "confirm_you_care": "在试探你是否在乎",
            "vent_anger": "在发泄情绪",
            "request_action": "要你给出行动/答复",
            "seek_explanation": "想要一个解释",
            "casual_chat": "轻松闲聊",
            "close_topic": "话题可以收尾"
        ][key] ?? key
    }

    static func need(_ key: String) -> String {
        [
            "apology": "需要道歉",
            "action": "需要具体行动",
            "explanation": "需要解释",
            "care": "需要关心",
            "nothing": "不需要更多"
        ][key] ?? key
    }

    static func action(_ key: String) -> String {
        [
            "check_history": "先翻聊天记录再回",
            "apologize": "先真诚道歉",
            "give_commitment": "给出具体承诺",
            "explain": "解释清楚原因",
            "acknowledge": "先回应感受",
            "say_less": "少说为好",
            "make_plan": "直接约定安排"
        ][key] ?? key
    }

    /// 一句话判断：意图 → 需要 · 建议。
    static func summary(_ analysis: Analysis) -> String {
        var parts: [String] = []
        if let intent = analysis.trueIntent { parts.append(Self.intent(intent.choice)) }
        if let need = analysis.sheNeeds { parts.append(Self.need(need.choice)) }
        var text = parts.joined(separator: " → ")
        if let action = analysis.bestAction { text += (text.isEmpty ? "" : " · ") + "建议" + Self.action(action.choice) }
        return text.isEmpty ? "判断接口未返回结论" : text
    }
}
