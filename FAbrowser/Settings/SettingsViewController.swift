import UIKit
import WebKit
import PhotosUI
import LocalAuthentication

/// Declarative settings row model. Every page of Settings is built from these.
struct SettingRow {
    enum Kind {
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case choice(options: [String], get: () -> Int, set: (Int) -> Void)
        case nav(detail: () -> String?, action: (SettingsViewController) -> Void)
        case action(destructive: Bool, action: (SettingsViewController) -> Void)
        case slider(min: Float, max: Float, get: () -> Float, set: (Float) -> Void)
        case info(detail: String)
    }

    var title: String
    var symbol: String?
    var color: UIColor = Theme.accent
    var kind: Kind
    var image: UIImage?

    static func toggle(_ title: String, _ symbol: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> SettingRow {
        SettingRow(title: title, symbol: symbol, kind: .toggle(get: get, set: set))
    }
    static func nav(_ title: String, _ symbol: String? = nil, color: UIColor = Theme.accent, detail: @escaping () -> String? = { nil }, action: @escaping (SettingsViewController) -> Void) -> SettingRow {
        SettingRow(title: title, symbol: symbol, color: color, kind: .nav(detail: detail, action: action))
    }
    static func page(_ title: String, _ symbol: String, color: UIColor, _ page: SettingsViewController.Page, detail: @escaping () -> String? = { nil }) -> SettingRow {
        nav(title, symbol, color: color, detail: detail) { vc in vc.push(page) }
    }
    static func choice(_ title: String, _ options: [String], get: @escaping () -> Int, set: @escaping (Int) -> Void) -> SettingRow {
        SettingRow(title: title, kind: .choice(options: options, get: get, set: set))
    }
    static func action(_ title: String, destructive: Bool = false, _ action: @escaping (SettingsViewController) -> Void) -> SettingRow {
        SettingRow(title: title, kind: .action(destructive: destructive, action: action))
    }
}

struct SettingSection {
    var title: String?
    var footer: String?
    var rows: [SettingRow]
}

final class SettingsViewController: UITableViewController, PHPickerViewControllerDelegate {
    enum Page {
        case root, general, search, searchEngines, homepage, display, gestures, privacy, clearData, adBlock, subscriptions, whitelist, video, translate, subtitles, userAgent, appIcon, backup, about
    }

    weak var browser: BrowserViewController?
    let page: Page
    private var sections: [SettingSection] = []

    init(page: Page) {
        self.page = page
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if page == .root {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        }
        if page == .searchEngines {
            navigationItem.rightBarButtonItems = [UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addEngine)), editButtonItem]
        }
        if page == .subscriptions {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSubscription))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .searchEnginesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .adBlockRulesChanged, object: nil)
        if page == .subtitles { NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: SenseVoiceModel.changed, object: nil) }
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: "translateTarget", queue: .main) { [weak self] _ in self?.refreshPackStatus() }
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
        refreshPackStatus()
    }

    @objc private func close() { dismiss(animated: true) }

    func push(_ page: Page) {
        let vc = SettingsViewController(page: page)
        vc.browser = browser
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc func rebuild() {
        title = Self.title(of: page)
        sections = build()
        tableView.reloadData()
    }

    static func title(of page: Page) -> String {
        switch page {
        case .root: return L("Settings")
        case .general: return L("General")
        case .search: return L("Search")
        case .searchEngines: return L("Search Engine")
        case .homepage: return L("Homepage")
        case .display: return L("Display")
        case .gestures: return L("Toolbar & Gestures")
        case .privacy: return L("Privacy & Security")
        case .clearData: return L("Clear Data")
        case .adBlock: return L("Ad Block")
        case .subscriptions: return L("Filter Subscriptions")
        case .whitelist: return L("Whitelist")
        case .video: return L("Video")
        case .translate: return L("Translate")
        case .subtitles: return L("Live Subtitles")
        case .userAgent: return L("User Agent")
        case .appIcon: return L("App Icon")
        case .backup: return L("Backup & Restore")
        case .about: return L("About")
        }
    }

    // MARK: Page definitions

    private func build() -> [SettingSection] {
        switch page {
        case .root:
            return [
                SettingSection(rows: [
                    .page(L("General"), "gearshape.fill", color: .systemGray, .general),
                    .page(L("Search"), "magnifyingglass", color: .systemBlue, .search, detail: { SearchEngineStore.shared.current.name }),
                    .page(L("Homepage"), "house.fill", color: .systemOrange, .homepage, detail: { Prefs.homepageMode.title }),
                    .page(L("Display"), "textformat.size", color: .systemIndigo, .display, detail: { Prefs.themeMode.title }),
                    .page(L("Toolbar & Gestures"), "hand.draw.fill", color: .systemTeal, .gestures),
                ]),
                SettingSection(rows: [
                    .page(L("Ad Block"), "shield.lefthalf.filled", color: Theme.shieldGreen, .adBlock, detail: { Prefs.adBlock ? L("On") : L("Off") }),
                    .page(L("Privacy & Security"), "hand.raised.fill", color: .systemBlue, .privacy),
                    .page(L("Clear Data"), "trash.fill", color: .systemRed, .clearData),
                ]),
                SettingSection(rows: [
                    .page(L("Video"), "play.rectangle.fill", color: .systemPink, .video, detail: { Self.rateTitle(Prefs.playbackRate) }),
                    .page(L("Translate"), "character.bubble.fill", color: .systemBlue, .translate, detail: { TranslateLanguages.name(Prefs.translateTarget) }),
                    .page(L("Live Subtitles"), "captions.bubble.fill", color: .systemIndigo, .subtitles, detail: { LiveSubtitles.shared.mode.title }),
                    .page(L("User Agent"), "person.text.rectangle.fill", color: .systemBrown, .userAgent),
                    .nav(L("JavaScript Extensions"), "puzzlepiece.extension.fill", color: .systemPurple, detail: { "\(JSExtensionStore.shared.extensions.count)" }) { vc in
                        vc.navigationController?.pushViewController(ExtensionsViewController(), animated: true)
                    },
                    .nav(L("Files"), "folder.fill", color: .systemCyan) { vc in
                        let files = FilesViewController(directory: FileManager.default.documentsURL)
                        files.onOpenWeb = { [weak b = vc.browser] url in b?.openInNewTab(url) }
                        vc.navigationController?.pushViewController(files, animated: true)
                    },
                ]),
                SettingSection(rows: [
                    .page(L("App Icon"), "app.badge.fill", color: .systemGreen, .appIcon),
                    .page(L("Backup & Restore"), "arrow.triangle.2.circlepath", color: .systemGray, .backup),
                    .nav(L("Language"), "globe", color: .systemBlue) { _ in
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    },
                    .page(L("About"), "info.circle.fill", color: .systemGray, .about, detail: { Bundle.main.shortVersion }),
                ]),
            ]

        case .general:
            return [
                SettingSection(title: L("Tabs"), rows: [
                    .toggle(L("Reopen tabs on launch"), get: { Prefs.reopenTabs }, set: { Prefs.reopenTabs = $0 }),
                    .toggle(L("Open Click Link in New Tab"), get: { Prefs.openClickLinkInNewTab }, set: { Prefs.openClickLinkInNewTab = $0 }),
                    .toggle(L("Prefer current tab when opening from other apps"), get: { Prefs.preferCurrentTab }, set: { Prefs.preferCurrentTab = $0 }),
                    .toggle(L("Open long-press links in background"), get: { Prefs.openInBackground }, set: { Prefs.openInBackground = $0 }),
                    .toggle(L("Block Popups"), get: { Prefs.blockPopups }, set: { Prefs.blockPopups = $0 }),
                ]),
                SettingSection(title: L("Page"), footer: L("Detect phone numbers, addresses and dates in web pages."), rows: [
                    .toggle(L("Pull to Refresh"), get: { Prefs.pullToRefresh }, set: { Prefs.pullToRefresh = $0 }),
                    .toggle(L("Detect Data"), get: { Prefs.autoDetectData }, set: { Prefs.autoDetectData = $0 }),
                    .toggle(L("Remove line breaks when copying page text"), get: { Prefs.removeLineBreaks }, set: { Prefs.removeLineBreaks = $0 }),
                ]),
                SettingSection(rows: [
                    .page(L("Translate"), "character.bubble.fill", color: .systemBlue, .translate, detail: { TranslateLanguages.name(Prefs.translateTarget) }),
                ]),
            ]

        case .search:
            return [
                SettingSection(rows: [
                    .page(L("Search Engine"), "magnifyingglass", color: .systemBlue, .searchEngines, detail: { SearchEngineStore.shared.current.name }),
                ]),
                SettingSection(title: L("Address Bar"), rows: [
                    .toggle(L("Domain Auto Completion"), get: { Prefs.domainAutoCompletion }, set: { Prefs.domainAutoCompletion = $0 }),
                    .toggle(L("Search Suggestions"), get: { Prefs.searchSuggestions }, set: { Prefs.searchSuggestions = $0 }),
                    .toggle(L("Match History & Bookmarks"), get: { Prefs.matchHistory }, set: { Prefs.matchHistory = $0 }),
                    .toggle(L("Show Copied Link"), get: { Prefs.autoPasteCopied }, set: { Prefs.autoPasteCopied = $0 }),
                    .toggle(L("Quick Input Bar"), get: { Prefs.showQuickInput }, set: { Prefs.showQuickInput = $0 }),
                ]),
                SettingSection(title: L("Search History"), rows: [
                    .toggle(L("Record Search History"), get: { Prefs.recordSearchHistory }, set: { Prefs.recordSearchHistory = $0 }),
                    .toggle(L("Show History When Search Starts"), get: { Prefs.showHistoryOnSearchStart }, set: { Prefs.showHistoryOnSearchStart = $0 }),
                    .action(L("Clear Search History"), destructive: true) { vc in
                        vc.confirm(L("Clear Search History"), action: L("Clear"), destructive: true) { HistoryStore.shared.clearSearches(); Toast.show(L("Cleared")) }
                    },
                ]),
            ]

        case .searchEngines:
            return [] // custom table below

        case .homepage:
            var rows: [SettingRow] = [
                .choice(L("Homepage"), HomepageMode.allCases.map(\.title), get: { Prefs.homepageModeRaw }, set: { Prefs.homepageModeRaw = $0 }),
            ]
            if Prefs.homepageMode == .customURL {
                rows.append(.nav(L("Homepage URL"), detail: { Prefs.homepageURL.isEmpty ? L("Not Set") : Prefs.homepageURL }) { vc in
                    vc.promptText(L("Homepage URL"), placeholders: ["https://"], values: [Prefs.homepageURL], keyboard: .URL) { v in
                        if let s = v.first, let u = URL.fromUserInput(s) { Prefs.homepageURL = u.absoluteString }
                        vc.rebuild()
                    }
                })
                rows.append(.nav(L("Use Current Page")) { vc in
                    if let u = vc.browser?.currentWebView?.url { Prefs.homepageURL = u.absoluteString; vc.rebuild() }
                })
            }
            return [
                SettingSection(rows: rows),
                SettingSection(title: L("Navigation Page"), rows: [
                    .toggle(L("Centered Search Box"), get: { Prefs.centeredSearchBox }, set: { Prefs.centeredSearchBox = $0 }),
                    .toggle(L("Bottom Search Button"), get: { Prefs.bottomSearchButton }, set: { Prefs.bottomSearchButton = $0 }),
                    .toggle(L("Pull Down to Search"), get: { Prefs.pullDownToSearch }, set: { Prefs.pullDownToSearch = $0 }),
                    .choice(L("Columns"), ["3", "4", "5", "6"], get: { max(0, Prefs.homeColumns - 3) }, set: { Prefs.homeColumns = $0 + 3 }),
                    SettingRow(title: L("Icon Corner Radius"), kind: .slider(min: 0, max: 30, get: { Float(Prefs.iconCornerRadius) }, set: { Prefs.iconCornerRadius = Double($0) })),
                    .action(L("Reset Navigation Sites"), destructive: true) { vc in
                        vc.confirm(L("Reset Navigation Sites"), action: L("Reset"), destructive: true) { BookmarkStore.shared.resetHomeSites() }
                    },
                ]),
                SettingSection(title: L("Wallpaper"), rows: [
                    .nav(L("Choose Wallpaper"), detail: { Wallpaper.image == nil ? L("None") : nil }) { vc in vc.pickWallpaper() },
                    SettingRow(title: L("Wallpaper Mask"), kind: .slider(min: 0, max: 0.8, get: { Float(Prefs.wallpaperAlpha) }, set: { Prefs.wallpaperAlpha = Double($0) })),
                    .action(L("Remove Wallpaper"), destructive: true) { vc in Wallpaper.set(nil); vc.rebuild() },
                ]),
            ]

        case .display:
            return [
                SettingSection(title: L("Appearance"), rows: [
                    .choice(L("Theme"), ThemeMode.allCases.map(\.title), get: { Prefs.themeModeRaw }, set: { Prefs.themeModeRaw = $0 }),
                    .toggle(L("Night Mode"), get: { Prefs.nightMode }, set: { Prefs.nightMode = $0 }),
                    .toggle(L("Apply dark theme to web pages"), get: { Prefs.applyDarkToWebpage }, set: { Prefs.applyDarkToWebpage = $0 }),
                    .toggle(L("Webpage Green Background"), get: { Prefs.eyeCare }, set: { Prefs.eyeCare = $0 }),
                ]),
                SettingSection(title: L("Page"), rows: [
                    .choice(L("Page Zoom"), Self.zooms.map { "\($0)%" }, get: { Self.zooms.firstIndex(of: Prefs.pageZoom) ?? 3 }, set: { Prefs.pageZoom = Self.zooms[$0] }),
                    .toggle(L("Text-Only"), get: { Prefs.noImage }, set: { Prefs.noImage = $0 }),
                    .toggle(L("Fullscreen"), get: { Prefs.fullscreen }, set: { Prefs.fullscreen = $0 }),
                    .toggle(L("Hide toolbars when scrolling"), get: { Prefs.hideToolbarsOnScroll }, set: { Prefs.hideToolbarsOnScroll = $0 }),
                ]),
                SettingSection(title: L("Tabs Bar"), rows: [
                    .toggle(L("Show Tabs Bar"), get: { Prefs.showTopTabs }, set: { Prefs.showTopTabs = $0 }),
                    .toggle(L("Show Tabs Bar with one tab"), get: { Prefs.showTopTabsOneTab }, set: { Prefs.showTopTabsOneTab = $0 }),
                ]),
            ]

        case .gestures:
            return [
                SettingSection(title: L("Toolbar"), footer: L("Every toolbar button supports long press: Back/Forward show history, Menu opens Toolbox, Tabs shows tab actions, Home opens bookmarks."), rows: [
                    .toggle(L("Swap Home and Tabs buttons"), get: { Prefs.swapHomeAndTab }, set: { Prefs.swapHomeAndTab = $0 }),
                    .toggle(L("Forward goes to next page"), get: { Prefs.forwardPrefersNextPage }, set: { Prefs.forwardPrefersNextPage = $0 }),
                ]),
                SettingSection(title: L("Gestures"), footer: L("Tap the top or bottom part of the page to scroll one screen."), rows: [
                    .toggle(L("Swipe back from anywhere"), get: { Prefs.swipeBackAnywhere }, set: { Prefs.swipeBackAnywhere = $0 }),
                    .toggle(L("Touch to Turn Page"), get: { Prefs.touchToTurnPage }, set: { Prefs.touchToTurnPage = $0 }),
                    .toggle(L("Show Page Up/Down Buttons"), get: { Prefs.showPageUpDown }, set: { Prefs.showPageUpDown = $0 }),
                ]),
            ]

        case .privacy:
            return [
                SettingSection(title: L("Security"), footer: L("Require Face ID / Touch ID / passcode when opening FAbrowser."), rows: [
                    .toggle(L("App Lock"), get: { Prefs.requireUnlock }, set: { [weak self] on in self?.setAppLock(on) }),
                    .toggle(L("Blur tabs in App Switcher"), get: { Prefs.coverInBackground }, set: { Prefs.coverInBackground = $0 }),
                ]),
                SettingSection(footer: L("caro_lock_footer"), rows: [
                    .toggle(L("Caro Lock"), get: { Prefs.caroLockPattern != nil }, set: { [weak self] on in self?.setCaroLock(on) }),
                ] + (Prefs.caroLockPattern == nil ? [] : [
                    .nav(L("Change Unlock Moves")) { vc in vc.recordCaroMoves() },
                ])),
                SettingSection(title: L("Privacy"), rows: [
                    .toggle(L("Read Clipboard"), get: { Prefs.allowClipboardRead }, set: { Prefs.allowClipboardRead = $0 }),
                    .toggle(L("Clear history on exit"), get: { Prefs.clearHistoryOnExit }, set: { Prefs.clearHistoryOnExit = $0 }),
                    .toggle(L("Close private tabs on exit"), get: { Prefs.clearPrivateOnExit }, set: { Prefs.clearPrivateOnExit = $0 }),
                ]),
                SettingSection(rows: [.page(L("Clear Data"), "trash.fill", color: .systemRed, .clearData)]),
            ]

        case .clearData:
            return [
                SettingSection(footer: L("Clearing website data signs you out of websites."), rows: [
                    .action(L("Clear History")) { vc in vc.clear(.history) },
                    .action(L("Clear Search History")) { vc in vc.clear(.searches) },
                    .action(L("Clear Cache")) { vc in vc.clear(.cache) },
                    .action(L("Clear Cookies & Website Data")) { vc in vc.clear(.cookies) },
                    .action(L("Clear Favicons")) { vc in vc.clear(.favicons) },
                ]),
                SettingSection(rows: [.action(L("Clear All Data"), destructive: true) { vc in vc.clear(.all) }]),
            ]

        case .adBlock:
            return [
                SettingSection(footer: L("Blocks ads and trackers using content rules. Hidden elements are applied even when ad block is off."), rows: [
                    .toggle(L("Ad Block"), get: { Prefs.adBlock }, set: { Prefs.adBlock = $0 }),
                ]),
                SettingSection(footer: L("Intrusive ads are full-screen or floating ads. Pop-ups opened without a tap are blocked and can still be opened from the notice."), rows: [
                    .toggle(L("Block intrusive ads"), get: { Prefs.blockIntrusiveAds }, set: { Prefs.blockIntrusiveAds = $0 }),
                    .toggle(L("Block Pop-up Windows"), get: { Prefs.blockPopups }, set: { Prefs.blockPopups = $0 }),
                    .toggle(L("Skip Video Ads"), get: { Prefs.skipVideoAds }, set: { Prefs.skipVideoAds = $0 }),
                    .toggle(L("Block App Jump"), get: { Prefs.blockAppJump }, set: { Prefs.blockAppJump = $0 }),
                ]),
                SettingSection(rows: [
                    .page(L("Filter Subscriptions"), "list.bullet.rectangle.fill", color: .systemOrange, .subscriptions,
                          detail: { "\(AdBlocker.shared.subscriptions.filter(\.enabled).count)" }),
                    .page(L("Whitelist"), "checkmark.shield.fill", color: Theme.shieldGreen, .whitelist, detail: { "\(AdBlocker.shared.whitelist.count)" }),
                    .nav(L("User Hide Ad"), "eye.slash.fill", color: .systemGray, detail: { "\(AdBlocker.shared.userRuleCount)" }) { vc in
                        vc.navigationController?.pushViewController(HiddenElementsViewController(host: nil), animated: true)
                    },
                ]),
                SettingSection(footer: L("EasyList and ABPVN are built in and work offline. Enabled lists are refreshed every 4 days."), rows: [
                    .toggle(L("Auto Update Filters"), get: { Prefs.filterAutoUpdate }, set: { Prefs.filterAutoUpdate = $0 }),
                    .action(L("Update All Filters Now")) { vc in
                        let subs = AdBlocker.shared.subscriptions.filter(\.enabled)
                        Toast.show(L("Updating…"))
                        var left = subs.count, failed = 0
                        for s in subs {
                            AdBlocker.shared.update(subscription: s.id) { r in
                                if case .failure = r { failed += 1 }
                                left -= 1
                                if left == 0 { Toast.show(failed == 0 ? L("Filters Updated") : L("Update Failed")); vc.rebuild() }
                            }
                        }
                    },
                    .action(L("Clear All Rules"), destructive: true) { vc in
                        vc.confirm(L("Clear All Rules"), message: L("Removes all user hide rules and the whitelist."), action: L("Clear"), destructive: true) {
                            AdBlocker.shared.clearUserRules()
                            AdBlocker.shared.whitelist.forEach { AdBlocker.shared.setWhitelisted($0, false) }
                            vc.rebuild()
                        }
                    },
                ]),
            ]

        case .subscriptions:
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            return [SettingSection(footer: L("Tap a subscription to update it. Swipe to delete."), rows: AdBlocker.shared.subscriptions.map { sub in
                SettingRow(title: sub.title, kind: .toggle(get: { sub.enabled }, set: { on in
                    var list = AdBlocker.shared.subscriptions
                    if let i = list.firstIndex(where: { $0.id == sub.id }) { list[i].enabled = on }
                    AdBlocker.shared.setSubscriptions(list)
                    if on, sub.lastUpdate == nil { AdBlocker.shared.update(subscription: sub.id) { _ in } }
                }))
            })]

        case .whitelist:
            return [SettingSection(footer: L("Ad block is disabled on these sites. Swipe to delete."), rows:
                AdBlocker.shared.whitelist.map { h in SettingRow(title: h, kind: .info(detail: "")) } + [
                    .action(L("Add Site")) { vc in
                        vc.promptText(L("Add Site"), placeholders: ["example.com"], keyboard: .URL) { v in
                            if let h = v.first?.trimmed.lowercased(), !h.isEmpty { AdBlocker.shared.setWhitelisted(URL.fromUserInput(h)?.host ?? h, true) }
                            vc.rebuild()
                        }
                    },
                ])]

        case .video:
            return [
                SettingSection(title: L("Video Floating"), footer: L("Videos open in a floating window as soon as they start playing; video ads are left to finish first. Swipe sideways to seek, swipe up or down on the left for volume and on the right for brightness, swipe the middle up to close or down to shrink. In the small window: drag to move, swipe right to close, double tap to go back. Long press the floating video button to turn this on or off."), rows: [
                    .toggle(L("Video Floating"), get: { Prefs.videoFloating }, set: { Prefs.videoFloating = $0 }),
                    .toggle(L("Allow Auto Replace Playing"), get: { Prefs.allowAutoReplace }, set: { Prefs.allowAutoReplace = $0 }),
                    .toggle(L("Resume Playback"), get: { Prefs.resumePlayback }, set: { Prefs.resumePlayback = $0 }),
                ]),
                SettingSection(title: L("Loading"), footer: L("Downloads videos over several connections at once and fetches upcoming HLS segments ahead of time, so videos start sooner and seeking is smoother on the same connection. Turn off if a site's video won't play."), rows: [
                    .toggle(L("Video Acceleration"), get: { Prefs.videoAccelerate }, set: { Prefs.videoAccelerate = $0 }),
                ]),
                SettingSection(title: L("Playback"), footer: L("Long press the video to play fast; double tap the left or right side to seek 5 seconds; two-finger tap to change the video gravity; pinch to zoom."), rows: [
                    .choice(L("Playback Speed"), Self.rates.map(Self.rateTitle), get: { Self.rates.firstIndex(of: Prefs.playbackRate) ?? 2 }, set: { Prefs.playbackRate = Self.rates[$0] }),
                    .choice(L("Long Press Speed"), Self.boostRates.map(Self.rateTitle), get: { Self.boostRates.firstIndex(of: Prefs.longPressSpeed) ?? 3 }, set: { Prefs.longPressSpeed = Self.boostRates[$0] }),
                    .toggle(L("Background Play"), get: { Prefs.backgroundPlay }, set: { Prefs.backgroundPlay = $0 }),
                    .toggle(L("Auto Picture in Picture"), get: { Prefs.autoPiP }, set: { Prefs.autoPiP = $0 }),
                    .toggle(L("Display Time and Battery"), get: { Prefs.showTimeBattery }, set: { Prefs.showTimeBattery = $0 }),
                ]),
                SettingSection(title: L("Compatibility"), footer: L("Makes websites deliver plain MP4/HLS video instead of streaming it in pieces, so more videos can open in the floating player. Turn off if a site's player breaks."), rows: [
                    .toggle(L("Video Compatibility Mode"), get: { Prefs.videoCompatMode }, set: { Prefs.videoCompatMode = $0 }),
                ]),
            ]

        case .translate:
            var packRows: [SettingRow] = []
            let target = TranslateLanguages.normalize(Prefs.translateTarget)
            for src in Self.packSources where src != target {
                packRows.append(.nav(TranslateLanguages.name(src) + " → " + TranslateLanguages.name(target), detail: { Self.packStatusText(src, target) }) { vc in
                    vc.downloadPack(from: src, to: target)
                })
            }
            return [
                SettingSection(footer: L("Translation runs on device with Apple's offline translator (iOS 18+). No page content is sent to Google or any server."), rows: [
                    .choice(L("Translate to"), TranslateLanguages.all.map(\.name), get: { TranslateLanguages.all.firstIndex { $0.code == target } ?? 0 },
                            set: { Prefs.translateTarget = TranslateLanguages.all[$0].code }),
                    .toggle(L("Keep translating new pages"), get: { Prefs.translateAutoContinue }, set: { Prefs.translateAutoContinue = $0 }),
                    .toggle(L("Offer to translate foreign pages"), get: { Prefs.translateSuggest }, set: { Prefs.translateSuggest = $0 }),
                ]),
                SettingSection(footer: L("Pages in these languages are translated automatically. Translations are cached on the device so revisited pages appear instantly."), rows: [
                    .nav(L("Always Translate"), detail: { Prefs.autoTranslateLangs.isEmpty ? L("None") : Prefs.autoTranslateLangs.map { TranslateLanguages.name($0) }.sorted().joined(separator: ", ") }) { vc in
                        vc.editAutoTranslateLanguages()
                    },
                    .action(L("Clear Translation Cache")) { _ in
                        TranslationCache.shared.clear()
                        Toast.show(L("Cleared"))
                    },
                ]),
                SettingSection(title: L("Language Packs"), footer: TranslationService.isAvailable ? L("Download the packs you need once; translation then works offline. Packs are managed by iOS in Settings › Apps › Translate.") : TranslationError.unavailableOS.localizedDescription, rows: packRows),
            ]

        case .subtitles:
            return [
                SettingSection(footer: L("Turns the speech in a playing video into subtitles and translates them into your language, on device. Start it from the Toolbox or the subtitles button of the floating player."), rows: [
                    .choice(L("Spoken Language"), SubtitleLanguages.sources.map(\.name), get: { SubtitleLanguages.sources.firstIndex { $0.code == Prefs.subtitleSource } ?? 0 },
                            set: { Prefs.subtitleSource = SubtitleLanguages.sources[$0].code; LiveSubtitles.shared.restartRecognition() }),
                    .choice(L("Display"), SubtitleMode.allCases.map(\.title), get: { Prefs.subtitleModeRaw }, set: { Prefs.subtitleModeRaw = $0 }),
                    .nav(L("Translate to"), detail: { TranslateLanguages.name(Prefs.translateTarget) }) { vc in vc.push(.translate) },
                    SettingRow(title: L("Font Size"), kind: .slider(min: 12, max: 30, get: { Float(Prefs.subtitleFontSize) }, set: { Prefs.subtitleFontSize = Double($0.rounded()) })),
                ]),
                SettingSection(title: L("Speech Recognition"), footer: L("SenseVoice is a free model that runs on the device. It is far more accurate for Chinese, English, Japanese, Korean and Cantonese, adds punctuation and detects which of them is spoken in about a second. Other languages use Apple's recognizer (its newest on-device model on iOS 26)."), rows: [
                    .choice(L("Engine"), Self.speechEngines.map(\.name), get: { Self.speechEngines.firstIndex { $0.code == Prefs.subtitleEngine } ?? 0 },
                            set: { Prefs.subtitleEngine = Self.speechEngines[$0].code; LiveSubtitles.shared.restartRecognition() }),
                    .nav(L("SenseVoice Model"), detail: { SenseVoiceModel.statusText }) { vc in vc.manageSenseVoiceModel() },
                ]),
            ]

        case .userAgent:
            return [
                SettingSection(title: L("Mobile"), rows: [
                    .choice(L("Mobile User Agent"), UserAgent.mobileOptions, get: { Prefs.mobileUA }, set: { Prefs.mobileUA = $0 }),
                    .nav(L("Custom"), detail: { Prefs.customMobileUA.isEmpty ? L("Not Set") : Prefs.customMobileUA }) { vc in
                        vc.promptText(L("Custom") + " UA", placeholders: ["Mozilla/5.0 …"], values: [Prefs.customMobileUA]) { v in Prefs.customMobileUA = v.first ?? ""; vc.rebuild() }
                    },
                ]),
                SettingSection(title: L("Desktop"), rows: [
                    .choice(L("Desktop User Agent"), UserAgent.desktopOptions, get: { Prefs.desktopUA }, set: { Prefs.desktopUA = $0 }),
                    .nav(L("Custom"), detail: { Prefs.customDesktopUA.isEmpty ? L("Not Set") : Prefs.customDesktopUA }) { vc in
                        vc.promptText(L("Custom") + " UA", placeholders: ["Mozilla/5.0 …"], values: [Prefs.customDesktopUA]) { v in Prefs.customDesktopUA = v.first ?? ""; vc.rebuild() }
                    },
                    .toggle(L("Open new tabs in desktop mode"), get: { Prefs.openNewTabInDesktop }, set: { Prefs.openNewTabInDesktop = $0 }),
                ]),
            ]

        case .appIcon:
            return [SettingSection(rows: AppIcon.allCases.map { icon in
                var row = SettingRow.nav(icon.title, detail: { AppIcon.current == icon ? "✓" : nil }) { vc in
                    UIApplication.shared.setAlternateIconName(icon.iconName) { err in
                        DispatchQueue.main.async { if let err { Toast.show(err.localizedDescription) }; vc.rebuild() }
                    }
                }
                row.image = icon.preview
                return row
            })]

        case .backup:
            return [
                SettingSection(title: L("Bookmarks"), rows: [
                    .action(L("Export Bookmarks (HTML)")) { vc in
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FAbrowser-bookmarks.html")
                        try? BookmarkStore.shared.exportHTML().write(to: url, atomically: true, encoding: .utf8)
                        vc.share([url])
                    },
                ]),
                SettingSection(title: L("Settings"), footer: L("Backup contains settings, bookmarks, navigation sites, search engines and extensions."), rows: [
                    .action(L("Create Backup")) { vc in vc.createBackup() },
                    .action(L("Restore from Backup")) { vc in vc.restoreBackup() },
                    .action(L("Reset All Settings"), destructive: true) { vc in
                        vc.confirm(L("Reset All Settings"), message: L("Bookmarks and history are kept."), action: L("Reset"), destructive: true) {
                            if let id = Bundle.main.bundleIdentifier {
                                let keep = Prefs.lastCopiedURL
                                UserDefaults.standard.removePersistentDomain(forName: id)
                                Prefs.lastCopiedURL = keep
                            }
                            vc.rebuild()
                        }
                    },
                ]),
            ]

        case .about:
            return [
                SettingSection(footer: L("FAbrowser is a fast, private and extensible web browser."), rows: [
                    SettingRow(title: L("Version"), kind: .info(detail: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")),
                    SettingRow(title: L("Engine"), kind: .info(detail: "WebKit")),
                    SettingRow(title: L("Bookmarks"), kind: .info(detail: "\(BookmarkStore.shared.allBookmarkCount)")),
                    SettingRow(title: L("History"), kind: .info(detail: "\(HistoryStore.shared.items.count)")),
                ]),
            ]
        }
    }

    static let zooms = [50, 75, 85, 100, 115, 125, 150, 175, 200]
    static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]
    static func rateTitle(_ r: Double) -> String { r == 1 ? L("Normal") : String(format: "%gx", r) }
    static let boostRates: [Double] = [1.5, 2.0, 2.5, 3.0, 4.0]
    static let packSources = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "vi"]
    static var packStatus: [String: TranslationService.PackStatus] = [:]

    static func packStatusText(_ src: String, _ dst: String) -> String {
        switch packStatus[src + ">" + dst] {
        case .installed: return L("Downloaded")
        case .downloadable: return L("Download")
        case .unsupported: return L("Not Supported")
        case .unavailableOS: return L("iOS 18+")
        case nil: return "…"
        }
    }

    private func refreshPackStatus() {
        guard page == .translate else { return }
        let target = TranslateLanguages.normalize(Prefs.translateTarget)
        Task { @MainActor in
            for src in Self.packSources where src != target {
                Self.packStatus[src + ">" + target] = await TranslationService.shared.status(from: src, to: target)
            }
            self.rebuild()
        }
    }

    fileprivate func downloadPack(from src: String, to dst: String) {
        guard TranslationService.isAvailable else { showAlert(L("Translate"), message: TranslationError.unavailableOS.localizedDescription); return }
        if Self.packStatus[src + ">" + dst] == .installed { Toast.show(L("Downloaded")); return }
        Task { @MainActor in
            do {
                try await TranslationService.shared.prepare(from: src, to: dst, presenter: self)
            } catch {
                self.showAlert(L("Translate"), message: error.localizedDescription)
            }
            self.refreshPackStatus()
        }
    }

    static var speechEngines: [(code: String, name: String)] {
        [("auto", L("Automatic")), ("sensevoice", "SenseVoice")]
            + (SpeechEngine.modernAvailable ? [("apple", L("New Speech Model"))] : [])
            + [("basic", L("Basic Speech Model"))]
    }

    fileprivate func manageSenseVoiceModel() {
        if SenseVoiceModel.progress != nil {
            let sheet = UIAlertController(title: L("SenseVoice Model"), message: SenseVoiceModel.statusText, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: L("Cancel Download"), style: .destructive) { _ in SenseVoiceModel.cancel() })
            sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            presentSheet(sheet)
        } else if SenseVoiceModel.isDownloaded {
            let sheet = UIAlertController(title: L("SenseVoice Model"), message: SenseVoiceModel.statusText, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: L("Delete"), style: .destructive) { _ in
                SenseVoiceModel.delete()
                LiveSubtitles.shared.restartRecognition()
            })
            sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            presentSheet(sheet)
        } else {
            let a = UIAlertController(title: L("SenseVoice Model"), message: String(format: L("Download the SenseVoice speech model (%d MB, free, works offline)? It recognizes Chinese, English, Japanese, Korean and Cantonese far more accurately and detects the spoken language in about a second."), SenseVoiceModel.downloadMB), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            a.addAction(UIAlertAction(title: L("Download"), style: .default) { [weak self] _ in
                if LiveSubtitles.shared.isOn {
                    LiveSubtitles.shared.downloadSenseVoice()
                } else {
                    SenseVoiceModel.download { error in
                        if let error, !(error is CancellationError) { self?.showAlert(L("Couldn't download the speech model."), message: error.localizedDescription) }
                    }
                }
            })
            present(a, animated: true)
        }
    }

    fileprivate func editAutoTranslateLanguages() {
        let target = TranslateLanguages.normalize(Prefs.translateTarget)
        let sheet = UIAlertController(title: L("Always Translate"), message: L("Tap a language to turn it on or off."), preferredStyle: .actionSheet)
        for lang in TranslateLanguages.all where lang.code != target {
            let on = Prefs.autoTranslateLangs.contains(lang.code)
            sheet.addAction(UIAlertAction(title: lang.name + (on ? "  ✓" : ""), style: .default) { [weak self] _ in
                if on { Prefs.autoTranslateLangs.remove(lang.code) } else { Prefs.autoTranslateLangs.insert(lang.code) }
                self?.rebuild()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    // MARK: Actions

    private func setAppLock(_ on: Bool) {
        guard on else { Prefs.requireUnlock = false; return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            showAlert(L("App Lock"), message: L("Please set a passcode on this device first."))
            rebuild()
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Unlock FAbrowser")) { ok, _ in
            DispatchQueue.main.async {
                Prefs.requireUnlock = ok
                if ok { Prefs.caroLock = false }
                self.rebuild()
            }
        }
    }

    private func setCaroLock(_ on: Bool) {
        if on { recordCaroMoves() } else { Prefs.caroLock = false }
        rebuild()
    }

    fileprivate func recordCaroMoves() {
        let vc = CaroPatternViewController()
        vc.onSaved = { [weak self] in self?.rebuild() }
        navigationController?.pushViewController(vc, animated: true)
    }

    private enum ClearKind { case history, searches, cache, cookies, favicons, all }

    private func clear(_ kind: ClearKind) {
        let run = {
            let store = WKWebsiteDataStore.default()
            switch kind {
            case .history: HistoryStore.shared.clear(since: nil)
            case .searches: HistoryStore.shared.clearSearches()
            case .cache:
                URLCache.shared.removeAllCachedResponses()
                store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache], modifiedSince: .distantPast) {}
            case .cookies:
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            case .favicons: FaviconManager.shared.clearCache()
            case .all:
                HistoryStore.shared.clear(since: nil)
                HistoryStore.shared.clearSearches()
                URLCache.shared.removeAllCachedResponses()
                FaviconManager.shared.clearCache()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
            Toast.show(L("Cleared"))
        }
        confirm(L("Are you sure to clear?"), action: L("Clear"), destructive: true, handler: run)
    }

    fileprivate func pickWallpaper() {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { return }
        p.loadObject(ofClass: UIImage.self) { obj, _ in
            DispatchQueue.main.async {
                guard let img = obj as? UIImage else { return }
                let maxSide: CGFloat = 1600
                let scale = min(1, maxSide / max(img.size.width, img.size.height))
                Wallpaper.set(scale < 1 ? img.resized(to: CGSize(width: img.size.width * scale, height: img.size.height * scale)) : img)
                if Prefs.wallpaperAlpha < 0.05 { Prefs.wallpaperAlpha = 0.15 }
                self.rebuild()
            }
        }
    }

    // MARK: Search engines page

    @objc private func addEngine() {
        promptText(L("Add Search Engine"), message: L("Use %@ in the URL as the search keyword."), placeholders: [L("Name"), "https://example.com/search?q=%@"], keyboard: .URL) { [weak self] v in
            guard v.count == 2, !v[0].trimmed.isEmpty, v[1].contains("%@"), URL(string: v[1].replacingOccurrences(of: "%@", with: "x")) != nil else {
                Toast.show(L("Invalid URL")); return
            }
            SearchEngineStore.shared.add(SearchEngine(id: UUID().uuidString, name: v[0].trimmed, template: v[1].trimmed, isCustom: true))
            self?.rebuild()
        }
    }

    // MARK: Subscriptions

    @objc private func addSubscription() {
        promptText(L("Add Subscription"), message: L("Adblock Plus compatible filter list URL"), placeholders: [L("Name"), "https://"], keyboard: .URL) { [weak self] v in
            guard v.count == 2, let url = URL(string: v[1].trimmed), url.scheme?.hasPrefix("http") == true else { Toast.show(L("Invalid URL")); return }
            let sub = FilterSubscription(title: v[0].trimmed.isEmpty ? (url.host ?? "List") : v[0].trimmed, url: url.absoluteString)
            AdBlocker.shared.setSubscriptions(AdBlocker.shared.subscriptions + [sub])
            Toast.show(L("Updating..."))
            AdBlocker.shared.update(subscription: sub.id) { r in
                DispatchQueue.main.async {
                    if case .success(let n) = r { Toast.show(LF("%d rules", n)) } else { Toast.show(L("Update Failed")) }
                    self?.rebuild()
                }
            }
        }
    }

    // MARK: Backup

    private func createBackup() {
        var prefs: [String: Any] = [:]
        if let id = Bundle.main.bundleIdentifier, let dict = UserDefaults.standard.persistentDomain(forName: id) {
            prefs = dict.filter { JSONSerialization.isValidJSONObject([$0.key: $0.value]) }
        }
        var payload: [String: Any] = ["app": "FAbrowser", "version": 1, "prefs": prefs]
        let support = FileManager.default.appSupportURL
        for name in ["bookmarks.json", "home_sites.json", "search_engines.json", "js_extensions.json", "filter_subscriptions.json", "user_hide_rules.json", "adblock_whitelist.json"] {
            if let d = try? Data(contentsOf: support.appendingPathComponent(name)), let obj = try? JSONSerialization.jsonObject(with: d) { payload[name] = obj }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FAbrowser-backup-\(df.string(from: Date())).json")
        try? data.write(to: url)
        share([url])
    }

    private func restoreBackup() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = backupDelegate
        present(picker, animated: true)
    }

    private lazy var backupDelegate = BackupPickerDelegate { [weak self] url in
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["app"] as? String == "FAbrowser" else {
            Toast.show(L("Invalid backup file")); return
        }
        if let prefs = obj["prefs"] as? [String: Any] { prefs.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) } }
        let support = FileManager.default.appSupportURL
        for (k, v) in obj where k.hasSuffix(".json") {
            if let d = try? JSONSerialization.data(withJSONObject: v) { try? d.write(to: support.appendingPathComponent(k)) }
        }
        self?.showAlert(L("Restored"), message: L("Please restart FAbrowser to apply all restored data."))
    }

    // MARK: Table

    private var isEngines: Bool { page == .searchEngines }
    private var engines: [SearchEngine] { SearchEngineStore.shared.engines }

    override func numberOfSections(in tableView: UITableView) -> Int { isEngines ? 1 : sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isEngines ? engines.count : sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isEngines ? nil : sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        isEngines ? L("Tap to set default. The switch controls whether the engine appears in the quick search bar above the keyboard.") : sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isEngines { return engineCell(engines[indexPath.row]) }
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        if let s = row.symbol { cell.imageView?.image = SettingsIcon.image(s, color: row.color) }
        if let img = row.image { cell.imageView?.image = SettingsIcon.rounded(img, side: 44) }
        switch row.kind {
        case .toggle(let get, let set):
            let sw = UISwitch()
            sw.isOn = get()
            sw.onTintColor = Theme.accent
            sw.addAction(UIAction { _ in set(sw.isOn) }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        case .choice(let options, let get, _):
            cell.detailTextLabel?.text = options[safe: get()]
            cell.accessoryType = .disclosureIndicator
        case .nav(let detail, _):
            cell.detailTextLabel?.text = detail()
            cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
            cell.accessoryType = .disclosureIndicator
        case .action(let destructive, _):
            cell.textLabel?.textColor = destructive ? .systemRed : Theme.accent
            cell.textLabel?.textAlignment = page == .clearData ? .center : .natural
        case .slider(let min, let max, let get, let set):
            let slider = UISlider()
            slider.minimumValue = min
            slider.maximumValue = max
            slider.value = get()
            slider.frame.size.width = 160
            slider.addAction(UIAction { _ in set(slider.value) }, for: .valueChanged)
            cell.accessoryView = slider
            cell.selectionStyle = .none
        case .info(let detail):
            cell.detailTextLabel?.text = detail
            cell.selectionStyle = .none
        }
        return cell
    }

    private func engineCell(_ e: SearchEngine) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = e.name
        cell.detailTextLabel?.text = e.template
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
        cell.imageView?.image = FaviconManager.letterAvatar(for: e.name, size: 30)
        if let host = e.host, let icon = FaviconManager.shared.cachedIcon(for: host) { cell.imageView?.image = icon.resized(to: CGSize(width: 30, height: 30)) }
        let isCurrent = SearchEngineStore.shared.current.id == e.id
        let sw = UISwitch()
        sw.isOn = e.isQuick
        sw.addAction(UIAction { _ in var x = e; x.isQuick = sw.isOn; SearchEngineStore.shared.update(x) }, for: .valueChanged)
        let check = UIImageView(image: UIImage(systemName: "checkmark"))
        check.tintColor = Theme.accent
        check.isHidden = !isCurrent
        let stack = UIStackView(arrangedSubviews: [check, sw])
        stack.spacing = 12
        stack.alignment = .center
        stack.frame.size = CGSize(width: 90, height: 31)
        cell.accessoryView = stack
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isEngines {
            Prefs.searchEngineID = engines[indexPath.row].id
            NotificationCenter.default.post(name: .searchEnginesChanged, object: nil)
            return
        }
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row.kind {
        case .nav(_, let action): action(self)
        case .action(_, let action): action(self)
        case .choice(let options, let get, let set):
            let vc = ChoiceViewController(title: row.title, options: options, selected: get()) { [weak self] i in set(i); self?.rebuild() }
            navigationController?.pushViewController(vc, animated: true)
        case .info(let detail):
            if !detail.isEmpty { UIPasteboard.general.string = detail; Toast.show(L("Copied")) }
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch page {
        case .searchEngines: return true
        case .subscriptions: return true
        case .whitelist: return indexPath.row < AdBlocker.shared.whitelist.count
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { isEngines }

    override func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        SearchEngineStore.shared.move(from: from.row, to: to.row)
    }

    override func tableView(_ tableView: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard style == .delete else { return }
        switch page {
        case .searchEngines:
            guard engines.count > 1 else { return }
            SearchEngineStore.shared.remove(id: engines[indexPath.row].id)
        case .subscriptions:
            AdBlocker.shared.removeSubscription(id: AdBlocker.shared.subscriptions[indexPath.row].id)
        case .whitelist:
            AdBlocker.shared.setWhitelisted(AdBlocker.shared.whitelist[indexPath.row], false)
        default: return
        }
        rebuild()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard page == .subscriptions else { return nil }
        let sub = AdBlocker.shared.subscriptions[indexPath.row]
        return UISwipeActionsConfiguration(actions: [
            UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in
                AdBlocker.shared.removeSubscription(id: sub.id); self?.rebuild(); done(true)
            },
            UIContextualAction(style: .normal, title: L("Update")) { [weak self] _, _, done in
                Toast.show(L("Updating..."))
                AdBlocker.shared.update(subscription: sub.id) { r in
                    DispatchQueue.main.async {
                        if case .success(let n) = r { Toast.show(LF("%d rules", n)) } else { Toast.show(L("Update Failed")) }
                        self?.rebuild()
                    }
                }
                done(true)
            },
        ])
    }
}

final class BackupPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let handler: (URL) -> Void
    init(_ handler: @escaping (URL) -> Void) { self.handler = handler }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let u = urls.first { handler(u) }
    }
}

final class ChoiceViewController: UITableViewController {
    private let options: [String]
    private var selected: Int
    private let onSelect: (Int) -> Void

    init(title: String, options: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.options = options
        self.selected = selected
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { options.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.textLabel?.text = options[indexPath.row]
        cell.accessoryType = indexPath.row == selected ? .checkmark : .none
        cell.tintColor = Theme.accent
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selected = indexPath.row
        onSelect(indexPath.row)
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }
}

enum SettingsIcon {
    static func rounded(_ img: UIImage, side: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.225).addClip()
            img.draw(in: rect)
        }
    }

    static func image(_ symbol: String, color: UIColor) -> UIImage {
        let size = CGSize(width: 29, height: 29)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            if let s = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                s.draw(at: CGPoint(x: (size.width - s.size.width) / 2, y: (size.height - s.size.height) / 2))
            }
        }
    }
}

enum AppIcon: String, CaseIterable {
    case standard, black, green, red, orange, purple, caro

    var iconName: String? {
        switch self {
        case .standard: return nil
        default: return "AppIcon-" + rawValue.capitalized
        }
    }

    var title: String {
        [L("Default"), L("Black"), L("Green"), L("Red"), L("Orange"), L("Purple"), L("Caro")][AppIcon.allCases.firstIndex(of: self)!]
    }

    var color: UIColor {
        switch self {
        case .standard: return Theme.accent
        case .black: return .black
        case .green: return .systemGreen
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .caro: return CaroBoardView.xColor
        }
    }

    var preview: UIImage? { UIImage(named: (iconName ?? "AppIcon") + "-Preview") }

    static var current: AppIcon {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == name } ?? .standard
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}
