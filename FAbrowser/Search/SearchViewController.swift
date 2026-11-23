import UIKit

/// Full-screen URL / search editor shown when tapping the location bar.
final class SearchViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    var onSubmit: ((String, SearchEngine?) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onScan: (() -> Void)?

    private let initialText: String?
    private let isPrivate: Bool
    private let topBar = UIView()
    private let field = UITextField()
    private let cancelButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    private enum Row {
        case clipboard(String)
        case suggestion(String)
        case history(HistoryItem)
        case searchHistory(String)
        case clearSearchHistory
    }
    private var sections: [(title: String?, rows: [Row])] = []
    private var suggestTask: URLSessionDataTask?
    private var suggestions: [String] = []
    private var lastTyped = ""

    init(initialText: String?, isPrivate: Bool) {
        self.initialText = initialText
        self.isPrivate = isPrivate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { isPrivate ? .lightContent : .default }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = isPrivate ? Theme.privateTrayBackground : Theme.barBackground

        topBar.backgroundColor = isPrivate ? Theme.privateBarBackground : Theme.barBackground
        field.backgroundColor = isPrivate ? Theme.privateLocationBackground : Theme.locationBackground
        field.textColor = isPrivate ? .white : Theme.text
        field.layer.cornerRadius = 9
        field.font = .systemFont(ofSize: 16)
        field.attributedPlaceholder = NSAttributedString(string: L("Search or Enter Address"), attributes: [.foregroundColor: isPrivate ? UIColor.white.withAlphaComponent(0.5) : Theme.secondaryText])
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.text = initialText
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        let mag = UIImageView(image: Theme.symbol("magnifyingglass", size: 14, weight: .medium))
        mag.tintColor = Theme.secondaryText
        mag.contentMode = .center
        mag.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        field.leftView = mag
        field.leftViewMode = .always
        let scan = UIButton(type: .system)
        scan.setImage(Theme.symbol("qrcode.viewfinder", size: 16), for: .normal)
        scan.tintColor = isPrivate ? .white : Theme.icon
        scan.frame = CGRect(x: 0, y: 0, width: 36, height: 34)
        scan.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        field.rightView = scan
        field.rightViewMode = .unlessEditing
        field.inputAccessoryView = QuickSearchBar(isPrivate: isPrivate) { [weak self] insert in
            self?.field.insertText(insert)
        } onEngine: { [weak self] engine in
            guard let self, let text = self.field.text, !text.trimmed.isEmpty else { return }
            self.finish { self.onSubmit?(text, engine) }
        }

        cancelButton.setTitle(L("Cancel"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.tintColor = isPrivate ? .white : Theme.accent
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.separatorColor = isPrivate ? UIColor.white.withAlphaComponent(0.08) : Theme.separator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")

        [topBar, tableView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        [field, cancelButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; topBar.addSubview($0) }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Theme.urlBarHeight),
            field.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 5),
            field.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -5),
            cancelButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        field.becomeFirstResponder()
        selectInitialText()
        DispatchQueue.main.async { self.selectInitialText() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        selectInitialText()
    }

    /// The current address starts out fully selected, ready to copy or to be typed over.
    /// UIKit moves the caret to the end while the field is still being presented, so this repeats until it sticks.
    private func selectInitialText() {
        guard let initial = initialText, !initial.isEmpty, field.text == initial, field.isFirstResponder else { return }
        let all = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        if field.selectedTextRange != all { field.selectAll(nil) }
    }

    // MARK: Data

    private var queryText: String {
        guard let text = field.text else { return "" }
        if let sel = field.selectedTextRange, !sel.isEmpty {
            let start = field.offset(from: field.beginningOfDocument, to: sel.start)
            return String(text.prefix(start))
        }
        return text
    }

    private func rebuild() {
        let q = queryText.trimmed
        var secs: [(String?, [Row])] = []
        if q.isEmpty || q == initialText {
            if Prefs.autoPasteCopied, !Prefs.lastCopiedURL.isEmpty, Prefs.lastCopiedURL != initialText {
                secs.append((L("Last website copied"), [.clipboard(Prefs.lastCopiedURL)]))
            }
            if Prefs.showHistoryOnSearchStart, !HistoryStore.shared.searches.isEmpty, !isPrivate {
                secs.append((L("Search History"), HistoryStore.shared.searches.prefix(10).map { .searchHistory($0) } + [.clearSearchHistory]))
            }
        } else {
            if !suggestions.isEmpty { secs.append((nil, suggestions.prefix(6).map { .suggestion($0) })) }
            if Prefs.matchHistory {
                let hist = HistoryStore.shared.search(q, limit: 6)
                if !hist.isEmpty { secs.append((L("History"), hist.map { .history($0) })) }
            }
            let searches = HistoryStore.shared.searches.filter { $0.lowercased().hasPrefix(q.lowercased()) && $0 != q }.prefix(3)
            if !searches.isEmpty { secs.append((L("Search History"), searches.map { .searchHistory($0) })) }
        }
        sections = secs.map { (title: $0.0, rows: $0.1) }
        tableView.reloadData()
    }

    @objc private func textChanged() {
        let typed = queryText
        let isDeleting = typed.count < lastTyped.count
        lastTyped = typed
        if Prefs.domainAutoCompletion, !isDeleting, let completion = HistoryStore.shared.domainCompletion(for: typed), completion.count > typed.count,
           completion.lowercased().hasPrefix(typed.lowercased()) {
            let rest = String(completion.dropFirst(typed.count))
            field.text = typed + rest
            if let start = field.position(from: field.beginningOfDocument, offset: typed.count) {
                field.selectedTextRange = field.textRange(from: start, to: field.endOfDocument)
            }
        }
        fetchSuggestions(typed)
        rebuild()
    }

    private func fetchSuggestions(_ q: String) {
        suggestTask?.cancel()
        guard Prefs.searchSuggestions, !isPrivate, !q.trimmed.isEmpty, URL.fromUserInput(q) == nil || q.count < 4 else {
            suggestions = []
            return
        }
        suggestTask = SearchEngineStore.shared.suggestions(for: q) { [weak self] list in
            guard let self, self.queryText == q else { return }
            self.suggestions = list.filter { $0 != q }
            self.rebuild()
        }
    }

    // MARK: Actions

    private func finish(_ then: @escaping () -> Void) {
        field.resignFirstResponder()
        dismiss(animated: true, completion: then)
    }

    @objc private func cancel() { finish {} }

    @objc private func scanTapped() { finish { [weak self] in self?.onScan?() } }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = field.text ?? ""
        guard !text.trimmed.isEmpty else { return false }
        finish { [weak self] in self?.onSubmit?(text, nil) }
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // Backspace with an inline completion selected removes just the completion.
        if string.isEmpty, let sel = textField.selectedTextRange, !sel.isEmpty {
            let start = textField.offset(from: textField.beginningOfDocument, to: sel.start)
            let end = textField.offset(from: textField.beginningOfDocument, to: sel.end)
            if end == (textField.text?.count ?? 0), start > 0, range.location == start {
                textField.text = String(textField.text!.prefix(start))
                lastTyped = textField.text ?? ""
                fetchSuggestions(lastTyped)
                rebuild()
                return false
            }
        }
        return true
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        let fg: UIColor = isPrivate ? .white : Theme.text
        cell.textLabel?.textColor = fg
        cell.detailTextLabel?.textColor = isPrivate ? UIColor.white.withAlphaComponent(0.5) : Theme.secondaryText
        cell.imageView?.tintColor = isPrivate ? UIColor.white.withAlphaComponent(0.6) : Theme.secondaryText
        switch sections[indexPath.section].rows[indexPath.row] {
        case .clipboard(let s):
            cell.textLabel?.text = s
            cell.imageView?.image = Theme.symbol("doc.on.clipboard", size: 15)
        case .suggestion(let s):
            cell.textLabel?.text = s
            cell.imageView?.image = Theme.symbol("magnifyingglass", size: 15)
            cell.accessoryView = fillButton(s)
        case .history(let h):
            cell.textLabel?.text = h.title
            cell.detailTextLabel?.text = h.url
            cell.imageView?.image = Theme.symbol("clock", size: 15)
        case .searchHistory(let s):
            cell.textLabel?.text = s
            cell.imageView?.image = Theme.symbol("clock.arrow.circlepath", size: 15)
            cell.accessoryView = fillButton(s)
        case .clearSearchHistory:
            cell.textLabel?.text = L("Clear") + " " + L("Search History")
            cell.textLabel?.textColor = Theme.destructive
            cell.textLabel?.font = .systemFont(ofSize: 14)
        }
        return cell
    }

    private func fillButton(_ text: String) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.field.text = text + " "
            self?.textChanged()
        })
        b.setImage(Theme.symbol("arrow.up.backward", size: 14), for: .normal)
        b.tintColor = Theme.secondaryText
        b.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        return b
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .clipboard(let s): finish { [weak self] in self?.onSubmit?(s, nil) }
        case .suggestion(let s), .searchHistory(let s): finish { [weak self] in self?.onSubmit?(s, SearchEngineStore.shared.current) }
        case .history(let h): if let u = URL(string: h.url) { finish { [weak self] in self?.onOpenURL?(u) } }
        case .clearSearchHistory:
            HistoryStore.shared.clearSearches()
            rebuild()
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let row = sections[indexPath.section].rows[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in
            switch row {
            case .searchHistory(let s): HistoryStore.shared.removeSearch(s)
            case .history(let h): HistoryStore.shared.remove(id: h.id)
            case .clipboard: Prefs.lastCopiedURL = ""
            default: break
            }
            self?.rebuild()
            done(true)
        }
        if case .suggestion = row { return nil }
        if case .clearSearchHistory = row { return nil }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// Keyboard accessory: quick-input characters and quick search engines.
final class QuickSearchBar: UIInputView {
    init(isPrivate: Bool, onInsert: @escaping (String) -> Void, onEngine: @escaping (SearchEngine) -> Void) {
        let showChars = Prefs.showQuickInput
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: showChars ? 88 : 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pinEdges(to: self)

        if showChars {
            let chars = UIStackView()
            chars.distribution = .fillEqually
            chars.spacing = 6
            chars.isLayoutMarginsRelativeArrangement = true
            chars.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 2, right: 6)
            for c in ["https://", "www.", "m.", "/", ".", ".com", ".vn"] {
                let b = UIButton(type: .system, primaryAction: UIAction { _ in
                    UIDevice.current.playInputClick()
                    onInsert(c)
                })
                b.setTitle(c, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                b.tintColor = .label
                b.backgroundColor = UIColor.dynamic(light: .white, dark: UIColor(hex: 0x6B6B6E))
                b.layer.cornerRadius = 6
                chars.addArrangedSubview(b)
            }
            chars.heightAnchor.constraint(equalToConstant: 42).isActive = true
            stack.addArrangedSubview(chars)
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let engines = UIStackView()
        engines.spacing = 8
        engines.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(engines)
        NSLayoutConstraint.activate([
            engines.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            engines.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            engines.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            engines.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            engines.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
        for e in SearchEngineStore.shared.quickEngines {
            var cfg = UIButton.Configuration.filled()
            cfg.title = e.name
            cfg.baseBackgroundColor = e.color.withAlphaComponent(0.14)
            cfg.baseForegroundColor = e.color
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a; a.font = .systemFont(ofSize: 13, weight: .semibold); return a
            }
            let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in onEngine(e) })
            engines.addArrangedSubview(b)
        }
        scroll.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension QuickSearchBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
