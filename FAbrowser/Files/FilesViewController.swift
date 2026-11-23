import UIKit
import QuickLook
import AVKit
import UniformTypeIdentifiers

/// File manager rooted at Documents: active downloads on top, then folders and files.
final class FilesViewController: UITableViewController, QLPreviewControllerDataSource, UIDocumentPickerDelegate {
    var onOpenWeb: ((URL) -> Void)?

    private let directory: URL
    private var files: [URL] = []
    private var previewURL: URL?
    private var sortByName = UserDefaults.standard.bool(forKey: "filesSortByName")

    private var isRoot: Bool { directory.standardizedFileURL == FileManager.default.documentsURL.standardizedFileURL }
    private var downloads: [DownloadItem] { isRoot ? DownloadManager.shared.active : [] }

    init(directory: URL) {
        self.directory = directory
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isRoot ? L("Files") : directory.lastPathComponent
        tableView.allowsMultipleSelectionDuringEditing = true
        if isRoot { navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close)) }
        navigationItem.rightBarButtonItems = [UIBarButtonItem(image: UIImage(systemName: "plus.circle"), menu: addMenu()), editButtonItem]
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged), name: .downloadsChanged, object: nil)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullReload), for: .valueChanged)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func addMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("New Folder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.newFolder() },
            UIAction(title: L("New Download"), image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in self?.newDownload() },
            UIAction(title: L("Wi-Fi Transfer"), image: UIImage(systemName: "wifi")) { [weak self] _ in
                self?.navigationController?.pushViewController(WiFiTransferViewController(), animated: true)
            },
            UIAction(title: L("Import"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.importFromFiles() },
            UIMenu(title: L("Sort"), options: .displayInline, children: [
                UIAction(title: L("Date"), state: sortByName ? .off : .on) { [weak self] _ in self?.setSort(name: false) },
                UIAction(title: L("Name"), state: sortByName ? .on : .off) { [weak self] _ in self?.setSort(name: true) },
            ]),
            UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: L("All Pause"), image: UIImage(systemName: "pause")) { _ in DownloadManager.shared.pauseAll() },
                UIAction(title: L("All Resume"), image: UIImage(systemName: "play")) { _ in DownloadManager.shared.resumeAll() },
            ]),
        ])
    }

    private func setSort(name: Bool) {
        sortByName = name
        UserDefaults.standard.set(name, forKey: "filesSortByName")
        navigationItem.rightBarButtonItems?.first?.menu = addMenu()
        reload()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func pullReload() { reload(); refreshControl?.endRefreshing() }
    @objc private func downloadsChanged() {
        if isRoot && !isEditing { reload() }
    }

    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let list = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        files = list.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let db = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if da != db { return da }
            if sortByName { return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
            let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma > mb
        }
        tableView.reloadData()
        tableView.backgroundView = (files.isEmpty && downloads.isEmpty) ? emptyView() : nil
    }

    private func emptyView() -> UIView {
        let l = UILabel()
        l.text = L("No local downloads.") + "\n\n" + L("Long press link or enter address to download.")
        l.numberOfLines = 0
        l.textAlignment = .center
        l.textColor = .secondaryLabel
        return l
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: Actions

    private func newFolder() {
        promptText(L("Create Folder"), message: L("Please enter the name of the folder to be created:"), placeholders: [L("Folder Name")]) { [weak self] v in
            guard let self, let name = v.first?.trimmed, !name.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(name), withIntermediateDirectories: false)
                self.reload()
            } catch { self.showAlert(L("Create Error"), message: error.localizedDescription) }
        }
    }

    private func newDownload() {
        promptText(L("New Download"), message: L("Enter URL to download"), placeholders: ["https://"], values: [UIPasteboard.general.url?.absoluteString ?? ""], keyboard: .URL) { v in
            guard let s = v.first, let url = URL.fromUserInput(s) ?? URL(string: s), url.scheme != nil else { Toast.show(L("Invalid URL")); return }
            DownloadManager.shared.download(url: url)
        }
    }

    private func importFromFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for u in urls {
            let dest = FileManager.default.uniqueURL(for: directory.appendingPathComponent(u.lastPathComponent))
            try? FileManager.default.moveItem(at: u, to: dest)
        }
        reload()
    }

    private func open(_ url: URL) {
        if isDirectory(url) {
            let vc = FilesViewController(directory: url)
            vc.onOpenWeb = onOpenWeb
            navigationController?.pushViewController(vc, animated: true)
            return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, type.conforms(to: .audiovisualContent) {
            let vc = AVPlayerViewController()
            vc.player = AVPlayer(url: url)
            present(vc, animated: true) { vc.player?.play(); vc.player?.rate = Float(Prefs.playbackRate) }
            return
        }
        if ["html", "htm", "webarchive", "mht", "svg"].contains(url.pathExtension.lowercased()) {
            dismiss(animated: true) { self.onOpenWeb?(url) }
            return
        }
        if url.pathExtension.lowercased() == "js", let s = try? String(contentsOf: url) {
            confirm(L("JavaScript Extensions"), message: L("JavaScript Extension Detected"), action: L("Add")) {
                JSExtensionStore.shared.upsert(JSExtensionStore.parse(fileContent: s, fallbackName: url.deletingPathExtension().lastPathComponent))
                Toast.show(L("Added"))
            }
            return
        }
        previewURL = url
        let ql = QLPreviewController()
        ql.dataSource = self
        present(ql, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }

    private func rename(_ url: URL) {
        promptText(L("Rename"), placeholders: [L("Filename")], values: [url.lastPathComponent]) { [weak self] v in
            guard let self, let name = v.first?.trimmed, !name.isEmpty, name != url.lastPathComponent else { return }
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            let doMove = {
                do { try FileManager.default.moveItem(at: url, to: dest); self.reload() } catch { self.showAlert(L("Error"), message: error.localizedDescription) }
            }
            if !self.isDirectory(url), url.pathExtension.lowercased() != dest.pathExtension.lowercased() {
                self.confirm(LF("Are you sure to change extension from '.%@' to '.%@'?", url.pathExtension, dest.pathExtension), message: L("Change file extension may also change the file type"), handler: doMove)
            } else {
                doMove()
            }
        }
    }

    private func move(_ urls: [URL]) {
        let root = FileManager.default.documentsURL
        var folders: [URL] = [root]
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e where isDirectory(u) && !urls.contains(where: { u.path.hasPrefix($0.path) }) { folders.append(u) }
        }
        let sheet = UIAlertController(title: L("Move Item"), message: L("Please enter the new location for this item:"), preferredStyle: .actionSheet)
        for f in folders.prefix(30) {
            let rel = f.path.replacingOccurrences(of: root.path, with: "")
            sheet.addAction(UIAlertAction(title: rel.isEmpty ? "/" + L("Files") : rel, style: .default) { [weak self] _ in
                for u in urls {
                    try? FileManager.default.moveItem(at: u, to: FileManager.default.uniqueURL(for: f.appendingPathComponent(u.lastPathComponent)))
                }
                self?.setEditing(false, animated: true)
                self?.reload()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    private func zip(_ urls: [URL]) {
        Toast.show(L("Zipping..."))
        let dir = directory
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var source: URL
            let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                source = urls[0]
            } else {
                let folderName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
                source = staging.appendingPathComponent(folderName)
                try? fm.createDirectory(at: source, withIntermediateDirectories: true)
                for u in urls { try? fm.copyItem(at: u, to: source.appendingPathComponent(u.lastPathComponent)) }
            }
            var result: URL?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordError) { zipURL in
                let dest = fm.uniqueURL(for: dir.appendingPathComponent(source.lastPathComponent + ".zip"))
                if (try? fm.copyItem(at: zipURL, to: dest)) != nil { result = dest }
            }
            try? fm.removeItem(at: staging)
            DispatchQueue.main.async {
                Toast.show(result != nil ? L("Zipped") : L("Failed"))
                self.setEditing(false, animated: true)
                self.reload()
            }
        }
    }

    private func delete(_ urls: [URL]) {
        confirm(L("Are you sure to delete?"), action: L("Delete"), destructive: true) { [weak self] in
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            self?.setEditing(false, animated: true)
            self?.reload()
        }
    }

    // MARK: Editing toolbar

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        navigationController?.setToolbarHidden(!editing, animated: animated)
        toolbarItems = editing ? [
            UIBarButtonItem(title: L("Select All"), style: .plain, target: self, action: #selector(selectAllFiles)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(shareSelected)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "folder"), style: .plain, target: self, action: #selector(moveSelected)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "doc.zipper"), style: .plain, target: self, action: #selector(zipSelected)),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(deleteSelected)),
        ] : nil
    }

    private var selectedFiles: [URL] {
        (tableView.indexPathsForSelectedRows ?? []).filter { $0.section == 1 }.map { files[$0.row] }
    }

    @objc private func selectAllFiles() {
        for i in files.indices { tableView.selectRow(at: IndexPath(row: i, section: 1), animated: false, scrollPosition: .none) }
    }
    @objc private func shareSelected() { if !selectedFiles.isEmpty { share(selectedFiles) } }
    @objc private func moveSelected() { if !selectedFiles.isEmpty { move(selectedFiles) } }
    @objc private func zipSelected() { if !selectedFiles.isEmpty { zip(selectedFiles) } }
    @objc private func deleteSelected() { if !selectedFiles.isEmpty { delete(selectedFiles) } }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? downloads.count : files.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return downloads.isEmpty ? nil : L("Downloading") }
        return files.isEmpty ? nil : LF("%d Items", files.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = DownloadCell(style: .subtitle, reuseIdentifier: nil)
            cell.configure(downloads[indexPath.row])
            return cell
        }
        let url = files[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = url.lastPathComponent
        cell.textLabel?.lineBreakMode = .byTruncatingMiddle
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
        if values?.isDirectory == true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
            cell.detailTextLabel?.text = LF("%d Items", count) + " · " + date
            cell.imageView?.image = UIImage(systemName: "folder.fill")
            cell.imageView?.tintColor = Theme.accent
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.detailTextLabel?.text = Int64(values?.fileSize ?? 0).byteString + " · " + date
            cell.imageView?.image = UIImage(systemName: FileIcon.symbol(for: url))
            cell.imageView?.tintColor = FileIcon.color(for: url)
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing { return }
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let item = downloads[indexPath.row]
            switch item.state {
            case .downloading: DownloadManager.shared.pause(item)
            case .paused, .failed: DownloadManager.shared.resume(item)
            case .finished: if let d = item.destination { open(d) }
            }
            return
        }
        open(files[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 || !isEditing }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        if indexPath.section == 0 {
            let item = downloads[indexPath.row]
            return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: L("Cancel")) { _, _, done in
                DownloadManager.shared.cancel(item); done(true)
            }])
        }
        let url = files[indexPath.row]
        return UISwipeActionsConfiguration(actions: [
            UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in self?.delete([url]); done(true) },
            UIContextualAction(style: .normal, title: L("Rename")) { [weak self] _, _, done in self?.rename(url); done(true) },
        ])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == 1, !isEditing else { return nil }
        let url = files[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: L("Open in…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in self.share([url]) },
                UIAction(title: L("Rename"), image: UIImage(systemName: "pencil")) { _ in self.rename(url) },
                UIAction(title: L("Move"), image: UIImage(systemName: "folder")) { _ in self.move([url]) },
                UIAction(title: L("Zip"), image: UIImage(systemName: "doc.zipper")) { _ in self.zip([url]) },
                UIAction(title: L("Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    try? FileManager.default.copyItem(at: url, to: FileManager.default.uniqueURL(for: url)); self.reload()
                },
                UIAction(title: L("Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.delete([url]) },
            ])
        }
    }
}

final class DownloadCell: UITableViewCell {
    private let bar = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 40),
            bar.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: DownloadItem) {
        textLabel?.text = item.filename
        textLabel?.lineBreakMode = .byTruncatingMiddle
        bar.progress = Float(item.progress)
        let size = item.total > 0 ? "\(item.received.byteString) / \(item.total.byteString)" : item.received.byteString
        switch item.state {
        case .downloading:
            detailTextLabel?.text = L("Downloading") + " · " + size
            imageView?.image = UIImage(systemName: "pause.circle")
        case .paused:
            detailTextLabel?.text = L("Paused") + " · " + size
            imageView?.image = UIImage(systemName: "play.circle")
        case .failed:
            detailTextLabel?.text = L("Download Failed") + (item.error.map { " · " + $0 } ?? "")
            imageView?.image = UIImage(systemName: "arrow.clockwise.circle")
        case .finished:
            detailTextLabel?.text = L("Downloaded")
            imageView?.image = UIImage(systemName: "checkmark.circle")
        }
        detailTextLabel?.textColor = item.state == .failed ? .systemRed : .secondaryLabel
        imageView?.tintColor = Theme.accent
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        guard let t = UTType(filenameExtension: ext) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
        if t.conforms(to: .audio) { return "music.note" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .archive) || ext == "zip" || ext == "rar" || ext == "7z" { return "doc.zipper" }
        if ext == "html" || ext == "htm" || ext == "webarchive" { return "safari" }
        if t.conforms(to: .text) || t.conforms(to: .sourceCode) { return "doc.text" }
        if ext == "epub" || ext == "mobi" || ext == "azw3" { return "book" }
        if ext == "ipa" || ext == "apk" { return "app.badge" }
        return "doc"
    }

    static func color(for url: URL) -> UIColor {
        switch symbol(for: url) {
        case "photo": return .systemGreen
        case "film": return .systemPurple
        case "music.note": return .systemPink
        case "doc.richtext": return .systemRed
        case "doc.zipper": return .systemOrange
        case "safari": return .systemBlue
        default: return .secondaryLabel
        }
    }
}
