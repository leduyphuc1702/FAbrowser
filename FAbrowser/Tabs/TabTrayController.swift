import UIKit

/// Grid of tab cards with a bottom tray toolbar: [Private] [+] [Done].
final class TabTrayController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    private let tabManager: TabManager
    private var showingPrivate: Bool
    private var collectionView: UICollectionView!
    private let trayToolbar = UIView()
    private let privateButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let emptyLabel = UILabel()

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        self.showingPrivate = tabManager.isPrivate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tabs: [Tab] { tabManager.tabs(private: showingPrivate) }

    override var preferredStatusBarStyle: UIStatusBarStyle { showingPrivate ? .lightContent : .default }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 14
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(TabCardCell.self, forCellWithReuseIdentifier: "tab")

        emptyLabel.text = L("Private Browsing") + "\n\n" + L("FAbrowser won't remember any of your history or cookies, but new bookmarks will be saved.")
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        privateButton.setTitle(L("Private"), for: .normal)
        privateButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        privateButton.addTarget(self, action: #selector(togglePrivate), for: .touchUpInside)
        addButton.setImage(Theme.symbol("plus", size: 22, weight: .medium), for: .normal)
        addButton.addTarget(self, action: #selector(addTab), for: .touchUpInside)
        doneButton.setTitle(L("Done"), for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(doneLongPress(_:)))
        doneButton.addGestureRecognizer(lp)

        let row = UIStackView(arrangedSubviews: [privateButton, addButton, doneButton])
        row.distribution = .fillEqually

        [collectionView, emptyLabel, trayToolbar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        trayToolbar.addSubview(row)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: trayToolbar.topAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            trayToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trayToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trayToolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            row.topAnchor.constraint(equalTo: trayToolbar.topAnchor),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),
            row.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        applyMode()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let sel = tabManager.selectedTab, let i = tabs.firstIndex(where: { $0 === sel }) {
            collectionView.scrollToItem(at: IndexPath(item: i, section: 0), at: .centeredVertically, animated: false)
        }
    }

    private func applyMode() {
        view.backgroundColor = showingPrivate ? Theme.privateTrayBackground : Theme.trayBackground
        trayToolbar.backgroundColor = showingPrivate ? Theme.privateBarBackground : Theme.barBackground
        let fg: UIColor = showingPrivate ? .white : Theme.icon
        addButton.tintColor = fg
        doneButton.tintColor = showingPrivate ? .white : Theme.accent
        privateButton.tintColor = showingPrivate ? .white : Theme.icon
        privateButton.backgroundColor = .clear
        var cfg = UIButton.Configuration.plain()
        cfg.title = L("Private")
        cfg.baseForegroundColor = showingPrivate ? Theme.privateBarBackground : Theme.icon
        if showingPrivate {
            cfg = UIButton.Configuration.filled()
            cfg.title = L("Private")
            cfg.baseBackgroundColor = .white
            cfg.baseForegroundColor = Theme.privateBarBackground
            cfg.cornerStyle = .medium
        }
        privateButton.configuration = cfg
        emptyLabel.isHidden = !(showingPrivate && tabs.isEmpty)
        collectionView.reloadData()
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func togglePrivate() {
        showingPrivate.toggle()
        UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve) { self.applyMode() }
    }

    @objc private func addTab() {
        tabManager.addTab(url: nil, isPrivate: showingPrivate, select: true, afterCurrent: false)
        dismiss(animated: true)
    }

    @objc private func done() {
        if let sel = tabManager.selectedTab, sel.isPrivate != showingPrivate {
            if let t = tabs.max(by: { $0.lastActive < $1.lastActive }) { tabManager.selectTab(t) }
            else { tabManager.addTab(url: nil, isPrivate: showingPrivate) }
        }
        dismiss(animated: true)
    }

    @objc private func doneLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        closeAllPrompt()
    }

    private func closeAllPrompt() {
        let sheet = UIAlertController(title: nil, message: L("clear_all_tabs_hint"), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: showingPrivate ? L("Close All and Exit Private") : L("Close All Tabs"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.tabManager.removeAll(private: self.showingPrivate)
            self.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: doneButton)
    }

    private func close(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasLastNormal = !showingPrivate && tabs.count == 1
        tabManager.removeTab(tab)
        if wasLastNormal { dismiss(animated: true); return }
        collectionView.performBatchUpdates({ collectionView.deleteItems(at: [IndexPath(item: idx, section: 0)]) })
        emptyLabel.isHidden = !(showingPrivate && tabs.isEmpty)
        collectionView.reloadData()
    }

    // MARK: Collection

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "tab", for: indexPath) as! TabCardCell
        let tab = tabs[indexPath.item]
        cell.configure(tab: tab, selected: tab === tabManager.selectedTab)
        cell.onClose = { [weak self] in self?.close(tab) }
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let cols: CGFloat = cv.bounds.width > 700 ? 4 : (cv.bounds.width > 500 ? 3 : 2)
        let w = floor((cv.bounds.width - 28 - (cols - 1) * 12) / cols)
        return CGSize(width: w, height: w * 1.32)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        tabManager.selectTab(tabs[indexPath.item])
        dismiss(animated: true)
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let tab = tabs[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: L("Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self.tabManager.duplicate(tab); self.collectionView.reloadData()
                },
                UIAction(title: L("Copy URL"), image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.string = (tab.webView?.url ?? tab.url)?.absoluteString
                },
                UIAction(title: L("Close All Except This"), image: UIImage(systemName: "xmark.square")) { _ in
                    self.tabManager.removeAll(private: tab.isPrivate, except: tab); self.collectionView.reloadData()
                },
                UIAction(title: L("Close Right Tabs"), image: UIImage(systemName: "arrow.right.to.line")) { _ in
                    self.tabManager.removeTabs(rightOf: tab); self.collectionView.reloadData()
                },
            ]
            actions.append(UIAction(title: L("Close Tab"), image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in self.close(tab) })
            return UIMenu(children: actions)
        }
    }

    func collectionView(_ cv: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = tabs[indexPath.item]
        return [item]
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath dest: IndexPath?) -> UICollectionViewDropProposal {
        session.localDragSession != nil ? UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath) : UICollectionViewDropProposal(operation: .forbidden)
    }

    func collectionView(_ cv: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dest = coordinator.destinationIndexPath, let item = coordinator.items.first, let src = item.sourceIndexPath,
              let tab = item.dragItem.localObject as? Tab else { return }
        let to = min(dest.item, tabs.count - 1)
        tabManager.moveTab(tab, toIndexInMode: to)
        cv.performBatchUpdates({ cv.moveItem(at: src, to: IndexPath(item: to, section: 0)) })
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: to, section: 0))
    }
}

final class TabCardCell: UICollectionViewCell {
    private let header = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let screenshot = UIImageView()
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.backgroundColor = Theme.cardBackground
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 3
        icon.clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.setImage(Theme.symbol("xmark", size: 11, weight: .bold), for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        screenshot.contentMode = .scaleAspectFill
        screenshot.clipsToBounds = true
        screenshot.backgroundColor = Theme.homeBackground

        [header, screenshot].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        [icon, titleLabel, closeButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            screenshot.topAnchor.constraint(equalTo: header.bottomAnchor),
            screenshot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            screenshot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            screenshot.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab, selected: Bool) {
        titleLabel.text = tab.displayTitle
        let isPrivate = tab.isPrivate
        header.backgroundColor = selected ? (isPrivate ? Theme.privatePurple : Theme.accent) : (isPrivate ? Theme.privateBarBackground : Theme.cardBackground)
        let fg: UIColor = selected || isPrivate ? .white : Theme.text
        titleLabel.textColor = fg
        closeButton.tintColor = fg.withAlphaComponent(0.85)
        icon.tintColor = fg
        if tab.showingHome { icon.image = Theme.symbol("house.fill", size: 12) }
        else if let host = (tab.webView?.url ?? tab.url)?.normalizedHost, let img = FaviconManager.shared.cachedIcon(for: host) { icon.image = img }
        else { icon.image = Theme.symbol("globe", size: 12) }
        screenshot.image = tab.screenshot
        contentView.layer.borderWidth = selected ? 2 : 0
        contentView.layer.borderColor = (isPrivate ? Theme.privatePurple : Theme.accent).cgColor
    }

    @objc private func close() { onClose?() }
}
