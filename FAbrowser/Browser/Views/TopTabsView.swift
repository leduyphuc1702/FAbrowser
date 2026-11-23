import UIKit

protocol TopTabsViewDelegate: AnyObject {
    func topTabsDidSelect(_ tab: Tab)
    func topTabsDidClose(_ tab: Tab)
    func topTabsDidTapAdd()
}

/// Desktop-style horizontal tab strip shown above the URL bar (iPad default, optional on iPhone).
final class TopTabsView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    weak var delegate: TopTabsViewDelegate?
    private var tabs: [Tab] = []
    private weak var selected: Tab?
    private var isPrivate = false

    private let collectionView: UICollectionView
    private let addButton = UIButton(type: .system)

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TopTabCell.self, forCellWithReuseIdentifier: "c")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        addButton.setImage(Theme.symbol("plus", size: 15, weight: .medium), for: .normal)
        addButton.addTarget(self, action: #selector(add), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            addButton.topAnchor.constraint(equalTo: topAnchor),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [Tab], selected: Tab?, isPrivate: Bool) {
        self.tabs = tabs
        self.selected = selected
        self.isPrivate = isPrivate
        backgroundColor = isPrivate ? UIColor(hex: 0x231C36) : UIColor.dynamic(light: UIColor(hex: 0xE4E5E8), dark: UIColor(hex: 0x111113))
        addButton.tintColor = isPrivate ? .white : Theme.icon
        collectionView.reloadData()
        if let s = selected, let i = tabs.firstIndex(where: { $0 === s }) {
            collectionView.scrollToItem(at: IndexPath(item: i, section: 0), at: .centeredHorizontally, animated: false)
        }
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath) as! TopTabCell
        let tab = tabs[indexPath.item]
        cell.configure(tab: tab, selected: tab === selected, isPrivate: isPrivate)
        cell.onClose = { [weak self] in self?.delegate?.topTabsDidClose(tab) }
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = cv.bounds.width
        let w = max(110, min(220, available / CGFloat(max(tabs.count, 1))))
        return CGSize(width: w, height: cv.bounds.height)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.topTabsDidSelect(tabs[indexPath.item])
    }

    @objc private func add() { delegate?.topTabsDidTapAdd() }
}

final class TopTabCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let icon = UIImageView()
    private let divider = UIView()
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 12)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 3
        icon.clipsToBounds = true
        closeButton.setImage(Theme.symbol("xmark", size: 10, weight: .semibold), for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        [icon, titleLabel, closeButton, divider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab, selected: Bool, isPrivate: Bool) {
        titleLabel.text = tab.displayTitle
        let fg: UIColor = isPrivate ? .white : Theme.text
        titleLabel.textColor = selected ? fg : fg.withAlphaComponent(0.6)
        closeButton.tintColor = fg.withAlphaComponent(0.7)
        contentView.backgroundColor = selected ? (isPrivate ? Theme.privateBarBackground : Theme.barBackground) : .clear
        divider.backgroundColor = Theme.separator
        icon.image = Theme.symbol("globe", size: 12)
        icon.tintColor = fg.withAlphaComponent(0.6)
        if tab.showingHome { icon.image = Theme.symbol("house", size: 12) }
        else if let host = tab.url?.normalizedHost, let img = FaviconManager.shared.cachedIcon(for: host) { icon.image = img }
    }

    @objc private func close() { onClose?() }
}
