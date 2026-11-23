import UIKit

/// Find in Page bar: [field] [1/5] [up] [down] [Done]
final class FindInPageBar: UIView, UITextFieldDelegate {
    var onSearch: ((String) -> Void)?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?

    let field = UITextField()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.barBackground
        let line = UIView()
        line.backgroundColor = Theme.separator

        field.placeholder = L("Find in Page")
        field.borderStyle = .none
        field.backgroundColor = Theme.locationBackground
        field.layer.cornerRadius = 8
        field.font = .systemFont(ofSize: 15)
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.leftViewMode = .always
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.delegate = self
        field.addTarget(self, action: #selector(changed), for: .editingChanged)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = Theme.secondaryText
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let up = UIButton(type: .system)
        up.setImage(Theme.symbol("chevron.up", size: 17), for: .normal)
        up.addTarget(self, action: #selector(stepPrev), for: .touchUpInside)
        let down = UIButton(type: .system)
        down.setImage(Theme.symbol("chevron.down", size: 17), for: .normal)
        down.addTarget(self, action: #selector(stepNext), for: .touchUpInside)
        let done = UIButton(type: .system)
        done.setTitle(L("Done"), for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        [up, down].forEach { $0.tintColor = Theme.icon; $0.widthAnchor.constraint(equalToConstant: 36).isActive = true }

        let stack = UIStackView(arrangedSubviews: [field, countLabel, up, down, done])
        stack.spacing = 6
        stack.alignment = .center
        [stack, line].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            field.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCount(current: Int, total: Int) {
        countLabel.text = field.text?.isEmpty == false ? "\(current)/\(total)" : ""
    }

    @objc private func changed() { onSearch?(field.text ?? "") }
    @objc private func stepPrev() { onStep?(-1) }
    @objc private func stepNext() { onStep?(1) }
    @objc private func close() { onClose?() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onStep?(1)
        return false
    }
}

/// Floating page up/down buttons on the right edge.
final class PageUpDownBar: UIView {
    var onPage: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let up = makeButton("chevron.up", -1)
        let down = makeButton("chevron.down", 1)
        let stack = UIStackView(arrangedSubviews: [up, down])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ symbol: String, _ dir: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(Theme.symbol(symbol, size: 16, weight: .semibold), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        b.layer.cornerRadius = 20
        b.tag = dir
        b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    @objc private func tap(_ b: UIButton) { onPage?(b.tag) }
}

/// Bar shown while picking an element to hide.
final class ElementPickerBar: UIView {
    var onExpand: (() -> Void)?
    var onHide: (() -> Void)?
    var onDone: (() -> Void)?
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x1F1F22)
        layer.cornerRadius = 14
        hint.text = L("Long press element to hide")
        hint.textColor = UIColor.white.withAlphaComponent(0.75)
        hint.font = .systemFont(ofSize: 12)
        hint.textAlignment = .center

        func button(_ title: String, _ color: UIColor, _ sel: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(color, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            b.addTarget(self, action: sel, for: .touchUpInside)
            return b
        }
        let row = UIStackView(arrangedSubviews: [
            button(L("Expand"), .white, #selector(expand)),
            button(L("Hide Element"), UIColor(hex: 0xFF6B6B), #selector(hide)),
            button(L("Done"), UIColor(hex: 0x4A90FF), #selector(done)),
        ])
        row.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [hint, row])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self, insets: UIEdgeInsets(top: 10, left: 10, bottom: 8, right: 10))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHint(_ s: String) { hint.text = s }

    @objc private func expand() { onExpand?() }
    @objc private func hide() { onHide?() }
    @objc private func done() { onDone?() }
}

/// "Failed to load. Click to try again"
final class ErrorPageView: UIView {
    var onRetry: (() -> Void)?
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.homeBackground
        let icon = UIImageView(image: Theme.symbol("wifi.exclamationmark", size: 54, weight: .light))
        icon.tintColor = Theme.iconDisabled
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.text = L("Failed to load. Click to try again")
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = Theme.secondaryText
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        let retry = UIButton(type: .system)
        retry.setTitle(L("Try again"), for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(error: Error, url: URL?) {
        detailLabel.text = [url?.host, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
    }

    @objc private func retryTapped() { onRetry?() }
}
