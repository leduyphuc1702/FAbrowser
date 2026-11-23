import UIKit

protocol HomePageDelegate: AnyObject {
    func homePage(_ vc: HomePageViewController, didSelect url: URL)
    func homePageDidRequestSearch(_ vc: HomePageViewController)
    func homePage(_ vc: HomePageViewController, openInNewTab url: URL, background: Bool)
    func homePageDidRequestScan(_ vc: HomePageViewController)
}

enum Wallpaper {
    static var url: URL { FileManager.default.appSupportURL.appendingPathComponent("wallpaper.jpg") }
    static var image: UIImage? { UIImage(contentsOfFile: url.path) }
    static func set(_ image: UIImage?) {
        if let image, let data = image.jpegData(compressionQuality: 0.85) { try? data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        NotificationCenter.default.post(name: .prefsChanged, object: "wallpaperAlpha")
    }
}

/// Navigation homepage: optional wallpaper, centered search box and a grid of site shortcuts.
final class HomePageViewController: UIViewController {
    weak var delegate: HomePageDelegate?

    private let wallpaperView = UIImageView()
    private let maskView = UIView()
    private var collectionView: UICollectionView!
    private let bottomSearchButton = UIButton(type: .system)
    private var sites: [HomeSite] = []
    private var pullTriggered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.homeBackground

        wallpaperView.contentMode = .scaleAspectFill
        wallpaperView.clipsToBounds = true
        view.addSubview(wallpaperView)
        wallpaperView.pinEdges(to: view)
        maskView.backgroundColor = .black
        view.addSubview(maskView)
        maskView.pinEdges(to: view)

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 8, left: 14, bottom: 90, right: 14)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(HomeSiteCell.self, forCellWithReuseIdentifier: "site")
        collectionView.register(HomeHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        view.addSubview(collectionView)
        collectionView.pinEdges(to: view)

        var cfg = UIButton.Configuration.filled()
        cfg.image = Theme.symbol("magnifyingglass", size: 15, weight: .semibold)
        cfg.title = L("Search")
        cfg.imagePadding = 6
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = Theme.cardBackground
        cfg.baseForegroundColor = Theme.icon
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 22)
        bottomSearchButton.configuration = cfg
        bottomSearchButton.layer.shadowColor = UIColor.black.cgColor
        bottomSearchButton.layer.shadowOpacity = 0.12
        bottomSearchButton.layer.shadowRadius = 8
        bottomSearchButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        bottomSearchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        bottomSearchButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomSearchButton)
        NSLayoutConstraint.activate([
            bottomSearchButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomSearchButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged), name: .bookmarksChanged, object: nil)
        reload()
    }

    @objc private func dataChanged() { reload() }

    func reload() {
        guard isViewLoaded else { return }
        sites = BookmarkStore.shared.homeSites
        let wp = Wallpaper.image
        wallpaperView.image = wp
        wallpaperView.isHidden = wp == nil
        maskView.isHidden = wp == nil
        maskView.alpha = CGFloat(Prefs.wallpaperAlpha)
        bottomSearchButton.isHidden = !Prefs.bottomSearchButton
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
    }

    @objc private func searchTapped() { delegate?.homePageDidRequestSearch(self) }

    private func addSite() {
        promptText(L("New Bookmark"), placeholders: [L("Title"), "URL"], values: ["", "https://"], keyboard: .URL) { values in
            let title = values[0].trimmed
            guard let url = URL.fromUserInput(values[1]) else { Toast.show(L("Invalid URL")); return }
            BookmarkStore.shared.addHomeSite(HomeSite(title: title.isEmpty ? url.displayString : title, url: url.absoluteString))
        }
    }

    private func edit(_ site: HomeSite) {
        promptText(L("Edit Bookmark"), placeholders: [L("Title"), "URL"], values: [site.title, site.url], keyboard: .URL) { values in
            var s = site
            s.title = values[0].trimmed.isEmpty ? site.title : values[0].trimmed
            if let u = URL.fromUserInput(values[1]) ?? URL(string: values[1]) { s.url = u.absoluteString }
            BookmarkStore.shared.updateHomeSite(s)
        }
    }

    private var hasWallpaper: Bool { !wallpaperView.isHidden }
}

extension HomePageViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { sites.count + 1 }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "site", for: indexPath) as! HomeSiteCell
        if indexPath.item < sites.count {
            cell.configure(site: sites[indexPath.item], lightText: hasWallpaper)
        } else {
            cell.configureAdd(lightText: hasWallpaper)
        }
        return cell
    }

    func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! HomeHeaderView
        h.configure(showSearch: Prefs.centeredSearchBox, lightText: hasWallpaper, engine: SearchEngineStore.shared.current.name)
        h.onSearch = { [weak self] in self?.searchTapped() }
        h.onScan = { [weak self] in guard let self else { return }; self.delegate?.homePageDidRequestScan(self) }
        return h
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        let h: CGFloat = Prefs.centeredSearchBox ? max(220, cv.bounds.height * 0.32) : 70
        return CGSize(width: cv.bounds.width, height: h)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = min(cv.bounds.width, 620) - 28
        let columns = CGFloat(cv.bounds.width > 600 ? max(Prefs.homeColumns, 6) : Prefs.homeColumns)
        return CGSize(width: floor(width / columns), height: 92)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let side = max(14, (cv.bounds.width - 620) / 2 + 14)
        return UIEdgeInsets(top: 8, left: side, bottom: 90, right: side)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item >= sites.count { addSite(); return }
        if let url = URL(string: sites[indexPath.item].url) { delegate?.homePage(self, didSelect: url) }
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.item < sites.count else { return nil }
        let site = sites[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let url = URL(string: site.url)
            return UIMenu(children: [
                UIAction(title: L("Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    if let url { self.delegate?.homePage(self, openInNewTab: url, background: false) }
                },
                UIAction(title: L("Open in Background"), image: UIImage(systemName: "square.on.square.dashed")) { _ in
                    if let url { self.delegate?.homePage(self, openInNewTab: url, background: true) }
                },
                UIAction(title: L("Edit"), image: UIImage(systemName: "pencil")) { _ in self.edit(site) },
                UIAction(title: L("Move to bookmarks"), image: UIImage(systemName: "book")) { _ in
                    BookmarkStore.shared.add(title: site.title, url: site.url)
                    BookmarkStore.shared.removeHomeSite(id: site.id)
                    Toast.show(L("Move to bookmarks"))
                },
                UIAction(title: L("Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    BookmarkStore.shared.removeHomeSite(id: site.id)
                },
            ])
        }
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard Prefs.pullDownToSearch else { return }
        if sv.contentOffset.y < -80 && sv.isTracking && !pullTriggered {
            pullTriggered = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate decelerate: Bool) {
        if pullTriggered {
            pullTriggered = false
            if sv.contentOffset.y < -60 { searchTapped() }
        }
    }
}

extension HomePageViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ cv: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard indexPath.item < sites.count else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: sites[indexPath.item].url as NSString))
        item.localObject = sites[indexPath.item]
        return [item]
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath dest: IndexPath?) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil, let dest, dest.item < sites.count else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ cv: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dest = coordinator.destinationIndexPath, let item = coordinator.items.first, let src = item.sourceIndexPath else { return }
        let to = min(dest.item, sites.count - 1)
        cv.performBatchUpdates({
            let s = sites.remove(at: src.item)
            sites.insert(s, at: to)
            cv.moveItem(at: src, to: IndexPath(item: to, section: 0))
        })
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: to, section: 0))
        BookmarkStore.shared.moveHomeSite(from: src.item, to: to)
    }
}

final class HomeSiteCell: UICollectionViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private var currentHost: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerCurve = .continuous
        iconView.backgroundColor = Theme.cardBackground
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textAlignment = .center
        [iconView, titleLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(site: HomeSite, lightText: Bool) {
        titleLabel.text = site.title
        titleLabel.textColor = lightText ? .white : Theme.text
        iconView.layer.cornerRadius = CGFloat(Prefs.iconCornerRadius)
        iconView.contentMode = .scaleAspectFill
        iconView.tintColor = nil
        let url = URL(string: site.url)
        currentHost = url?.normalizedHost
        if let file = site.customIconFile, let img = UIImage(contentsOfFile: FileManager.default.appSupportURL.appendingPathComponent(file).path) {
            iconView.image = img
            return
        }
        if let host = currentHost, let img = FaviconManager.shared.cachedIcon(for: host) {
            iconView.image = img
        } else {
            iconView.image = FaviconManager.letterAvatar(for: site.title)
            FaviconManager.shared.icon(for: url) { [weak self] img in
                guard let self, let img, self.currentHost == url?.normalizedHost else { return }
                self.iconView.image = img
            }
        }
    }

    func configureAdd(lightText: Bool) {
        currentHost = nil
        titleLabel.text = L("Add")
        titleLabel.textColor = lightText ? .white : Theme.secondaryText
        iconView.layer.cornerRadius = CGFloat(Prefs.iconCornerRadius)
        iconView.image = Theme.symbol("plus", size: 22, weight: .medium)
        iconView.contentMode = .center
        iconView.tintColor = Theme.secondaryText
    }

    override var isHighlighted: Bool { didSet { contentView.alpha = isHighlighted ? 0.5 : 1 } }
}

final class HomeHeaderView: UICollectionReusableView {
    var onSearch: (() -> Void)?
    var onScan: (() -> Void)?
    private let logo = UILabel()
    private let box = UIControl()
    private let placeholder = UILabel()
    private let scanButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        logo.textAlignment = .center
        box.backgroundColor = Theme.cardBackground
        box.layer.cornerRadius = 22
        box.layer.shadowColor = UIColor.black.cgColor
        box.layer.shadowOpacity = 0.08
        box.layer.shadowRadius = 10
        box.layer.shadowOffset = CGSize(width: 0, height: 2)
        box.addTarget(self, action: #selector(search), for: .touchUpInside)

        let mag = UIImageView(image: Theme.symbol("magnifyingglass", size: 15, weight: .medium))
        mag.tintColor = Theme.secondaryText
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = Theme.secondaryText
        scanButton.setImage(Theme.symbol("qrcode.viewfinder", size: 17), for: .normal)
        scanButton.tintColor = Theme.icon
        scanButton.addTarget(self, action: #selector(scan), for: .touchUpInside)
        [mag, placeholder].forEach { $0.isUserInteractionEnabled = false }

        [logo, box].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        [mag, placeholder, scanButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; box.addSubview($0) }
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -22),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            box.heightAnchor.constraint(equalToConstant: 44),
            box.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.86),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            mag.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            mag.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: mag.trailingAnchor, constant: 8),
            placeholder.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            scanButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            scanButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            scanButton.widthAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(showSearch: Bool, lightText: Bool, engine: String) {
        box.isHidden = !showSearch
        logo.isHidden = !showSearch
        let attr = NSMutableAttributedString(string: "FA", attributes: [.font: UIFont.systemFont(ofSize: 38, weight: .heavy), .foregroundColor: lightText ? UIColor.white : Theme.accent])
        attr.append(NSAttributedString(string: "browser", attributes: [.font: UIFont.systemFont(ofSize: 38, weight: .light), .foregroundColor: lightText ? UIColor.white : Theme.text]))
        logo.attributedText = attr
        placeholder.text = L("Search or Enter Address") + " · " + engine
    }

    @objc private func search() { onSearch?() }
    @objc private func scan() { onScan?() }
}
