import UIKit

/// Jarvis 键盘：只读主 App 写好的候选，自绘三个按钮，点击后 `insertText`（架构文档 §8）。
///
/// 不是完整输入法：需要改字时用地球键切回原来的中文输入法。不联网、不持有密钥、不读屏幕。
/// 顶部文字固定以 “Jarvis 键盘” 开头：主 App 录屏识别到它就知道下方是键盘区，不会把候选当成聊天内容。
final class KeyboardViewController: UIInputViewController {
    private let headerLabel = UILabel()
    private let noteLabel = UILabel()
    private let candidateStack = UIStackView()
    private let confirmButton = UIButton(type: .system)
    private var switchButton: UIButton?

    private var bundle: ReplyBundle?
    private var lastModified: Date?
    private var timer: Timer?
    /// 用户确认过“就是这个会话”的 bundleID + 文档标识。只存在键盘内存里。
    private var confirmedKey: String?
    private var pendingReplace: (candidateID: String, until: Date)?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 每次键盘重新出现都要重新确认来源：输入框可能已经换成另一个联系人。
        confirmedKey = nil
        reload(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: false) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        render()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        render()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        switchButton?.isHidden = !needsInputModeSwitchKey
    }

    // MARK: - 数据

    /// 文件变化时重新读取；没变也要重新渲染，让过期在屏幕上及时体现。
    private func reload(force: Bool) {
        let modified = ReplyBundleStore.modificationDate()
        if force || modified != lastModified {
            lastModified = modified
            let next = ReplyBundleStore.load()
            if next?.bundleID != bundle?.bundleID { confirmedKey = nil; pendingReplace = nil }
            bundle = next
        }
        render()
    }

    private var confirmationKey: String? {
        guard let bundle else { return nil }
        return "\(bundle.bundleID)|\(textDocumentProxy.documentIdentifier.uuidString)"
    }

    private var usableBundle: ReplyBundle? {
        guard let bundle, bundle.isUsable() else { return nil }
        return bundle
    }

    // MARK: - 渲染

    private func render() {
        candidateStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let bundle = usableBundle else {
            headerLabel.text = "Jarvis 键盘 · 暂无可用建议"
            noteLabel.text = unavailableReason()
            confirmButton.isHidden = true
            for _ in 0..<3 { candidateStack.addArrangedSubview(placeholderRow()) }
            return
        }
        let age = max(0, Int(Date().timeIntervalSince(bundle.generatedAt)))
        headerLabel.text = "Jarvis 键盘 · 来源：\(bundle.sourceTitle) · \(age < 5 ? "刚刚" : "\(age) 秒前")"
        let confirmed = confirmedKey == confirmationKey
        confirmButton.isHidden = confirmed
        confirmButton.setTitle("确认是和「\(bundle.sourceTitle)」的聊天", for: .normal)
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            noteLabel.text = "已选中文字：点候选会替换选中内容，需再点一次确认"
        } else if !confirmed {
            noteLabel.text = "先确认当前输入框就是这个会话，再点候选插入。\(bundle.summary.map { "判断：\($0)" } ?? "")"
        } else {
            noteLabel.text = bundle.summary.map { "判断：\($0)" } ?? "从上到下推荐程度由低到高"
        }
        for candidate in bundle.candidates.sorted(by: { $0.rank < $1.rank }) {
            candidateStack.addArrangedSubview(candidateRow(candidate, enabled: confirmed))
        }
    }

    private func unavailableReason() -> String {
        guard let bundle else { return "打开 Jarvis 开始录屏，在聊天窗口停留片刻后回来。" }
        if bundle.status == .invalid { return bundle.note ?? "会话已变化，等待新的建议。" }
        if Date() >= bundle.validUntil || Date() >= bundle.expiresAt { return "建议已过期：会话可能已更新，回到 Jarvis 画中画查看最新状态。" }
        return "建议不完整，已禁用插入。"
    }

    private func candidateRow(_ candidate: ReplyBundle.Candidate, enabled: Bool) -> UIView {
        let button = UIButton(type: .system)
        let marker = ["①", "②", "③"][max(0, min(2, candidate.rank - 1))]
        let top = candidate.rank == 3
        var config = UIButton.Configuration.filled()
        config.title = "\(marker) \(candidate.text)"
        config.subtitle = top ? "优先推荐" : (candidate.rank == 1 ? "推荐程度较低" : nil)
        config.titleLineBreakMode = .byTruncatingTail
        config.baseBackgroundColor = top ? UIColor.systemIndigo.withAlphaComponent(0.18) : .secondarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.titleAlignment = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 15, weight: top ? .semibold : .regular)
            return attributes
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 11)
            attributes.foregroundColor = .secondaryLabel
            return attributes
        }
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.isEnabled = enabled
        button.titleLabel?.numberOfLines = 2
        // 绑定候选 ID 与文本，点击时重新读文件确认没有被替换成另一条。
        let id = candidate.id, text = candidate.text
        button.addAction(UIAction { [weak self] _ in self?.insert(candidateID: id, text: text) }, for: .touchUpInside)
        return button
    }

    private func placeholderRow() -> UIView {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.5)
        view.layer.cornerRadius = 8
        return view
    }

    // MARK: - 插入

    private func insert(candidateID: String, text: String) {
        // 点击时重新读取共享文件，确认版本仍然一致。
        let latest = ReplyBundleStore.load()
        guard let shown = bundle, let latest, latest.isUsable(), latest.bundleID == shown.bundleID,
              latest.sessionID == shown.sessionID, latest.conversationID == shown.conversationID,
              latest.revision == shown.revision, latest.analysisRequestID == shown.analysisRequestID,
              latest.candidates.contains(where: { $0.id == candidateID && $0.text == text })
        else {
            noteLabel.text = "建议已更新，请点“刷新”后再选"
            reload(force: true)
            return
        }
        guard confirmedKey == confirmationKey else { return }
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            if pendingReplace?.candidateID != candidateID || (pendingReplace?.until ?? .distantPast) < Date() {
                pendingReplace = (candidateID, Date().addingTimeInterval(3))
                noteLabel.text = "再点一次这条候选，替换选中的文字"
                return
            }
        }
        pendingReplace = nil
        textDocumentProxy.insertText(text)
        noteLabel.text = "已插入，请在聊天 App 里检查后自己发送"
    }

    // MARK: - 布局

    private func buildLayout() {
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabel
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 2
        confirmButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        confirmButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            confirmedKey = confirmationKey
            render()
        }, for: .touchUpInside)

        candidateStack.axis = .vertical
        candidateStack.spacing = 6
        candidateStack.distribution = .fillEqually

        let globe = controlButton("globe", label: "切换输入法")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        switchButton = globe
        let refresh = controlButton("arrow.clockwise", label: "刷新")
        refresh.addAction(UIAction { [weak self] _ in self?.reload(force: true) }, for: .touchUpInside)
        let delete = controlButton("delete.left", label: "删除")
        delete.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.deleteBackward() }, for: .touchUpInside)
        let newline = controlButton("return", label: "换行")
        newline.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.insertText("\n") }, for: .touchUpInside)
        let dismiss = controlButton("keyboard.chevron.compact.down", label: "收起键盘")
        dismiss.addAction(UIAction { [weak self] _ in self?.dismissKeyboard() }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [globe, refresh, UIView(), delete, newline, dismiss])
        controls.spacing = 8
        controls.alignment = .center

        let headerRow = UIStackView(arrangedSubviews: [headerLabel, UIView(), confirmButton])
        headerRow.alignment = .center
        headerRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [headerRow, noteLabel, candidateStack, controls])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let height = view.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func controlButton(_ symbol: String, label: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.image = UIImage(systemName: symbol)
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return button
    }
}
