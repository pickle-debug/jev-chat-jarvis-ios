import UIKit
import VisynCapture

final class ViewController: UIViewController {
    private var capture: VisynCaptureController?
    private let statusLabel = UILabel()
    private let frameLabel = UILabel()
    private let errorLabel = UILabel()
    private let recordButton = UIButton(configuration: .filled())
    private let pipButton = UIButton(configuration: .tinted())
    private let analysisButton = UIButton(configuration: .tinted())
    private let settingsButton = UIButton(configuration: .gray())
    private var receivedFrames = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHome()
        configureCapture()
    }

    private func configureCapture() {
        do {
            let capture = try VisynCaptureController(
                configuration: .load(),
                pictureInPictureContent: makePiPContent()
            )
            self.capture = capture
            capture.onStateChange = { [weak self] state in
                guard let self else { return }
                recordButton.configuration?.title = state == .stopped ? "开始录屏" : "停止录屏"
                switch state {
                case .broadcasting:
                    statusLabel.text = "正在采集屏幕"
                case .paused:
                    statusLabel.text = "录屏已暂停"
                case .stopped:
                    statusLabel.text = "录屏已停止"
                    receivedFrames = 0
                    frameLabel.text = "等待屏幕数据"
                }
            }
            capture.onFrame = { [weak self] frame in
                guard let self else { return }
                receivedFrames += 1
                frameLabel.text = "已收到 \(receivedFrames) 帧 · \(frame.width) × \(frame.height)"
            }
            capture.onPictureInPictureChange = { [weak self] active in
                self?.pipButton.configuration?.title = active ? "关闭画中画" : "开启画中画"
            }
            capture.onError = { [weak self] error in
                self?.errorLabel.text = error.localizedDescription
                self?.errorLabel.isHidden = false
            }
            capture.prepare(on: view)
        } catch {
            statusLabel.text = "暂时无法启动"
            errorLabel.text = error.localizedDescription
            errorLabel.isHidden = false
            recordButton.isEnabled = false
            pipButton.isEnabled = false
        }
    }

    private func buildHome() {
        view.backgroundColor = .systemBackground
        view.tintColor = .systemIndigo

        let titleLabel = UILabel()
        titleLabel.text = "Jarvis"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.accessibilityTraits.insert(.header)
        let subtitleLabel = UILabel()
        subtitleLabel.text = "从这里开始，连接你的屏幕。"
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        statusLabel.text = "准备就绪"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        frameLabel.text = "等待屏幕数据"
        frameLabel.font = .preferredFont(forTextStyle: .subheadline)
        frameLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        recordButton.configuration?.title = "开始录屏"
        recordButton.configuration?.image = UIImage(systemName: "record.circle")
        recordButton.configuration?.baseBackgroundColor = .systemIndigo
        recordButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            errorLabel.isHidden = true
            capture?.showBroadcastPicker(on: view)
        }, for: .touchUpInside)
        pipButton.configuration?.title = "开启画中画"
        pipButton.configuration?.image = UIImage(systemName: "pip")
        pipButton.addAction(UIAction { [weak self] _ in
            self?.errorLabel.isHidden = true
            self?.capture?.togglePictureInPicture()
        }, for: .touchUpInside)
        analysisButton.configuration?.title = "手动分析"
        analysisButton.configuration?.image = UIImage(systemName: "sparkles")
        analysisButton.addAction(UIAction { [weak self] _ in
            self?.present(AnalysisViewController())
        }, for: .touchUpInside)
        settingsButton.configuration?.title = "BYOK 设置"
        settingsButton.configuration?.image = UIImage(systemName: "key")
        settingsButton.addAction(UIAction { [weak self] _ in
            self?.present(SettingsViewController())
        }, for: .touchUpInside)
        for button in [recordButton, pipButton, analysisButton, settingsButton] {
            button.configuration?.imagePadding = 10
            button.configuration?.cornerStyle = .large
            button.configuration?.contentInsets = .init(top: 16, leading: 20, bottom: 16, trailing: 20)
        }
        let hintLabel = UILabel()
        hintLabel.text = "录屏的开始与停止都需要在系统面板中确认。画中画可在切换 App 后继续显示。"
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        for label in [titleLabel, subtitleLabel, statusLabel, frameLabel, errorLabel, hintLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let stack = UIStackView(arrangedSubviews: [
            titleLabel, subtitleLabel, statusLabel, frameLabel,
            errorLabel, recordButton, pipButton, analysisButton, settingsButton, hintLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(36, after: subtitleLabel)
        stack.setCustomSpacing(8, after: statusLabel)
        stack.setCustomSpacing(28, after: frameLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        ])
    }

    private func makePiPContent() -> UIView {
        let label = UILabel()
        label.text = "测试中"
        label.font = .systemFont(ofSize: 22, weight: .medium)
        label.textAlignment = .center
        label.textColor = .black
        label.backgroundColor = .white
        return label
    }

    /// 主页是 storyboard 里的裸 view controller，没有导航栈，
    /// 所以包一层 UINavigationController 来拿到标题栏和关闭按钮。
    private func present(_ viewController: UIViewController) {
        let navigation = UINavigationController(rootViewController: viewController)
        viewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak navigation] _ in
                navigation?.dismiss(animated: true)
            }
        )
        present(navigation, animated: true)
    }
}
