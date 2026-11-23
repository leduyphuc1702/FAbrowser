import UIKit

struct GridItem {
    var title: String
    var symbol: String
    var isOn: Bool = false
    var enabled: Bool = true
    var badge: String? = nil
    var action: () -> Void
    var longPress: (() -> Void)? = nil
}

/// Bottom sheet with a paged icon grid. Used for the main menu and the toolbox.
final class GridSheetViewController: UIViewController, UIScrollViewDelegate {
    private let items: [GridItem]
    private let columns: Int
    private let rowsPerPage: Int
    private let sheetTitle: String?
    var isPrivate = false

    private let dimView = UIView()
    private let panel = UIView()
    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private var pageViews: [UIView] = []
    private var itemViews: [GridItemView] = []
    private var panelBottom: NSLayoutConstraint!
    private let rowHeight: CGFloat = 80

    init(title: String?, items: [GridItem], columns: Int = 5, rowsPerPage: Int = 2) {
        self.items = items
        self.columns = columns
        self.rowsPerPage = rowsPerPage
        self.sheetTitle = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    private var perPage: Int { columns * rowsPerPage }
    private var pageCount: Int { max(1, Int(ceil(Double(items.count) / Double(perPage)))) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        dimView.alpha = 0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        view.addSubview(dimView)
        dimView.pinEdges(to: view)

        let fg: UIColor = isPrivate ? .white : Theme.text
        panel.backgroundColor = isPrivate ? Theme.privateBarBackground : Theme.menuBackground
        panel.layer.cornerRadius = 16
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let content = UIStackView()
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)

        if let sheetTitle, !sheetTitle.isEmpty {
            let label = UILabel()
            label.text = sheetTitle
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = fg.withAlphaComponent(0.55)
            label.textAlignment = .center
            label.heightAnchor.constraint(equalToConstant: 40).isActive = true
            content.addArrangedSubview(label)
            let line = UIView()
            line.backgroundColor = isPrivate ? UIColor.white.withAlphaComponent(0.08) : Theme.separator
            line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            content.addArrangedSubview(line)
        } else {
            let spacer = UIView()
            spacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
            content.addArrangedSubview(spacer)
        }

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.heightAnchor.constraint(equalToConstant: rowHeight * CGFloat(rowsPerPage) + 10).isActive = true
        content.addArrangedSubview(scrollView)

        pageControl.numberOfPages = pageCount
        pageControl.hidesForSinglePage = true
        pageControl.currentPageIndicatorTintColor = isPrivate ? .white : Theme.accent
        pageControl.pageIndicatorTintColor = fg.withAlphaComponent(0.18)
        pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
        pageControl.heightAnchor.constraint(equalToConstant: pageCount > 1 ? 22 : 6).isActive = true
        content.addArrangedSubview(pageControl)

        let line = UIView()
        line.backgroundColor = isPrivate ? UIColor.white.withAlphaComponent(0.08) : Theme.separator
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        content.addArrangedSubview(line)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(Theme.symbol("chevron.down", size: 18, weight: .medium), for: .normal)
        closeButton.tintColor = fg.withAlphaComponent(0.7)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight).isActive = true
        content.addArrangedSubview(closeButton)

        for p in 0..<pageCount {
            let page = UIView()
            scrollView.addSubview(page)
            pageViews.append(page)
            for i in (p * perPage)..<min(items.count, (p + 1) * perPage) {
                let v = GridItemView(item: items[i], isPrivate: isPrivate)
                v.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
                v.tag = i
                if items[i].longPress != nil {
                    let lp = UILongPressGestureRecognizer(target: self, action: #selector(itemLongPressed(_:)))
                    v.addGestureRecognizer(lp)
                }
                page.addSubview(v)
                itemViews.append(v)
            }
        }

        let maxWidth = panel.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        let fullWidth = panel.widthAnchor.constraint(equalTo: view.widthAnchor)
        fullWidth.priority = .defaultHigh
        panelBottom = panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 500)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth, fullWidth, panelBottom,
            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = scrollView.bounds.width
        let h = scrollView.bounds.height
        guard w > 0 else { return }
        scrollView.contentSize = CGSize(width: w * CGFloat(pageCount), height: h)
        let cellW = (w - 16) / CGFloat(columns)
        for (p, page) in pageViews.enumerated() {
            page.frame = CGRect(x: CGFloat(p) * w, y: 0, width: w, height: h)
            for v in page.subviews.compactMap({ $0 as? GridItemView }) {
                let local = v.tag - p * perPage
                let row = local / columns, col = local % columns
                v.frame = CGRect(x: 8 + CGFloat(col) * cellW, y: 5 + CGFloat(row) * rowHeight, width: cellW, height: rowHeight)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.layoutIfNeeded()
        panelBottom.constant = 0
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.4) {
            self.dimView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv.bounds.width > 0 else { return }
        pageControl.currentPage = Int(round(sv.contentOffset.x / sv.bounds.width))
    }

    @objc private func pageChanged() {
        scrollView.setContentOffset(CGPoint(x: CGFloat(pageControl.currentPage) * scrollView.bounds.width, y: 0), animated: true)
    }

    @objc private func itemTapped(_ v: GridItemView) {
        let item = items[v.tag]
        guard item.enabled else { return }
        dismissSheet { item.action() }
    }

    @objc private func itemLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let v = g.view as? GridItemView, let lp = items[v.tag].longPress else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismissSheet { lp() }
    }

    @objc private func close() { dismissSheet(nil) }

    func dismissSheet(_ completion: (() -> Void)?) {
        panelBottom.constant = panel.bounds.height + 40
        UIView.animate(withDuration: 0.2, animations: {
            self.dimView.alpha = 0
            self.view.layoutIfNeeded()
        }) { _ in
            self.dismiss(animated: false) { completion?() }
        }
    }
}

final class GridItemView: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()
    private let badgeLabel = PaddingLabel()

    init(item: GridItem, isPrivate: Bool) {
        super.init(frame: .zero)
        let base: UIColor = isPrivate ? .white : Theme.icon
        let color: UIColor = !item.enabled ? (isPrivate ? UIColor.white.withAlphaComponent(0.3) : Theme.iconDisabled) : (item.isOn ? Theme.accent : base)
        icon.image = Theme.symbol(item.symbol, size: 22)
        icon.tintColor = color
        icon.contentMode = .center
        label.text = item.title
        label.font = .systemFont(ofSize: 11)
        label.textColor = item.enabled ? (item.isOn ? Theme.accent : (isPrivate ? UIColor.white.withAlphaComponent(0.85) : Theme.secondaryText)) : color
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        badgeLabel.insets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        badgeLabel.text = item.badge
        badgeLabel.isHidden = item.badge == nil
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        [icon, label, badgeLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.isUserInteractionEnabled = false; addSubview($0) }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 32),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badgeLabel.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -2),
            badgeLabel.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 4),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        accessibilityLabel = item.title
        accessibilityTraits = item.isOn ? [.button, .selected] : .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.45 : 1 }
    }
}
