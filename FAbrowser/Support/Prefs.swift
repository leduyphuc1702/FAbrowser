import UIKit

@propertyWrapper
struct Pref<T> {
    let key: String
    let defaultValue: T

    init(_ key: String, _ defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        // Observers read the pref back while the notification is delivered; a mutating setter would
        // hold exclusive access to the static storage during that and trap.
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .prefsChanged, object: key)
        }
    }
}

enum ThemeMode: Int, CaseIterable {
    case system, light, dark
    var title: String { [L("Follow System"), L("Light Mode"), L("Dark Mode")][rawValue] }
    var style: UIUserInterfaceStyle { [.unspecified, .light, .dark][rawValue] }
}

enum HomepageMode: Int, CaseIterable {
    case navigation, customURL, blank
    var title: String { [L("Navigation Page"), L("Website Homepage"), L("Blank")][rawValue] }
}

enum AutoRefreshInterval: Int, CaseIterable {
    case s10 = 10, s30 = 30, m1 = 60, m3 = 180, m5 = 300, m10 = 600, m30 = 1800, m60 = 3600
    var title: String {
        rawValue < 60 ? LF("%d sec.", rawValue) : LF("%d min.", rawValue / 60)
    }
}

/// All user-facing settings. Every write posts `.prefsChanged` with the key as object.
enum Prefs {
    // General
    @Pref("searchEngineID", "google") static var searchEngineID: String
    @Pref("pullToRefresh", true) static var pullToRefresh: Bool
    @Pref("swipeBackAnywhere", true) static var swipeBackAnywhere: Bool
    @Pref("openClickLinkInNewTab", false) static var openClickLinkInNewTab: Bool
    @Pref("preferCurrentTab", false) static var preferCurrentTab: Bool
    @Pref("blockPopups", true) static var blockPopups: Bool
    @Pref("reopenTabs", true) static var reopenTabs: Bool
    @Pref("domainAutoCompletion", true) static var domainAutoCompletion: Bool
    @Pref("autoPasteCopied", true) static var autoPasteCopied: Bool
    @Pref("searchSuggestions", true) static var searchSuggestions: Bool
    @Pref("matchHistory", true) static var matchHistory: Bool
    @Pref("recordSearchHistory", true) static var recordSearchHistory: Bool
    @Pref("showQuickInput", true) static var showQuickInput: Bool
    @Pref("showHistoryOnSearchStart", true) static var showHistoryOnSearchStart: Bool
    @Pref("touchToTurnPage", false) static var touchToTurnPage: Bool
    @Pref("showPageUpDown", false) static var showPageUpDown: Bool
    @Pref("forwardPrefersNextPage", true) static var forwardPrefersNextPage: Bool
    @Pref("openInBackground", true) static var openInBackground: Bool
    @Pref("autoDetectData", false) static var autoDetectData: Bool
    @Pref("hideToolbarsOnScroll", true) static var hideToolbarsOnScroll: Bool
    @Pref("removeLineBreaks", false) static var removeLineBreaks: Bool

    // Display
    @Pref("themeMode", 0) static var themeModeRaw: Int
    @Pref("nightMode", false) static var nightMode: Bool
    @Pref("applyDarkToWebpage", false) static var applyDarkToWebpage: Bool
    @Pref("pageZoom", 100) static var pageZoom: Int
    @Pref("showTopTabs", UIDevice.current.userInterfaceIdiom == .pad) static var showTopTabs: Bool
    @Pref("showTopTabsOneTab", false) static var showTopTabsOneTab: Bool
    @Pref("swapHomeAndTab", false) static var swapHomeAndTab: Bool
    @Pref("fullscreen", false) static var fullscreen: Bool
    @Pref("noImage", false) static var noImage: Bool
    @Pref("eyeCare", false) static var eyeCare: Bool

    // Homepage
    @Pref("homepageMode", 0) static var homepageModeRaw: Int
    @Pref("homepageURL", "") static var homepageURL: String
    @Pref("centeredSearchBox", true) static var centeredSearchBox: Bool
    @Pref("bottomSearchButton", true) static var bottomSearchButton: Bool
    @Pref("pullDownToSearch", true) static var pullDownToSearch: Bool
    @Pref("wallpaperAlpha", 0.15) static var wallpaperAlpha: Double
    @Pref("iconCornerRadius", 14.0) static var iconCornerRadius: Double
    @Pref("homeColumns", 5) static var homeColumns: Int

    // User agent
    @Pref("mobileUA", 0) static var mobileUA: Int
    @Pref("customMobileUA", "") static var customMobileUA: String
    @Pref("desktopUA", 0) static var desktopUA: Int
    @Pref("customDesktopUA", "") static var customDesktopUA: String
    @Pref("openNewTabInDesktop", false) static var openNewTabInDesktop: Bool

    // Privacy
    @Pref("clearHistoryOnExit", false) static var clearHistoryOnExit: Bool
    @Pref("clearPrivateOnExit", true) static var clearPrivateOnExit: Bool
    @Pref("coverInBackground", true) static var coverInBackground: Bool
    @Pref("requireUnlock", false) static var requireUnlock: Bool
    @Pref("caroLock", false) static var caroLock: Bool
    @Pref("caroLockMoves", "") static var caroLockMoves: String
    @Pref("allowClipboardRead", true) static var allowClipboardRead: Bool

    // Ad block
    @Pref("adBlock", true) static var adBlock: Bool
    @Pref("blockIntrusiveAds", true) static var blockIntrusiveAds: Bool
    @Pref("skipVideoAds", true) static var skipVideoAds: Bool
    @Pref("blockAppJump", true) static var blockAppJump: Bool
    @Pref("filterAutoUpdate", true) static var filterAutoUpdate: Bool

    // Video
    @Pref("playbackRate", 1.0) static var playbackRate: Double
    @Pref("backgroundPlay", true) static var backgroundPlay: Bool
    @Pref("videoFloating", true) static var videoFloating: Bool
    /// Load floating-player videos through the local multi-connection proxy.
    @Pref("videoAccelerate", true) static var videoAccelerate: Bool
    @Pref("longPressSpeed", 3.0) static var longPressSpeed: Double
    @Pref("autoPiP", true) static var autoPiP: Bool
    @Pref("resumePlayback", true) static var resumePlayback: Bool
    @Pref("allowAutoReplace", true) static var allowAutoReplace: Bool
    @Pref("showTimeBattery", true) static var showTimeBattery: Bool
    @Pref("videoCompatMode", true) static var videoCompatMode: Bool
    @Pref("videoGravity", 0) static var videoGravity: Int

    // Translate (offline, Apple Translation)
    @Pref("translateTarget", "vi") static var translateTarget: String
    @Pref("translateAutoContinue", true) static var translateAutoContinue: Bool
    /// Offer to translate pages that aren't in the target language.
    @Pref("translateSuggest", true) static var translateSuggest: Bool
    /// Source languages the user chose to always translate (comma separated).
    @Pref("autoTranslateLangs", "") static var autoTranslateLangsRaw: String
    static var autoTranslateLangs: Set<String> {
        get { Set(autoTranslateLangsRaw.split(separator: ",").map(String.init)) }
        set { autoTranslateLangsRaw = newValue.sorted().joined(separator: ",") }
    }

    // Live subtitles
    @Pref("subtitleSource", "auto") static var subtitleSource: String
    @Pref("subtitleMode", 0) static var subtitleModeRaw: Int
    @Pref("subtitleEngine", "auto") static var subtitleEngine: String
    @Pref("senseVoiceOffered", false) static var senseVoiceOffered: Bool
    @Pref("appAudioAllowed", false) static var appAudioAllowed: Bool
    @Pref("subtitleFontSize", 17.0) static var subtitleFontSize: Double

    // Onboarding
    @Pref("onboarded", false) static var onboarded: Bool

    // Misc
    @Pref("lastCopiedURL", "") static var lastCopiedURL: String

    static var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .system }
        set { themeModeRaw = newValue.rawValue }
    }

    static var homepageMode: HomepageMode {
        get { HomepageMode(rawValue: homepageModeRaw) ?? .navigation }
        set { homepageModeRaw = newValue.rawValue }
    }
}
