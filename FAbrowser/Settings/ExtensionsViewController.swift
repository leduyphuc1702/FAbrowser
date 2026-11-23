import UIKit
import WebKit
import UniformTypeIdentifiers

/// JavaScript extensions list: passive (auto-run) and active (run from menu) userscripts.
final class ExtensionsViewController: UITableViewController, UIDocumentPickerDelegate {
    private var items: [JSExtension] { JSExtensionStore.shared.extensions }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("JavaScript Extensions")
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        }
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [
                UIAction(title: L("New Extension"), image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.edit(nil) },
                UIAction(title: L("Import from Files"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.importFile() },
                UIAction(title: L("Import from URL"), image: UIImage(systemName: "link")) { [weak self] _ in self?.importURL() },
            ])),
            editButtonItem,
        ]
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: .extensionsChanged, object: nil)
    }

    @objc private func close() { dismiss(animated: true) }

    private func edit(_ ext: JSExtension?) {
        navigationController?.pushViewController(ExtensionEditorViewController(ext: ext), animated: true)
    }

    private func importFile() {
        let types = [UTType(filenameExtension: "js") ?? .sourceCode, .javaScript, .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for u in urls {
            guard let s = try? String(contentsOf: u) else { continue }
            JSExtensionStore.shared.upsert(JSExtensionStore.parse(fileContent: s, fallbackName: u.deletingPathExtension().lastPathComponent))
        }
        tableView.reloadData()
    }

    private func importURL() {
        promptText(L("Import from URL"), placeholders: ["https://…/script.user.js"], keyboard: .URL) { [weak self] v in
            guard let s = v.first, let url = URL(string: s.trimmed) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    guard let data, let code = String(data: data, encoding: .utf8) else { Toast.show(L("Failed")); return }
                    JSExtensionStore.shared.upsert(JSExtensionStore.parse(fileContent: code, fallbackName: url.deletingPathExtension().lastPathComponent))
                    self?.tableView.reloadData()
                    Toast.show(L("Added"))
                }
            }.resume()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L("Passive extensions run automatically on matching pages. Active extensions run when you pick them from Menu › JavaScript Extensions.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let ext = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = ext.name
        cell.detailTextLabel?.text = (ext.isActive ? L("Active") : L("Passive")) + " · " + ext.matches
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = UIImage(systemName: ext.isActive ? "hand.tap" : "bolt")
        cell.imageView?.tintColor = ext.enabled ? Theme.accent : .tertiaryLabel
        let sw = UISwitch()
        sw.isOn = ext.enabled
        sw.addAction(UIAction { _ in
            var e = ext
            e.enabled = sw.isOn
            JSExtensionStore.shared.upsert(e)
        }, for: .valueChanged)
        cell.accessoryView = sw
        cell.editingAccessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(items[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard style == .delete else { return }
        JSExtensionStore.shared.remove(id: items[indexPath.row].id)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        JSExtensionStore.shared.move(from: from.row, to: to.row)
    }
}

final class ExtensionEditorViewController: UITableViewController {
    private var ext: JSExtension
    private let isNew: Bool
    private let nameField = UITextField()
    private let authorField = UITextField()
    private let summaryField = UITextField()
    private let matchField = UITextField()
    private let codeView = UITextView()

    init(ext: JSExtension?) {
        isNew = ext == nil
        self.ext = ext ?? JSExtension(name: "", code: "")
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? L("New Extension") : L("Edit")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        tableView.keyboardDismissMode = .interactive
        for (f, v, p) in [(nameField, ext.name, L("Name")), (authorField, ext.author, L("Author")), (summaryField, ext.summary, L("Description")), (matchField, ext.matches, "*")] {
            f.text = v
            f.placeholder = p
            f.clearButtonMode = .whileEditing
        }
        matchField.autocapitalizationType = .none
        matchField.autocorrectionType = .no
        codeView.text = ext.code
        codeView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.autocapitalizationType = .none
        codeView.autocorrectionType = .no
        codeView.smartQuotesType = .no
        codeView.smartDashesType = .no
        codeView.backgroundColor = .clear
    }

    @objc private func save() {
        let name = nameField.text?.trimmed ?? ""
        let code = codeView.text ?? ""
        guard !name.isEmpty else { Toast.show(L("Please enter a name")); return }
        guard !code.trimmed.isEmpty else { Toast.show(L("Please enter code")); return }
        ext.name = name
        ext.author = authorField.text ?? ""
        ext.summary = summaryField.text ?? ""
        ext.matches = matchField.text?.trimmed.isEmpty == false ? matchField.text!.trimmed : "*"
        ext.code = code
        JSExtensionStore.shared.upsert(ext)
        navigationController?.popViewController(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [3, 1, 2, 1][section]
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [L("Info"), L("Match URLs"), L("Run"), L("Code")][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? L("Separate multiple rules with @@. Use * as wildcard, or /regex/.") : nil
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 3 ? 360 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        func embed(_ v: UIView, insets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)) {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: insets.left),
                v.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -insets.right),
                v.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: insets.top),
                v.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -insets.bottom),
                v.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
        switch (indexPath.section, indexPath.row) {
        case (0, let r): embed([nameField, authorField, summaryField][r])
        case (1, _): embed(matchField)
        case (2, 0):
            cell.textLabel?.text = L("Active Extension")
            let sw = UISwitch()
            sw.isOn = ext.isActive
            sw.addAction(UIAction { [weak self] _ in self?.ext.isActive = sw.isOn }, for: .valueChanged)
            cell.accessoryView = sw
        case (2, _):
            cell.textLabel?.text = L("Run At")
            let seg = UISegmentedControl(items: [L("Very Beginning"), L("DOMContentLoaded")])
            seg.selectedSegmentIndex = ext.runAt == .veryBeginning ? 0 : 1
            seg.addAction(UIAction { [weak self] _ in self?.ext.runAt = seg.selectedSegmentIndex == 0 ? .veryBeginning : .domContentLoaded }, for: .valueChanged)
            cell.accessoryView = seg
            seg.sizeToFit()
        default: embed(codeView, insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 6))
        }
        return cell
    }
}

/// User element-hiding rules, grouped by host.
final class HiddenElementsViewController: UITableViewController {
    private let host: String?
    private var hosts: [String] = []

    init(host: String?) {
        self.host = host
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = host ?? L("User Hide Ad")
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Clear"), style: .plain, target: self, action: #selector(clearAll))
        reload()
    }

    private func reload() {
        hosts = host.map { [$0] } ?? AdBlocker.shared.userRules.keys.sorted()
        hosts = hosts.filter { !(AdBlocker.shared.userRules[$0] ?? []).isEmpty }
        tableView.reloadData()
        let empty = UILabel()
        empty.text = L("No hidden elements.") + "\n\n" + L("Use Toolbox › Hide Element to pick an element on a page.")
        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.textColor = .secondaryLabel
        tableView.backgroundView = hosts.isEmpty ? empty : nil
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func clearAll() {
        confirm(L("Clear all hidden element rules?"), action: L("Clear"), destructive: true) { [weak self] in
            if let h = self?.host { AdBlocker.shared.clearUserRules(host: h) } else { AdBlocker.shared.clearUserRules() }
            self?.reload()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { hosts.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { hosts[section] }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AdBlocker.shared.userRules[hosts[section]]?.count ?? 0 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.textLabel?.text = AdBlocker.shared.userRules[hosts[indexPath.section]]?[safe: indexPath.row]
        cell.textLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        cell.textLabel?.numberOfLines = 3
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        let h = hosts[indexPath.section]
        guard style == .delete, let sel = AdBlocker.shared.userRules[h]?[safe: indexPath.row] else { return }
        AdBlocker.shared.removeUserRule(host: h, selector: sel)
        reload()
    }
}

/// Per-site sheet opened from the shield in the URL bar.
final class SiteSettingsViewController: UITableViewController {
    private let siteTab: Tab
    private weak var browser: BrowserViewController?
    private var host: String? { siteTab.webView?.url?.host }

    init(tab: Tab, browser: BrowserViewController) {
        self.siteTab = tab
        self.browser = browser
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = host ?? L("Site Settings")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    }

    @objc private func close() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [1, 3, 2][section] }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? L("Disable ad block on this site if it does not work correctly.") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        let secure = siteTab.webView?.hasOnlySecureContent == true && siteTab.webView?.url?.scheme == "https"
        switch (indexPath.section, indexPath.row) {
        case (0, _):
            cell.imageView?.image = UIImage(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill")
            cell.imageView?.tintColor = secure ? Theme.shieldGreen : .systemOrange
            cell.textLabel?.text = secure ? L("Connection is secure") : L("Connection is not secure")
            cell.textLabel?.numberOfLines = 0
            cell.selectionStyle = .none
        case (1, 0):
            cell.textLabel?.text = L("Ad Block")
            let sw = UISwitch()
            sw.isOn = Prefs.adBlock && !AdBlocker.shared.isWhitelisted(host)
            sw.isEnabled = Prefs.adBlock && host != nil
            sw.addAction(UIAction { [weak self] _ in
                guard let self, let h = self.host else { return }
                AdBlocker.shared.setWhitelisted(h, !sw.isOn)
                self.siteTab.webView?.reload()
            }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        case (1, 1):
            cell.textLabel?.text = L("Request Desktop Site")
            let sw = UISwitch()
            sw.isOn = siteTab.isDesktop
            sw.addAction(UIAction { [weak self] _ in self?.browser?.toggleDesktop(adjustM: false) }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        case (1, _):
            cell.textLabel?.text = L("Hidden Elements")
            cell.detailTextLabel?.text = "\(host.flatMap { AdBlocker.shared.userRules[$0]?.count } ?? 0)"
            cell.accessoryType = .disclosureIndicator
        case (2, 0):
            cell.textLabel?.text = L("Copy Link")
            cell.textLabel?.textColor = Theme.accent
        default:
            cell.textLabel?.text = L("Clear Site Data")
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (1, 2):
            navigationController?.pushViewController(HiddenElementsViewController(host: host), animated: true)
        case (2, 0):
            UIPasteboard.general.url = siteTab.webView?.url
            Toast.show(L("Copied"))
        case (2, 1):
            guard let host, let store = siteTab.webView?.configuration.websiteDataStore else { return }
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let matching = records.filter { host.hasSuffix($0.displayName) || $0.displayName.hasSuffix(host.replacingOccurrences(of: "www.", with: "")) }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) {
                    Toast.show(L("Cleared"))
                    self.siteTab.webView?.reload()
                }
            }
        default: break
        }
    }
}
