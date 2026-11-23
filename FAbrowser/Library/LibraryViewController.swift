import UIKit
import UniformTypeIdentifiers

/// Bookmarks | History, switched by a segmented control in the navigation bar.
final class LibraryViewController: UIViewController {
    var onOpen: ((URL, Bool) -> Void)?

    private let segment = UISegmentedControl(items: [L("Bookmarks"), L("History")])
    private var bookmarks: BookmarksViewController!
    private var history: HistoryViewController!

    init(segment: Int) {
        super.init(nibName: nil, bundle: nil)
        self.segment.selectedSegmentIndex = segment
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.titleView = segment
        segment.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        let open: (URL, Bool) -> Void = { [weak self] url, newTab in
            self?.dismiss(animated: true) { self?.onOpen?(url, newTab) }
        }
        bookmarks = BookmarksViewController(folderID: nil)
        bookmarks.onOpen = open
        history = HistoryViewController()
        history.onOpen = open
        for child in [bookmarks!, history!] as [UIViewController] {
            addChild(child)
            view.addSubview(child.view)
            child.view.pinEdges(to: view)
            child.didMove(toParent: self)
        }
        segmentChanged()
    }

    @objc private func segmentChanged() {
        let showBookmarks = segment.selectedSegmentIndex == 0
        bookmarks.view.isHidden = !showBookmarks
        history.view.isHidden = showBookmarks
        let active: UIViewController = showBookmarks ? bookmarks : history
        navigationItem.rightBarButtonItems = active.navigationItem.rightBarButtonItems
        toolbarItems = active.toolbarItems
        navigationController?.setToolbarHidden(active.toolbarItems?.isEmpty ?? true, animated: false)
    }

    @objc private func close() { dismiss(animated: true) }
}

// MARK: - Bookmarks

final class BookmarksViewController: UITableViewController, UIDocumentPickerDelegate {
    var onOpen: ((URL, Bool) -> Void)?
    private let folderID: UUID?
    private var folder: BookmarkNode { BookmarkStore.shared.folder(id: folderID) }

    init(folderID: UUID?) {
        self.folderID = folderID
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folder.title
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu()),
            editButtonItem,
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .bookmarksChanged, object: nil)
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("New Folder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.newFolder() },
            UIAction(title: L("New Bookmark"), image: UIImage(systemName: "bookmark")) { [weak self] _ in
                let vc = BookmarkEditViewController(mode: .new(title: "", url: "https://"), folderID: self?.folderID)
                self?.present(UINavigationController(rootViewController: vc), animated: true)
            },
            UIAction(title: L("Import Bookmarks"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.importBookmarks() },
            UIAction(title: L("Export Bookmarks"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportBookmarks() },
        ])
    }

    @objc private func reload() { tableView.reloadData() }

    private func newFolder() {
        promptText(L("New Folder"), message: L("Please enter the name of the folder to be created:"), placeholders: [L("Folder Name")]) { [weak self] v in
            let name = v.first?.trimmed ?? ""
            guard !name.isEmpty else { return }
            BookmarkStore.shared.addFolder(title: name, to: self?.folderID)
        }
    }

    private func importBookmarks() {
        showAlert(L("Import Bookmarks"), message: L("Import Bookmarks Hint"))
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.html, .data])
        picker.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentedViewController?.dismiss(animated: false)
            self?.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let html = try? String(contentsOf: url) else { Toast.show(L("Import Failed")); return }
        let n = BookmarkStore.shared.importHTML(html)
        Toast.show(n > 0 ? LF("%d bookmarks", n) + " · " + L("Import Success") : L("Import Failed"))
    }

    private func exportBookmarks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FAbrowser-bookmarks.html")
        try? BookmarkStore.shared.exportHTML().write(to: url, atomically: true, encoding: .utf8)
        share([url])
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(folder.children?.count ?? 0, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let children = folder.children, !children.isEmpty else {
            cell.textLabel?.text = L("Bookmarks you save will show up here.")
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }
        let node = children[indexPath.row]
        cell.textLabel?.text = node.title
        if node.isFolder {
            cell.imageView?.image = UIImage(systemName: "folder.fill")
            cell.imageView?.tintColor = Theme.accent
            cell.detailTextLabel?.text = LF("%d bookmarks", node.bookmarkCount) + (node.folderCount > 0 ? " · " + LF("%d folders", node.folderCount) : "")
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.detailTextLabel?.text = node.url
            cell.detailTextLabel?.textColor = .secondaryLabel
            let url = node.url.flatMap(URL.init(string:))
            cell.imageView?.image = url?.normalizedHost.flatMap { FaviconManager.shared.cachedIcon(for: $0) }?.resized(to: 24) ?? UIImage(systemName: "globe")
            cell.imageView?.tintColor = .secondaryLabel
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let children = folder.children, indexPath.row < children.count else { return }
        let node = children[indexPath.row]
        if isEditing {
            let vc = BookmarkEditViewController(mode: .edit(node), folderID: folderID)
            present(UINavigationController(rootViewController: vc), animated: true)
            return
        }
        if node.isFolder {
            let vc = BookmarksViewController(folderID: node.id)
            vc.onOpen = onOpen
            navigationController?.pushViewController(vc, animated: true)
        } else if let s = node.url, let url = URL(string: s) {
            onOpen?(url, false)
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !(folder.children?.isEmpty ?? true) }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { !(folder.children?.isEmpty ?? true) }

    override func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        BookmarkStore.shared.move(in: folderID, from: from.row, to: to.row)
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard style == .delete, let node = folder.children?[indexPath.row] else { return }
        BookmarkStore.shared.remove(id: node.id)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let node = folder.children?[safe: indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if let s = node.url, let url = URL(string: s) {
                actions.append(UIAction(title: L("Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in self?.onOpen?(url, true) })
                actions.append(UIAction(title: L("Copy URL"), image: UIImage(systemName: "link")) { _ in UIPasteboard.general.string = s })
                actions.append(UIAction(title: L("Move to homepage"), image: UIImage(systemName: "house")) { _ in
                    BookmarkStore.shared.addHomeSite(HomeSite(title: node.title, url: s))
                    BookmarkStore.shared.remove(id: node.id)
                    Toast.show(L("Move to homepage"))
                })
            }
            actions.append(UIAction(title: L("Edit"), image: UIImage(systemName: "pencil")) { _ in
                let vc = BookmarkEditViewController(mode: .edit(node), folderID: self?.folderID)
                self?.present(UINavigationController(rootViewController: vc), animated: true)
            })
            actions.append(UIAction(title: L("Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                BookmarkStore.shared.remove(id: node.id)
            })
            return UIMenu(children: actions)
        }
    }
}

// MARK: - History

final class HistoryViewController: UITableViewController, UISearchResultsUpdating {
    var onOpen: ((URL, Bool) -> Void)?
    private var groups: [(String, [HistoryItem])] = []
    private let searchController = UISearchController(searchResultsController: nil)

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L("Search")
        tableView.tableHeaderView = searchController.searchBar
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: L("Clear"), style: .plain, target: self, action: #selector(clearTapped))]
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .historyChanged, object: nil)
        reload()
    }

    @objc private func reload() {
        let q = searchController.searchBar.text?.lowercased() ?? ""
        let items = q.isEmpty ? HistoryStore.shared.items : HistoryStore.shared.items.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        let cal = Calendar.current
        let now = Date()
        var today: [HistoryItem] = [], yesterday: [HistoryItem] = [], week: [HistoryItem] = [], month: [HistoryItem] = [], older: [HistoryItem] = []
        for i in items {
            if cal.isDateInToday(i.date) { today.append(i) }
            else if cal.isDateInYesterday(i.date) { yesterday.append(i) }
            else if now.timeIntervalSince(i.date) < 7 * 86400 { week.append(i) }
            else if now.timeIntervalSince(i.date) < 30 * 86400 { month.append(i) }
            else { older.append(i) }
        }
        groups = [(L("Today"), today), (L("Yesterday"), yesterday), (L("Last week"), week), (L("Last month"), month), (L("Older"), older)].filter { !$0.1.isEmpty }
        tableView.reloadData()
        tableView.backgroundView = groups.isEmpty ? emptyView() : nil
    }

    private func emptyView() -> UIView {
        let l = UILabel()
        l.text = L("Websites you've visited recently will show up here.")
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }

    func updateSearchResults(for searchController: UISearchController) { reload() }

    @objc private func clearTapped() {
        let sheet = UIAlertController(title: L("Clear All History?"), message: nil, preferredStyle: .actionSheet)
        let options: [(String, Date?)] = [
            (L("Within 1 Hour"), Date().addingTimeInterval(-3600)),
            (L("Today"), Calendar.current.startOfDay(for: Date())),
            (L("Today And Yesterday"), Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))),
            (L("All"), nil),
        ]
        for (title, date) in options {
            sheet.addAction(UIAlertAction(title: title, style: .destructive) { _ in HistoryStore.shared.clear(since: date) })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: parent?.navigationItem.rightBarButtonItems?.first)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].1.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].0 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = groups[indexPath.section].1[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.url
        cell.detailTextLabel?.textColor = .secondaryLabel
        let host = URL(string: item.url)?.normalizedHost
        cell.imageView?.image = host.flatMap { FaviconManager.shared.cachedIcon(for: $0) }?.resized(to: 24) ?? UIImage(systemName: "globe")
        cell.imageView?.tintColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let url = URL(string: groups[indexPath.section].1[indexPath.row].url) { onOpen?(url, false) }
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if style == .delete { HistoryStore.shared.remove(id: groups[indexPath.section].1[indexPath.row].id) }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = groups[indexPath.section].1[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L("Open in New Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    if let u = URL(string: item.url) { self?.onOpen?(u, true) }
                },
                UIAction(title: L("Add to Library"), image: UIImage(systemName: "star")) { _ in
                    BookmarkStore.shared.add(title: item.title, url: item.url); Toast.show(L("Added"))
                },
                UIAction(title: L("Copy URL"), image: UIImage(systemName: "link")) { _ in UIPasteboard.general.string = item.url },
                UIAction(title: L("Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in HistoryStore.shared.remove(id: item.id) },
            ])
        }
    }
}

// MARK: - Bookmark editor

final class BookmarkEditViewController: UITableViewController {
    enum Mode {
        case new(title: String, url: String)
        case edit(BookmarkNode)
    }

    private let mode: Mode
    private var folderID: UUID?
    private let titleField = UITextField()
    private let urlField = UITextField()
    private var addToHomepage = false

    init(mode: Mode, folderID: UUID? = nil) {
        self.mode = mode
        self.folderID = folderID
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isFolder: Bool { if case .edit(let n) = mode { return n.isFolder }; return false }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch mode {
        case .new(let t, let u):
            title = L("New Bookmark"); titleField.text = t; urlField.text = u
        case .edit(let n):
            title = n.isFolder ? L("Edit") : L("Edit Bookmark"); titleField.text = n.title; urlField.text = n.url
        }
        titleField.placeholder = L("Title")
        urlField.placeholder = "URL"
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        [titleField, urlField].forEach { $0.clearButtonMode = .whileEditing }
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return isFolder ? 1 : 2 }
        if case .new = mode { return 2 }
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? L("Select Folder") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let f = indexPath.row == 0 ? titleField : urlField
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(f)
            f.pinEdges(to: cell.contentView, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 12))
            f.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            cell.selectionStyle = .none
        } else if indexPath.row == 0 {
            cell.textLabel?.text = L("Bookmarks")
            cell.detailTextLabel?.text = BookmarkStore.shared.folder(id: folderID).title
            cell.imageView?.image = UIImage(systemName: "folder")
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = L("Add to homepage")
            let sw = UISwitch()
            sw.isOn = addToHomepage
            sw.addAction(UIAction { [weak self] a in self?.addToHomepage = (a.sender as? UISwitch)?.isOn ?? false }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, indexPath.row == 0 else { return }
        let sheet = UIAlertController(title: L("Select Folder"), message: nil, preferredStyle: .actionSheet)
        var excluded: UUID?
        if case .edit(let n) = mode, n.isFolder { excluded = n.id }
        for (node, depth) in BookmarkStore.shared.allFolders() where node.id != excluded {
            sheet.addAction(UIAlertAction(title: String(repeating: "    ", count: depth) + node.title, style: .default) { [weak self] _ in
                self?.folderID = node.id == BookmarkStore.shared.root.id ? nil : node.id
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: tableView.cellForRow(at: indexPath))
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func save() {
        let t = titleField.text?.trimmed ?? ""
        let u = urlField.text?.trimmed ?? ""
        guard !t.isEmpty || !u.isEmpty else { showAlert(L("Name can't be empty")); return }
        switch mode {
        case .new:
            guard let url = URL.fromUserInput(u) ?? URL(string: u), url.scheme != nil else { showAlert(L("Invalid URL")); return }
            BookmarkStore.shared.add(title: t.isEmpty ? url.displayString : t, url: url.absoluteString, to: folderID)
            if addToHomepage { BookmarkStore.shared.addHomeSite(HomeSite(title: t.isEmpty ? url.displayString : t, url: url.absoluteString)) }
            Toast.show(L("Added"))
        case .edit(let n):
            BookmarkStore.shared.update(id: n.id, title: t.isEmpty ? n.title : t, url: u, moveTo: folderID)
        }
        dismiss(animated: true)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension UIImage {
    func resized(to side: CGFloat) -> UIImage { resized(to: CGSize(width: side, height: side)) }

    func resized(to size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
