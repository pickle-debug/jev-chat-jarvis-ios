import UIKit

/// 一组"标题 + 输入框"的配置行。
final class ConfigFieldView: UIView {
    let textField = UITextField()
    private let titleLabel = UILabel()

    init(title: String, placeholder: String, isSecure: Bool = false) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true

        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = .whileEditing
        textField.accessibilityLabel = title
        if isSecure {
            textField.isSecureTextEntry = true
            textField.textContentType = .password
        } else {
            textField.keyboardType = .URL
        }

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var text: String {
        get { textField.text ?? "" }
        set { textField.text = newValue }
    }
}

/// 分区标题。
func makeSectionLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .headline)
    label.adjustsFontForContentSizeCategory = true
    label.accessibilityTraits.insert(.header)
    return label
}

/// 说明性小字。
func makeFootnoteLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.adjustsFontForContentSizeCategory = true
    return label
}
