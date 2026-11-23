import UIKit

/// First-launch setup: the user's language (target of page translation and live subtitles),
/// how subtitles are shown, and the offline language packs to download.
final class OnboardingViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Step: Int, CaseIterable { case welcome, language, subtitles, packs }

    private var step: Step = .welcome
    private var target: String = OnboardingViewController.defaultTarget()
    private var mode: SubtitleMode = .translation
    private var packStatus: [String: TranslationService.PackStatus] = [:]

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let iconView = UIImageView()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let primaryButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    private let dots = UIPageControl()

    private static let packSources = ["en", "ja", "zh-Hans"]

    static func defaultTarget() -> String {
        for id in Locale.preferredLanguages {
            let code = TranslateLanguages.normalize(id)
            if TranslateLanguages.all.contains(where: { $0.code == code }), code != "en" { return code }
        }
        return "vi"
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        iconView.image = UIImage(named: "AppIcon-Preview")
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 22
        iconView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.register(UITableViewCell.self, forCellReuseIdentifier: "c")

        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .large
        cfg.baseBackgroundColor = Theme.accent
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        primaryButton.configuration = cfg
        primaryButton.addTarget(self, action: #selector(goNext), for: .touchUpInside)
        skipButton.setTitle(L("Skip"), for: .normal)
        skipButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        dots.numberOfPages = Step.allCases.count
        dots.currentPageIndicatorTintColor = Theme.accent
        dots.pageIndicatorTintColor = .systemGray4
        dots.isUserInteractionEnabled = false

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 10
        header.alignment = .center
        header.setCustomSpacing(18, after: iconView)

        [header, table, primaryButton, skipButton, dots].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
            header.topAnchor.constraint(equalTo: g.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -28),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: dots.topAnchor, constant: -6),
            dots.bottomAnchor.constraint(equalTo: primaryButton.topAnchor, constant: -10),
            dots.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            primaryButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            primaryButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
            primaryButton.bottomAnchor.constraint(equalTo: skipButton.topAnchor, constant: -4),
            skipButton.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            skipButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -8),
        ])
        render()
    }

    private func render() {
        dots.currentPage = step.rawValue
        iconView.isHidden = step != .welcome
        skipButton.isHidden = step == .packs
        var title = L("Continue")
        switch step {
        case .welcome:
            titleLabel.text = L("Welcome to FAbrowser")
            subtitleLabel.text = L("Fast, private and ad-free. Videos float while you browse, pages and video speech are translated on your device.")
            title = L("Get Started")
        case .language:
            titleLabel.text = L("Your Language")
            subtitleLabel.text = L("Web pages and live subtitles will be translated into this language.")
        case .subtitles:
            titleLabel.text = L("Live Subtitles")
            subtitleLabel.text = L("Speech in videos (English, Japanese, Chinese…) becomes subtitles in your language. How should they look?")
        case .packs:
            titleLabel.text = L("Offline Language Packs")
            subtitleLabel.text = TranslationService.isAvailable
                ? L("Download the languages you watch and read most. Translation then works without internet.")
                : TranslationError.unavailableOS.localizedDescription
            title = L("Start Browsing")
            refreshPacks()
        }
        primaryButton.configuration?.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]))
        table.reloadData()
        if table.numberOfSections > 0, table.numberOfRows(inSection: 0) > 0 { table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false) }
    }

    @objc private func goNext() {
        guard let n = Step(rawValue: step.rawValue + 1) else { finish(); return }
        step = n
        UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve) { self.render() }
    }

    @objc private func finish() {
        Prefs.translateTarget = target
        Prefs.subtitleModeRaw = mode.rawValue
        Prefs.onboarded = true
        dismiss(animated: true)
    }

    private func refreshPacks() {
        Task { @MainActor in
            for src in Self.packSources where src != target {
                packStatus[src] = await TranslationService.shared.status(from: src, to: target)
            }
            if step == .packs { table.reloadData() }
        }
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { step == .welcome ? 1 : 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch step {
        case .welcome: return 4
        case .language: return TranslateLanguages.all.count
        case .subtitles: return SubtitleMode.allCases.count
        case .packs: return Self.packSources.filter { $0 != target }.count
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch step {
        case .subtitles: return L("You can change this later in Settings › Live Subtitles.")
        case .packs: return TranslationService.isAvailable ? L("iOS asks for confirmation before downloading. Packs can be removed in the iOS Settings app.") : nil
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .default
        switch step {
        case .welcome:
            let items: [(String, String, String)] = [
                ("pip.fill", L("Video Floating"), L("Play videos in a floating window, picture in picture and fullscreen gestures.")),
                ("character.bubble.fill", L("Offline Translation"), L("Translate whole pages on device. Nothing is sent to Google.")),
                ("captions.bubble.fill", L("Live Subtitles"), L("Subtitles for any video, translated into your language.")),
                ("shield.lefthalf.filled", L("Ad Block"), L("Built-in EasyList and ABPVN, pop-up and video ad blocking.")),
            ]
            let it = items[ip.row]
            c.image = Theme.symbol(it.0, size: 20, weight: .semibold)
            c.imageProperties.tintColor = Theme.accent
            c.text = it.1
            c.secondaryText = it.2
            c.secondaryTextProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        case .language:
            let lang = TranslateLanguages.all[ip.row]
            c.text = lang.name
            let local = Locale.current.localizedString(forIdentifier: lang.code)
            if let local, local != lang.name { c.secondaryText = local }
            c.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = lang.code == target ? .checkmark : .none
        case .subtitles:
            let m = SubtitleMode.allCases[ip.row]
            c.text = m.title
            c.secondaryText = Self.example(for: m, target: target)
            c.secondaryTextProperties.color = .secondaryLabel
            c.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = m == mode ? .checkmark : .none
        case .packs:
            let src = Self.packSources.filter { $0 != target }[ip.row]
            c.text = TranslateLanguages.name(src) + " → " + TranslateLanguages.name(target)
            let label = UILabel()
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            switch packStatus[src] {
            case .installed: label.text = L("Downloaded"); label.textColor = .systemGreen
            case .downloadable: label.text = L("Download"); label.textColor = Theme.accent
            case .unsupported: label.text = L("Not Supported"); label.textColor = .secondaryLabel
            case .unavailableOS: label.text = L("iOS 18+"); label.textColor = .secondaryLabel
            case nil: label.text = "…"; label.textColor = .secondaryLabel
            }
            label.sizeToFit()
            cell.accessoryView = label
        }
        cell.contentConfiguration = c
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch step {
        case .welcome: return
        case .language:
            target = TranslateLanguages.all[ip.row].code
            packStatus = [:]
        case .subtitles:
            mode = SubtitleMode.allCases[ip.row]
        case .packs:
            let src = Self.packSources.filter { $0 != target }[ip.row]
            guard TranslationService.isAvailable, packStatus[src] == .downloadable else { return }
            Task { @MainActor in
                do { try await TranslationService.shared.prepare(from: src, to: target, presenter: self) } catch {
                    self.showAlert(L("Translate"), message: error.localizedDescription)
                }
                self.refreshPacks()
            }
        }
        tableView.reloadData()
    }

    private static func example(for m: SubtitleMode, target: String) -> String {
        let original = "It's a beautiful day, isn't it?"
        let translated: String = [
            "vi": "Hôm nay trời đẹp nhỉ?", "zh-Hans": "今天天气真好，不是吗？", "zh-Hant": "今天天氣真好，不是嗎？", "ja": "いい天気ですね。",
            "ko": "날씨가 정말 좋네요, 그렇죠?", "fr": "Quelle belle journée, n'est-ce pas ?", "de": "Was für ein schöner Tag, oder?",
            "es": "Hace un día precioso, ¿verdad?",
        ][target] ?? original
        switch m {
        case .translation: return translated
        case .bilingual: return translated + "\n" + original
        case .original: return original
        }
    }
}
