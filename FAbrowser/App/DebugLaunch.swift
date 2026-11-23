#if DEBUG
import UIKit

/// Debug-only launch arguments for UI snapshots without manual tapping:
///   -FAOpenURL https://example.com      open a page in the current tab
///   -FAScreen menu|toolbox|tabs|search|library|history|files|settings|settings.<page>|extensions|wifi|reader|find
///   -FADark YES                         force dark appearance
///   -FAPlayURL https://…/video.mp4      open a video in the floating player (-FAScreen player.mini|player.full to change mode)
///   -FASkipOnboarding YES               don't show first-launch onboarding
///   -FAThenURL https://…                load a second page 14 s after launch (-FAThenBack YES goes back at 26 s)
///   -FAPlayTitle "…"                    title for -FAPlayURL; -FALiveSubs YES starts live subtitles on it
/// Example: xcrun simctl launch booted com.fabrowser.app -FAScreen menu
enum DebugLaunch {
    static var skipsOnboarding: Bool { UserDefaults.standard.bool(forKey: "FASkipOnboarding") || UserDefaults.standard.string(forKey: "FAScreen") != nil && UserDefaults.standard.string(forKey: "FAScreen") != "onboarding" }

    static func run(_ browser: BrowserViewController) {
        let d = UserDefaults.standard
        if d.bool(forKey: "FADark") { browser.view.window?.overrideUserInterfaceStyle = .dark }
        if let s = d.string(forKey: "FAOpenURL"), let url = URL(string: s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { browser.load(url) }
        }
        if let s = d.string(forKey: "FAPlayURL"), let url = URL(string: s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                browser.floatingPlayer.play(VideoSource(url: url, title: d.string(forKey: "FAPlayTitle") ?? "Sample Video", pageURL: nil), in: browser)
            }
            if d.bool(forKey: "FALiveSubs") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { browser.toggleSubtitles(forPlayer: true) }
            }
        }
        if let s = d.string(forKey: "FAThenURL"), let url = URL(string: s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { browser.load(url) }
            if d.bool(forKey: "FAThenBack") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 26) { browser.currentWebView?.goBack() }
            }
        }
        guard let screen = d.string(forKey: "FAScreen") else { return }
        let delay: Double = d.string(forKey: "FAOpenURL") == nil ? 0.8 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch screen {
            case "menu": browser.presentMenu()
            case "toolbox": browser.presentToolbox()
            case "tabs": browser.presentTabTray()
            case "search": browser.presentSearch(initialText: nil)
            case "library": browser.presentLibrary()
            case "files": browser.presentFiles()
            case "settings": browser.presentSettings()
            case "extensions": browser.present(UINavigationController(rootViewController: ExtensionsViewController()), animated: true)
            case "wifi": browser.present(UINavigationController(rootViewController: WiFiTransferViewController()), animated: true)
            case "reader": browser.openReaderMode()
            case "find": browser.showFindBar()
            case "translate": browser.translatePage()
            case "playpage": browser.playPageVideo()
            case "onboarding":
                let vc = OnboardingViewController()
                vc.modalPresentationStyle = .fullScreen
                browser.present(vc, animated: false)
            case "player.mini": browser.floatingPlayer.setMode(.mini)
            case "player.full": browser.floatingPlayer.setMode(.fullscreen)
            case "translatebar": browser.translateBar.show(from: "en", to: Prefs.translateTarget, progress: 0.5)
            case "translate.accept": if let tab = browser.currentTab { browser.pageTranslator.accept(tab: tab) }
            case "subtitles":
                browser.pageSubtitles.isHidden = false
                browser.view.setNeedsLayout()
                browser.pageSubtitles.show(original: "Welcome back to the channel, today we are testing live subtitles.", translated: "Chào mừng trở lại kênh, hôm nay chúng ta thử phụ đề trực tiếp.", mode: .bilingual)
            case "livesubs.page": browser.toggleSubtitles(forPlayer: false)
            case "player.subtitles":
                browser.floatingPlayer.setSubtitlesShown(true)
                browser.floatingPlayer.subtitleView.show(original: "今日はいい天気ですね。", translated: "Hôm nay trời đẹp nhỉ.", mode: LiveSubtitles.shared.mode)
            case let s where s.hasPrefix("settings."):
                let pages: [String: SettingsViewController.Page] = [
                    "general": .general, "search": .search, "engines": .searchEngines, "homepage": .homepage, "display": .display,
                    "gestures": .gestures, "privacy": .privacy, "clear": .clearData, "adblock": .adBlock, "video": .video, "translate": .translate, "subtitles": .subtitles,
                    "ua": .userAgent, "icon": .appIcon, "backup": .backup, "about": .about,
                ]
                browser.presentSettings(open: pages[String(s.dropFirst("settings.".count))])
                if d.bool(forKey: "FASlide") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { slideFirstSlider(in: browser.view.window) }
                }
            default: break
            }
        }
    }

    /// -FASlide YES: drags the first slider on screen through its range, like a finger would.
    private static func slideFirstSlider(in window: UIWindow?) {
        func find(_ v: UIView) -> UISlider? { (v as? UISlider) ?? v.subviews.lazy.compactMap(find).first }
        guard let w = window, let slider = find(w) else { NSLog("[debug] no slider"); return }
        for i in 0...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                slider.value = slider.minimumValue + (slider.maximumValue - slider.minimumValue) * Float(i) / 20
                slider.sendActions(for: .valueChanged)
                if i == 20 { NSLog("[debug] slid to %.1f", slider.value) }
            }
        }
    }
}
#endif
