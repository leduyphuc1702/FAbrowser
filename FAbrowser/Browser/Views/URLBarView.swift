import UIKit

protocol URLBarViewDelegate: AnyObject {
    func urlBarDidTapLocation(_ bar: URLBarView)
    func urlBarDidLongPressLocation(_ bar: URLBarView)
    func urlBarDidTapShield(_ bar: URLBarView)
    func urlBarDidTapReload(_ bar: URLBarView)
    func urlBarDidTapReader(_ bar: URLBarView)
    func urlBarDidTapCollapsed(_ bar: URLBarView)
}

/// Top location bar: [shield] [ title / domain ] [reader] [reload|stop], with a thin progress bar.
final class URLBarView: UIView {
    weak var delegate: URLBarViewDelegate?

    let locationView = UIView()
    private let shieldButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let reloadButton = UIButton(type: .system)
    private let readerButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let collapsedLabel = UILabel()
    private var expandedConstraints: [NSLayoutConstraint] = []
    private(set) var isCollapsed = false

    var isLoading = false { didSet { updateReloadIcon() } }
    var isPrivate = false { didSet { applyColors() } }
    var isSecure = true { didSet { updateShield() } }
    var showsReader = false { didSet { readerButton.isHidden = !showsReader } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        locationView.layer.cornerRadius = 9
        locationView.layer.cornerCurve = .continuous
        addSubview(locationView)
        locationView.translatesAutoresizingMaskIntoConstraints = false

        shieldButton.setImage(Theme.symbol("checkmark.shield.fill", size: 15, weight: .medium), for: .normal)
        shieldButton.addTarget(self, action: #selector(shieldTapped), for: .touchUpInside)
        shieldButton.accessibilityLabel = L("Site Settings")

        titleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.text = L("Search or Enter Address")

        readerButton.setImage(Theme.symbol("doc.plaintext", size: 15), for: .normal)
        readerButton.addTarget(self, action: #selector(readerTapped), for: .touchUpInside)
        readerButton.isHidden = true
        readerButton.accessibilityLabel = L("Reader Mode")

        reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        reloadButton.accessibilityLabel = L("Refresh")

        let tap = UITapGestureRecognizer(target: self, action: #selector(locationTapped))
        locationView.addGestureRecognizer(tap)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(locationLongPressed(_:)))
        locationView.addGestureRecognizer(lp)

        [shieldButton, titleLabel, readerButton, reloadButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            locationView.addSubview($0)
        }

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = Theme.accent
        progressView.trackTintColor = .clear
        progressView.alpha = 0
        addSubview(progressView)

        collapsedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        collapsedLabel.textAlignment = .center
        collapsedLabel.alpha = 0
        collapsedLabel.isUserInteractionEnabled = true
        collapsedLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(collapsedTapped)))
        collapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collapsedLabel)

        expandedConstraints = [
            locationView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            locationView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ]
        NSLayoutConstraint.activate(expandedConstraints + [
            locationView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            locationView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            shieldButton.leadingAnchor.constraint(equalTo: locationView.leadingAnchor, constant: 4),
            shieldButton.centerYAnchor.constraint(equalTo: locationView.centerYAnchor),
            shieldButton.widthAnchor.constraint(equalToConstant: 32),
            shieldButton.heightAnchor.constraint(equalToConstant: 32),

            reloadButton.trailingAnchor.constraint(equalTo: locationView.trailingAnchor, constant: -4),
            reloadButton.centerYAnchor.constraint(equalTo: locationView.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.heightAnchor.constraint(equalToConstant: 32),

            readerButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor),
            readerButton.centerYAnchor.constraint(equalTo: locationView.centerYAnchor),
            readerButton.widthAnchor.constraint(equalToConstant: 28),

            titleLabel.centerXAnchor.constraint(equalTo: locationView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: locationView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: shieldButton.trailingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: readerButton.leadingAnchor, constant: -2),

            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            collapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            collapsedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            collapsedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            collapsedLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateReloadIcon()
        applyColors()
    }

    func setTitle(_ text: String?, placeholder: Bool) {
        titleLabel.text = text
        titleLabel.textColor = placeholder ? Theme.secondaryText : (isPrivate ? .white : Theme.text)
        collapsedLabel.text = text
    }

    func setProgress(_ value: Float, animated: Bool) {
        if value >= 1 || value <= 0 {
            progressView.setProgress(value >= 1 ? 1 : 0, animated: animated)
            UIView.animate(withDuration: 0.25, delay: 0.15, options: []) { self.progressView.alpha = 0 } completion: { _ in
                if self.progressView.alpha == 0 { self.progressView.setProgress(0, animated: false) }
            }
        } else {
            progressView.alpha = 1
            progressView.setProgress(max(value, 0.1), animated: animated)
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        locationView.alpha = collapsed ? 0 : 1
        collapsedLabel.alpha = collapsed ? 1 : 0
    }

    private func updateReloadIcon() {
        reloadButton.setImage(Theme.symbol(isLoading ? "xmark" : "arrow.clockwise", size: 15, weight: .medium), for: .normal)
    }

    private func updateShield() {
        shieldButton.setImage(Theme.symbol(isSecure ? "checkmark.shield.fill" : "exclamationmark.shield.fill", size: 15, weight: .medium), for: .normal)
        shieldButton.tintColor = isPrivate ? Theme.privatePurple.withAlphaComponent(0.95) : (isSecure ? Theme.shieldGreen : .systemOrange)
        if isPrivate { shieldButton.setImage(Theme.symbol("eyeglasses", size: 15, weight: .medium), for: .normal); shieldButton.tintColor = .white }
    }

    private func applyColors() {
        backgroundColor = isPrivate ? Theme.privateBarBackground : Theme.barBackground
        locationView.backgroundColor = isPrivate ? Theme.privateLocationBackground : Theme.locationBackground
        reloadButton.tintColor = isPrivate ? .white : Theme.icon
        readerButton.tintColor = isPrivate ? .white : Theme.icon
        collapsedLabel.textColor = isPrivate ? .white : Theme.text
        updateShield()
    }

    @objc private func shieldTapped() { delegate?.urlBarDidTapShield(self) }
    @objc private func reloadTapped() { delegate?.urlBarDidTapReload(self) }
    @objc private func readerTapped() { delegate?.urlBarDidTapReader(self) }
    @objc private func locationTapped() { delegate?.urlBarDidTapLocation(self) }
    @objc private func collapsedTapped() { delegate?.urlBarDidTapCollapsed(self) }
    @objc private func locationLongPressed(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { delegate?.urlBarDidLongPressLocation(self) }
    }
}
