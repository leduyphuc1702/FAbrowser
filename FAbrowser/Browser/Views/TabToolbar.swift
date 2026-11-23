import UIKit

protocol TabToolbarDelegate: AnyObject {
    func toolbarDidTapBack()
    func toolbarDidLongPressBack()
    func toolbarDidTapForward()
    func toolbarDidLongPressForward()
    func toolbarDidTapMenu()
    func toolbarDidLongPressMenu()
    func toolbarDidTapTabs()
    func toolbarDidLongPressTabs()
    func toolbarDidTapHome()
    func toolbarDidLongPressHome()
}

/// The square tab counter used by the tabs button.
final class TabCountButton: UIButton {
    private let box = UIView()
    private let countLabel = UILabel()

    var count: Int = 1 {
        didSet { countLabel.text = count > 99 ? ":D" : "\(count)" }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.isUserInteractionEnabled = false
        box.layer.borderWidth = 1.8
        box.layer.cornerRadius = 4
        box.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11, weight: .bold)
        countLabel.textAlignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(countLabel)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 21),
            box.heightAnchor.constraint(equalToConstant: 21),
            countLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        count = 1
        accessibilityLabel = L("Tab Switch Button")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        box.layer.borderColor = tintColor.cgColor
        countLabel.textColor = tintColor
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.4 : 1 } }
}

/// Bottom bar: Back · Forward · Menu · Tabs · Home (Home/Tabs can be swapped in settings).
final class TabToolbar: UIView {
    weak var delegate: TabToolbarDelegate?

    let backButton = UIButton(type: .system)
    let forwardButton = UIButton(type: .system)
    let menuButton = UIButton(type: .system)
    let tabsButton = TabCountButton()
    let homeButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let topLine = UIView()

    var isPrivate = false { didSet { applyColors() } }
    var nextPageAvailable = false { didSet { applyColors() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        configure(backButton, "chevron.backward", L("Back"), #selector(back), #selector(backLong(_:)))
        configure(forwardButton, "chevron.forward", L("Forward"), #selector(forward), #selector(forwardLong(_:)))
        configure(menuButton, "line.3.horizontal", L("Menu Button"), #selector(menu), #selector(menuLong(_:)))
        configure(tabsButton, nil, L("Tab Switch Button"), #selector(tabs), #selector(tabsLong(_:)))
        configure(homeButton, "house", L("Homepage Button"), #selector(home), #selector(homeLong(_:)))
        arrange()

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func arrange() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let order: [UIView] = Prefs.swapHomeAndTab
            ? [backButton, forwardButton, menuButton, homeButton, tabsButton]
            : [backButton, forwardButton, menuButton, tabsButton, homeButton]
        order.forEach { stack.addArrangedSubview($0) }
    }

    private func configure(_ b: UIButton, _ symbol: String?, _ label: String, _ tap: Selector, _ long: Selector) {
        if let symbol { b.setImage(Theme.symbol(symbol, size: 20, weight: .regular), for: .normal) }
        b.accessibilityLabel = label
        b.addTarget(self, action: tap, for: .touchUpInside)
        let lp = UILongPressGestureRecognizer(target: self, action: long)
        lp.minimumPressDuration = 0.4
        b.addGestureRecognizer(lp)
    }

    func update(canGoBack: Bool, canGoForward: Bool, tabCount: Int) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward || nextPageAvailable
        tabsButton.count = tabCount
        applyColors()
    }

    private func applyColors() {
        backgroundColor = isPrivate ? Theme.privateBarBackground : Theme.barBackground
        topLine.backgroundColor = isPrivate ? UIColor.white.withAlphaComponent(0.1) : Theme.separator
        let tint: UIColor = isPrivate ? .white : Theme.icon
        [backButton, menuButton, tabsButton, homeButton].forEach { $0.tintColor = tint }
        forwardButton.tintColor = nextPageAvailable ? Theme.nextPageGreen : tint
    }

    @objc private func back() { delegate?.toolbarDidTapBack() }
    @objc private func forward() { delegate?.toolbarDidTapForward() }
    @objc private func menu() { delegate?.toolbarDidTapMenu() }
    @objc private func tabs() { delegate?.toolbarDidTapTabs() }
    @objc private func home() { delegate?.toolbarDidTapHome() }
    @objc private func backLong(_ g: UIGestureRecognizer) { if g.state == .began { haptic(); delegate?.toolbarDidLongPressBack() } }
    @objc private func forwardLong(_ g: UIGestureRecognizer) { if g.state == .began { haptic(); delegate?.toolbarDidLongPressForward() } }
    @objc private func menuLong(_ g: UIGestureRecognizer) { if g.state == .began { haptic(); delegate?.toolbarDidLongPressMenu() } }
    @objc private func tabsLong(_ g: UIGestureRecognizer) { if g.state == .began { haptic(); delegate?.toolbarDidLongPressTabs() } }
    @objc private func homeLong(_ g: UIGestureRecognizer) { if g.state == .began { haptic(); delegate?.toolbarDidLongPressHome() } }

    private func haptic() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}
