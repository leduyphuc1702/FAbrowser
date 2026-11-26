import WebKit

final class Tab {
    let id: UUID
    let isPrivate: Bool
    fileprivate(set) var webView: WKWebView?

    var url: URL?
    var title: String?
    var isDesktop: Bool
    var screenshot: UIImage?
    var nextPageURL: URL?
    /// True while the navigation homepage is shown on top of this tab's web view.
    var showingHome: Bool
    var lastActive = Date()

    var autoRefreshTimer: Timer?
    var autoRefreshInterval: Int = 0
    var isScreenAlwaysOn = false

    /// Media found on the current page (reset on each main-frame navigation).
    var videos: [DetectedVideo] = []
    var adNoticeShown = false
    /// Ad creatives the page's VAST/VMAP responses listed.
    var adURLs: Set<String> = []
    /// While true, every page loaded in this tab is translated to `Prefs.translateTarget`.
    var translateActive = false
    var translatedFrom: String?
    /// Source language offered in the "translate this page?" bar for the current page.
    var translateSuggested: String?
    /// Languages whose suggestion the user dismissed in this tab.
    var translateDeclined = Set<String>()
    /// Page id + state already handled, so DOMContentLoaded and didFinish don't both start work.
    var translateHandled: String?

    fileprivate var restoreState: Data?
    fileprivate var pendingURL: URL?

    init(id: UUID = UUID(), isPrivate: Bool, url: URL?, title: String? = nil, isDesktop: Bool = false) {
        self.id = id
        self.isPrivate = isPrivate
        self.url = url
        self.title = title
        self.isDesktop = isDesktop
        self.pendingURL = url
        self.showingHome = url == nil
    }

    var displayTitle: String {
        if showingHome || url == nil { return L("Homepage") }
        if let t = title, !t.isEmpty { return t }
        return url?.displayString ?? L("Untitle")
    }

    var canGoBack: Bool {
        guard let wv = webView else { return false }
        if showingHome { return wv.url != nil }
        return wv.canGoBack || wv.url != nil
    }

    var canGoForward: Bool {
        guard let wv = webView else { return false }
        if showingHome { return wv.url != nil }
        return wv.canGoForward
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        autoRefreshInterval = 0
    }

    func startAutoRefresh(seconds: Int) {
        stopAutoRefresh()
        autoRefreshInterval = seconds
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            self?.webView?.reload()
        }
    }
}

private struct SavedTab: Codable {
    var id: UUID
    var url: String?
    var title: String?
    var isDesktop: Bool
    var state: Data?
}

private struct SavedSession: Codable {
    var tabs: [SavedTab]
    var selected: Int
}

protocol TabManagerDelegate: AnyObject {
    func tabManager(_ manager: TabManager, didSelect tab: Tab, previous: Tab?)
    func tabManager(_ manager: TabManager, didCreateWebView webView: WKWebView, for tab: Tab)
    func tabManagerDidUpdateTabs(_ manager: TabManager)
}

final class TabManager {
    weak var delegate: TabManagerDelegate?

    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?

    private let processPool = WKProcessPool()
    private var privateDataStore = WKWebsiteDataStore.nonPersistent()
    private let sessionFile = "session.json"
    private var saveWork: DispatchWorkItem?

    var normalTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter { $0.isPrivate } }
    var isPrivate: Bool { selectedTab?.isPrivate ?? false }

    func tabs(private isPrivate: Bool) -> [Tab] { tabs.filter { $0.isPrivate == isPrivate } }

    func tab(for webView: WKWebView) -> Tab? { tabs.first { $0.webView === webView } }

    // MARK: Configuration

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.processPool = processPool
        c.websiteDataStore = isPrivate ? privateDataStore : .default()
        c.allowsInlineMediaPlayback = true
        c.allowsAirPlayForMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = .audio
        c.preferences.javaScriptCanOpenWindowsAutomatically = !Prefs.blockPopups
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.dataDetectorTypes = Prefs.autoDetectData ? [.phoneNumber, .link, .address, .calendarEvent, .flightNumber, .trackingNumber] : []
        c.upgradeKnownHostsToHTTPS = true
        return c
    }

    @discardableResult
    func ensureWebView(for tab: Tab, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let wv = tab.webView { return wv }
        let config = configuration ?? makeConfiguration(isPrivate: tab.isPrivate)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = Prefs.swipeBackAnywhere
        wv.allowsLinkPreview = false
        wv.customUserAgent = tab.isDesktop ? UserAgent.desktop : UserAgent.mobile
        wv.pageZoom = CGFloat(Prefs.pageZoom) / 100
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        tab.webView = wv
        delegate?.tabManager(self, didCreateWebView: wv, for: tab)

        if configuration == nil {
            if let state = tab.restoreState {
                wv.interactionState = state as NSData
                tab.restoreState = nil
                tab.pendingURL = nil
            } else if let url = tab.pendingURL {
                load(url, in: tab)
                tab.pendingURL = nil
            }
        }
        return wv
    }

    func load(_ url: URL, in tab: Tab) {
        let wv = ensureWebView(for: tab)
        tab.showingHome = false
        tab.url = url
        if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    // MARK: Add / remove / select

    @discardableResult
    func addTab(url: URL? = nil, isPrivate: Bool? = nil, select: Bool = true, afterCurrent: Bool = true, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let priv = isPrivate ?? self.isPrivate
        let tab = Tab(isPrivate: priv, url: url, isDesktop: Prefs.openNewTabInDesktop)
        if afterCurrent, let current = selectedTab, let idx = tabs.firstIndex(where: { $0 === current }), current.isPrivate == priv {
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }
        if configuration != nil || url != nil && !select {
            ensureWebView(for: tab, configuration: configuration)
        }
        if select { selectTab(tab) }
        delegate?.tabManagerDidUpdateTabs(self)
        scheduleSave()
        return tab
    }

    func selectTab(_ tab: Tab) {
        let previous = selectedTab
        selectedTab = tab
        tab.lastActive = Date()
        if !tab.showingHome || tab.pendingURL != nil || tab.restoreState != nil {
            ensureWebView(for: tab)
        }
        delegate?.tabManager(self, didSelect: tab, previous: previous === tab ? nil : previous)
        scheduleSave()
    }

    func removeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = tab === selectedTab
        tab.stopAutoRefresh()
        tab.webView?.stopLoading()
        tab.webView?.removeFromSuperview()
        tabs.remove(at: idx)
        if wasSelected {
            let sameMode = tabs.filter { $0.isPrivate == tab.isPrivate }
            if let next = sameMode.max(by: { $0.lastActive < $1.lastActive }) {
                selectTab(next)
            } else if tab.isPrivate, let normal = normalTabs.max(by: { $0.lastActive < $1.lastActive }) {
                selectTab(normal)
            } else {
                addTab(url: nil, isPrivate: false)
            }
        }
        if tab.isPrivate && privateTabs.isEmpty { resetPrivateStore() }
        delegate?.tabManagerDidUpdateTabs(self)
        scheduleSave()
    }

    func removeAll(private isPrivate: Bool, except keep: Tab? = nil) {
        let removing = tabs.filter { $0.isPrivate == isPrivate && $0 !== keep }
        for t in removing { t.stopAutoRefresh(); t.webView?.stopLoading(); t.webView?.removeFromSuperview() }
        tabs.removeAll { t in removing.contains { $0 === t } }
        if isPrivate && keep == nil { resetPrivateStore() }
        if let keep {
            selectTab(keep)
        } else if let sel = selectedTab, !tabs.contains(where: { $0 === sel }) {
            if isPrivate, let t = normalTabs.max(by: { $0.lastActive < $1.lastActive }) {
                selectTab(t)
            } else {
                addTab(url: nil, isPrivate: false)
            }
        }
        delegate?.tabManagerDidUpdateTabs(self)
        scheduleSave()
    }

    func removeTabs(rightOf tab: Tab) {
        let same = tabs(private: tab.isPrivate)
        guard let idx = same.firstIndex(where: { $0 === tab }) else { return }
        let toRemove = same.suffix(from: idx + 1)
        for t in toRemove { t.stopAutoRefresh(); t.webView?.removeFromSuperview() }
        tabs.removeAll { t in toRemove.contains { $0 === t } }
        if let sel = selectedTab, !tabs.contains(where: { $0 === sel }) { selectTab(tab) }
        delegate?.tabManagerDidUpdateTabs(self)
        scheduleSave()
    }

    func moveTab(_ tab: Tab, toIndexInMode newIndex: Int) {
        var same = tabs(private: tab.isPrivate)
        guard let from = same.firstIndex(where: { $0 === tab }) else { return }
        same.remove(at: from)
        same.insert(tab, at: min(newIndex, same.count))
        tabs = tab.isPrivate ? normalTabs + same : same + privateTabs
        delegate?.tabManagerDidUpdateTabs(self)
        scheduleSave()
    }

    func duplicate(_ tab: Tab) {
        let new = addTab(url: tab.webView?.url ?? tab.url, isPrivate: tab.isPrivate, select: false)
        new.isDesktop = tab.isDesktop
    }

    func selectAdjacent(_ offset: Int) {
        guard let cur = selectedTab else { return }
        let same = tabs(private: cur.isPrivate)
        guard same.count > 1, let i = same.firstIndex(where: { $0 === cur }) else { return }
        selectTab(same[(i + offset + same.count) % same.count])
    }

    private func resetPrivateStore() {
        privateDataStore = WKWebsiteDataStore.nonPersistent()
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func saveNow() {
        guard Prefs.reopenTabs else { JSONStore.save(SavedSession(tabs: [], selected: 0), to: sessionFile); return }
        let normals = normalTabs
        let saved = normals.map { t -> SavedTab in
            let state = (t.webView?.interactionState as? Data) ?? t.restoreState
            return SavedTab(id: t.id, url: (t.webView?.url ?? t.url)?.absoluteString, title: t.title, isDesktop: t.isDesktop, state: t.showingHome ? nil : state)
        }
        let sel = normals.firstIndex { $0 === selectedTab } ?? max(0, normals.count - 1)
        JSONStore.save(SavedSession(tabs: saved, selected: sel), to: sessionFile)
    }

    func restore() {
        if Prefs.reopenTabs, let session = JSONStore.load(SavedSession.self, from: sessionFile), !session.tabs.isEmpty {
            for s in session.tabs {
                let t = Tab(id: s.id, isPrivate: false, url: s.url.flatMap(URL.init(string:)), title: s.title, isDesktop: s.isDesktop)
                t.restoreState = s.state
                tabs.append(t)
            }
            selectTab(tabs[min(session.selected, tabs.count - 1)])
        } else {
            addTab(url: nil, isPrivate: false)
        }
        delegate?.tabManagerDidUpdateTabs(self)
    }

    func forEachWebView(_ body: (WKWebView, Tab) -> Void) {
        for t in tabs { if let wv = t.webView { body(wv, t) } }
    }
}
