import UIKit
import WebKit

final class BrowserViewController: UIViewController {
    let tabManager = TabManager()

    let urlBar = URLBarView()
    let toolbar = TabToolbar()
    let topTabs = TopTabsView()
    let homeVC = HomePageViewController()
    let webContainer = UIView()
    let errorView = ErrorPageView()
    let findBar = FindInPageBar()
    let pageUpDown = PageUpDownBar()
    var pickerBar: ElementPickerBar?
    let translateBar = TranslateBar()
    let videoButton = VideoFloatButton()
    let pageSubtitles = SubtitleOverlayView()
    lazy var floatingPlayer = FloatingPlayerController(browser: self)
    lazy var pageTranslator = PageTranslator(browser: self)
    var webContainerTop: NSLayoutConstraint!

    private let topBackground = UIView()
    private let topStack = UIStackView()
    private let fullscreenHotZone = UIView()
    private let fullscreenExitButton = UIButton(type: .system)

    private var urlBarHeight: NSLayoutConstraint!
    private var topTabsHeight: NSLayoutConstraint!
    private var toolbarHeight: NSLayoutConstraint!
    private var toolbarBottom: NSLayoutConstraint!
    private var topStackTop: NSLayoutConstraint!

    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var lastOffsetY: CGFloat = 0
    private(set) var barsHidden = false
    private var fullscreenRevealWork: DispatchWorkItem?
    let scriptHandler = WeakHandlerBox()
    private(set) var tabsReady = false
    private var pendingTabActions: [() -> Void] = []

    /// Runs `action` now, or after the saved tabs are restored at launch.
    func whenTabsReady(_ action: @escaping () -> Void) {
        if tabsReady { action() } else { pendingTabActions.append(action) }
    }

    var currentTab: Tab? { tabManager.selectedTab }
    var currentWebView: WKWebView? { tabManager.selectedTab?.webView }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        tabManager.isPrivate ? .lightContent : .default
    }

    override var prefersStatusBarHidden: Bool { Prefs.fullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { Prefs.fullscreen }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.barBackground
        scriptHandler.handler = self
        setupLayout()
        tabManager.delegate = self
        // Restore tabs once the content rules are loaded so the first page is already filtered;
        // a first-run compile of the bundled lists may take longer, so fall back after a few seconds.
        let restore = { [weak self] in
            guard let self, !self.tabsReady else { return }
            self.tabManager.restore()
            self.tabsReady = true
            let pending = self.pendingTabActions
            self.pendingTabActions = []
            pending.forEach { $0() }
        }
        AdBlocker.shared.prepare { [weak self] in
            guard let self else { return }
            let late = self.tabsReady
            self.reinstallScripts()
            restore()
            if late, Prefs.adBlock, let wv = self.currentTab?.webView, wv.url != nil { wv.reload() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { restore() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(prefsChanged(_:)), name: .prefsChanged, object: nil)
        nc.addObserver(self, selector: #selector(contentRulesChanged), name: .adBlockRulesChanged, object: nil)
        nc.addObserver(self, selector: #selector(contentRulesChanged), name: .extensionsChanged, object: nil)
        nc.addObserver(self, selector: #selector(clipboardChanged), name: UIPasteboard.changedNotification, object: nil)
        updateTopTabsVisibility()
        updatePageUpDown()
        if Prefs.fullscreen { setFullscreen(true, animated: false) }
        setupMedia()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutMedia()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        let skip = DebugLaunch.skipsOnboarding
        #else
        let skip = false
        #endif
        if !Prefs.onboarded, presentedViewController == nil, !skip {
            let vc = OnboardingViewController()
            vc.modalPresentationStyle = .fullScreen
            present(vc, animated: false)
        }
    }

    /// Top edge of the web content area (below the URL bar), used by the floating player.
    var contentTop: CGFloat { max(topStack.frame.maxY, view.safeAreaInsets.top) }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        toolbarHeight.constant = Theme.toolbarHeight + view.safeAreaInsets.bottom
        if barsHidden || Prefs.fullscreen { toolbarBottom.constant = toolbarHeight.constant }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle, Prefs.applyDarkToWebpage {
            reinstallScripts()
        }
    }

    private func setupLayout() {
        topBackground.backgroundColor = Theme.barBackground
        urlBar.delegate = self
        toolbar.delegate = self
        topTabs.delegate = self

        topStack.axis = .vertical
        topStack.addArrangedSubview(topTabs)
        topStack.addArrangedSubview(urlBar)
        urlBar.clipsToBounds = true
        topTabs.clipsToBounds = true

        webContainer.backgroundColor = Theme.homeBackground
        webContainer.clipsToBounds = true

        [webContainer, topBackground, topStack, toolbar, fullscreenHotZone, pageUpDown, findBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        addChild(homeVC)
        homeVC.delegate = self
        homeVC.view.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(homeVC.view)
        homeVC.view.pinEdges(to: webContainer)
        homeVC.didMove(toParent: self)

        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(errorView)
        errorView.pinEdges(to: webContainer)
        errorView.onRetry = { [weak self] in
            self?.errorView.isHidden = true
            self?.currentWebView?.reload()
        }

        urlBarHeight = urlBar.heightAnchor.constraint(equalToConstant: Theme.urlBarHeight)
        topTabsHeight = topTabs.heightAnchor.constraint(equalToConstant: Theme.topTabsHeight)
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight)
        toolbarBottom = toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        topStackTop = topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        webContainerTop = webContainer.topAnchor.constraint(equalTo: topStack.bottomAnchor)

        NSLayoutConstraint.activate([
            topBackground.topAnchor.constraint(equalTo: view.topAnchor),
            topBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBackground.bottomAnchor.constraint(equalTo: topStack.bottomAnchor),

            topStackTop,
            topStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            urlBarHeight,
            topTabsHeight,

            webContainerTop,
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarHeight,
            toolbarBottom,

            fullscreenHotZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fullscreenHotZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fullscreenHotZone.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fullscreenHotZone.heightAnchor.constraint(equalToConstant: 28),

            pageUpDown.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            pageUpDown.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -24),

            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        fullscreenHotZone.isHidden = true
        fullscreenHotZone.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(revealToolbarInFullscreen)))

        findBar.isHidden = true
        findBar.onSearch = { [weak self] q in self?.find(q) }
        findBar.onStep = { [weak self] d in self?.findStep(d) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }

        pageUpDown.onPage = { [weak self] dir in
            self?.currentWebView?.evaluateJavaScript("window.__fa && __fa.page(\(dir))")
        }
    }

    // MARK: Tab display

    func display(tab: Tab) {
        for sub in webContainer.subviews where sub is WKWebView { sub.removeFromSuperview() }
        errorView.isHidden = true
        if let wv = tab.webView {
            wv.translatesAutoresizingMaskIntoConstraints = false
            webContainer.insertSubview(wv, at: 0)
            wv.pinEdges(to: webContainer)
            wv.scrollView.delegate = self
            updateRefreshControl(for: wv)
        }
        homeVC.view.isHidden = !tab.showingHome
        if tab.showingHome { webContainer.bringSubviewToFront(homeVC.view); homeVC.reload() }
        setBarsHidden(false, animated: false)
        updateUI()
        updateTopTabs()
        setNeedsStatusBarAppearanceUpdate()
        UIApplication.shared.isIdleTimerDisabled = tab.isScreenAlwaysOn
        mediaTabChanged(tab)
    }

    func showHome(_ show: Bool) {
        guard let tab = currentTab else { return }
        tab.showingHome = show
        homeVC.view.isHidden = !show
        if show {
            webContainer.bringSubviewToFront(homeVC.view)
            homeVC.reload()
            errorView.isHidden = true
        }
        setBarsHidden(false, animated: true)
        updateUI()
        updateTopTabs()
    }

    func updateUI() {
        guard let tab = currentTab else { return }
        let wv = tab.webView
        let isPrivate = tab.isPrivate
        urlBar.isPrivate = isPrivate
        toolbar.isPrivate = isPrivate
        topBackground.backgroundColor = isPrivate ? Theme.privateBarBackground : (topTabs.isHidden ? Theme.barBackground : topTabs.backgroundColor)
        view.backgroundColor = isPrivate ? Theme.privateBarBackground : Theme.barBackground

        if tab.showingHome || wv?.url == nil {
            urlBar.setTitle(L("Search or Enter Address"), placeholder: true)
            urlBar.isLoading = false
            urlBar.isSecure = true
            urlBar.showsReader = false
            urlBar.setProgress(0, animated: false)
        } else if let wv {
            let title = wv.title?.isEmpty == false ? wv.title! : (wv.url?.displayString ?? "")
            urlBar.setTitle(title, placeholder: false)
            urlBar.isLoading = wv.isLoading
            urlBar.isSecure = wv.url?.scheme == "https" || wv.url?.isFileURL == true
            urlBar.showsReader = wv.url?.isWebURL == true && !wv.isLoading
        }
        let canForward = tab.canGoForward
        toolbar.nextPageAvailable = Prefs.forwardPrefersNextPage && !tab.showingHome && !canForward && tab.nextPageURL != nil
        toolbar.update(canGoBack: tab.canGoBack, canGoForward: canForward, tabCount: tabManager.tabs(private: isPrivate).count)
    }

    // MARK: Observation

    func observe(_ wv: WKWebView) {
        let id = ObjectIdentifier(wv)
        var obs: [NSKeyValueObservation] = []
        obs.append(wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard wv === self?.currentWebView, self?.currentTab?.showingHome == false else { return }
            self?.urlBar.setProgress(Float(wv.estimatedProgress), animated: true)
        })
        let refresh: (WKWebView) -> Void = { [weak self] wv in
            guard let self, let tab = self.tabManager.tab(for: wv) else { return }
            if let u = wv.url { tab.url = u }
            if let t = wv.title, !t.isEmpty { tab.title = t }
            if wv === self.currentWebView { self.updateUI() }
        }
        obs.append(wv.observe(\.title) { wv, _ in refresh(wv) })
        obs.append(wv.observe(\.url) { wv, _ in refresh(wv) })
        obs.append(wv.observe(\.canGoBack) { wv, _ in refresh(wv) })
        obs.append(wv.observe(\.canGoForward) { wv, _ in refresh(wv) })
        obs.append(wv.observe(\.isLoading) { wv, _ in refresh(wv) })
        observations[id] = obs
    }

    func stopObserving(_ wv: WKWebView) {
        observations[ObjectIdentifier(wv)] = nil
    }

    // MARK: Bars

    func setBarsHidden(_ hidden: Bool, animated: Bool) {
        guard !Prefs.fullscreen else { return }
        guard hidden != barsHidden || !animated else { return }
        barsHidden = hidden
        urlBarHeight.constant = hidden ? 22 : Theme.urlBarHeight
        topTabsHeight.constant = (hidden || topTabs.isHidden) ? 0 : Theme.topTabsHeight
        toolbarBottom.constant = hidden ? toolbarHeight.constant : 0
        let changes = {
            self.urlBar.setCollapsed(hidden)
            self.pageUpDown.alpha = hidden ? 0.5 : 1
            self.view.layoutIfNeeded()
        }
        if animated { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes) } else { changes() }
    }

    func setFullscreen(_ on: Bool, animated: Bool) {
        barsHidden = false
        urlBarHeight.constant = on ? 0 : Theme.urlBarHeight
        topTabsHeight.constant = (on || topTabs.isHidden) ? 0 : Theme.topTabsHeight
        toolbarBottom.constant = on ? toolbarHeight.constant : 0
        topStackTop.isActive = false
        topStackTop = on ? topStack.topAnchor.constraint(equalTo: view.topAnchor) : topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        topStackTop.isActive = true
        fullscreenHotZone.isHidden = !on
        urlBar.setCollapsed(false)
        let changes = {
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.view.layoutIfNeeded()
        }
        if animated { UIView.animate(withDuration: 0.25, animations: changes) } else { changes() }
        if on && animated { Toast.show(L("Click bottom red area to show toolbar")) }
    }

    @objc private func revealToolbarInFullscreen() {
        guard Prefs.fullscreen else { return }
        toolbarBottom.constant = 0
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        fullscreenRevealWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, Prefs.fullscreen else { return }
            self.toolbarBottom.constant = self.toolbarHeight.constant
            UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        }
        fullscreenRevealWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func updateTopTabsVisibility() {
        let count = tabManager.tabs(private: tabManager.isPrivate).count
        let show = Prefs.showTopTabs && (Prefs.showTopTabsOneTab || count > 1) && !Prefs.fullscreen
        topTabs.isHidden = !show
        topTabsHeight.constant = show && !barsHidden ? Theme.topTabsHeight : 0
        updateTopTabs()
    }

    func updateTopTabs() {
        guard !topTabs.isHidden else { return }
        let isPrivate = tabManager.isPrivate
        topTabs.update(tabs: tabManager.tabs(private: isPrivate), selected: currentTab, isPrivate: isPrivate)
    }

    func updatePageUpDown() {
        pageUpDown.isHidden = !Prefs.showPageUpDown || currentTab?.showingHome != false
    }

    func updateRefreshControl(for wv: WKWebView) {
        if Prefs.pullToRefresh {
            if wv.scrollView.refreshControl == nil {
                let rc = UIRefreshControl()
                rc.addTarget(self, action: #selector(pullRefresh(_:)), for: .valueChanged)
                wv.scrollView.refreshControl = rc
            }
        } else {
            wv.scrollView.refreshControl = nil
        }
    }

    @objc private func pullRefresh(_ rc: UIRefreshControl) {
        currentWebView?.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { rc.endRefreshing() }
    }

    // MARK: Preferences

    private static let scriptKeys: Set<String> = ["nightMode", "eyeCare", "touchToTurnPage", "playbackRate", "applyDarkToWebpage", "adBlock", "noImage", "blockIntrusiveAds",
                                                       "videoCompatMode", "skipVideoAds", "blockAppJump", "blockPopups"]

    @objc private func prefsChanged(_ n: Notification) {
        guard let key = n.object as? String else { return }
        if BrowserViewController.scriptKeys.contains(key) {
            reinstallScripts()
            if key == "noImage" || key == "adBlock" || key == "videoCompatMode" { currentWebView?.reload() }
        }
        switch key {
        case "pageZoom":
            tabManager.forEachWebView { wv, _ in wv.pageZoom = CGFloat(Prefs.pageZoom) / 100 }
        case "swipeBackAnywhere":
            tabManager.forEachWebView { wv, _ in wv.allowsBackForwardNavigationGestures = Prefs.swipeBackAnywhere }
        case "showTopTabs", "showTopTabsOneTab":
            updateTopTabsVisibility()
            updateUI()
        case "swapHomeAndTab":
            toolbar.arrange()
        case "fullscreen":
            setFullscreen(Prefs.fullscreen, animated: true)
            updateTopTabsVisibility()
        case "showPageUpDown":
            updatePageUpDown()
        case "pullToRefresh":
            tabManager.forEachWebView { wv, _ in updateRefreshControl(for: wv) }
        case "mobileUA", "desktopUA", "customMobileUA", "customDesktopUA":
            tabManager.forEachWebView { wv, tab in wv.customUserAgent = tab.isDesktop ? UserAgent.desktop : UserAgent.mobile }
        case "backgroundPlay":
            (UIApplication.shared.delegate as? AppDelegate)?.configureAudioSession()
        case "forwardPrefersNextPage":
            updateUI()
        case "videoFloating":
            videoStateChanged()
        case "subtitleFontSize", "subtitleMode":
            pageSubtitles.refreshStyle()
        case "translateTarget":
            if let tab = currentTab, tab.translateActive {
                pageTranslator.restore(tab: tab)
                pageTranslator.translate(tab: tab, userInitiated: true)
            }
        case "homepageMode", "centeredSearchBox", "bottomSearchButton", "wallpaperAlpha", "iconCornerRadius", "homeColumns":
            homeVC.reload()
        default: break
        }
    }

    @objc private func contentRulesChanged() { reinstallScripts() }

    func pageConfig() -> PageConfig { PageConfig.current(darkUI: traitCollection.userInterfaceStyle == .dark) }

    func reinstallScripts() {
        let cfg = pageConfig()
        tabManager.forEachWebView { wv, _ in
            ScriptManager.install(into: wv.configuration.userContentController, config: cfg)
            wv.evaluateJavaScript("window.__fa && __fa.apply(\(cfg.json))")
            wv.overrideUserInterfaceStyle = cfg.night ? .dark : .unspecified
        }
    }

    // MARK: Clipboard

    @objc private func clipboardChanged() { checkClipboardForURL() }

    func checkClipboardForURL() {
        guard Prefs.autoPasteCopied, UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings else { return }
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            guard case .success(let patterns) = result, patterns.contains(.probableWebURL) else { return }
            DispatchQueue.main.async {
                if let s = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string, URL.fromUserInput(s) != nil {
                    Prefs.lastCopiedURL = s
                }
            }
        }
    }
}

/// Indirection so the script message handler doesn't retain the browser.
final class WeakHandlerBox: NSObject, WKScriptMessageHandler {
    weak var handler: WKScriptMessageHandler?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?.userContentController(c, didReceive: message)
    }
}

// MARK: - TabManagerDelegate

extension BrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didCreateWebView webView: WKWebView, for tab: Tab) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: ScriptManager.handlerName)
        ucc.add(scriptHandler, name: ScriptManager.handlerName)
        let cfg = pageConfig()
        ScriptManager.install(into: ucc, config: cfg)
        webView.overrideUserInterfaceStyle = cfg.night ? .dark : .unspecified
        webView.backgroundColor = Theme.homeBackground
        webView.isOpaque = false

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(webLongPress(_:)))
        lp.minimumPressDuration = 0.45
        lp.delegate = self
        webView.addGestureRecognizer(lp)
        observe(webView)
    }

    func tabManager(_ manager: TabManager, didSelect tab: Tab, previous: Tab?) {
        if let prev = previous, let wv = prev.webView, !prev.showingHome {
            prev.screenshot = wv.snapshotImage() ?? prev.screenshot
        }
        if pickerBar != nil { stopElementPicker() }
        if !findBar.isHidden { hideFindBar() }
        display(tab: tab)
        updateTopTabsVisibility()
        updatePageUpDown()
    }

    func tabManagerDidUpdateTabs(_ manager: TabManager) {
        updateTopTabsVisibility()
        updateUI()
    }
}

// MARK: - Scrolling

extension BrowserViewController: UIScrollViewDelegate, UIGestureRecognizerDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastOffsetY = scrollView.contentOffset.y
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard Prefs.hideToolbarsOnScroll, !Prefs.fullscreen, sv.isTracking || sv.isDecelerating else { return }
        let y = sv.contentOffset.y
        let dy = y - lastOffsetY
        if y <= 0 {
            setBarsHidden(false, animated: true)
        } else if dy > 12, y > 40, sv.contentSize.height > sv.bounds.height * 1.4 {
            setBarsHidden(true, animated: true)
            lastOffsetY = y
        } else if dy < -18 {
            setBarsHidden(false, animated: true)
            lastOffsetY = y
        }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        setBarsHidden(false, animated: true)
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - URL bar / toolbar / top tabs delegates

extension BrowserViewController: URLBarViewDelegate {
    func urlBarDidTapLocation(_ bar: URLBarView) {
        let text = currentTab?.showingHome == false ? currentWebView?.url?.absoluteString : nil
        presentSearch(initialText: text)
    }

    func urlBarDidLongPressLocation(_ bar: URLBarView) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if let url = currentWebView?.url, currentTab?.showingHome == false {
            sheet.addAction(UIAlertAction(title: L("Copy URL"), style: .default) { _ in
                UIPasteboard.general.string = url.absoluteString
                Toast.show(L("Copied"))
            })
        }
        if let s = UIPasteboard.general.string, !s.trimmed.isEmpty {
            let isURL = URL.fromUserInput(s) != nil
            sheet.addAction(UIAlertAction(title: isURL ? L("Paste and Go") : L("Paste and Search"), style: .default) { [weak self] _ in
                self?.submit(text: s)
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: bar)
    }

    func urlBarDidTapShield(_ bar: URLBarView) { showSiteSettings() }

    func urlBarDidTapReload(_ bar: URLBarView) {
        guard let wv = currentWebView, currentTab?.showingHome == false else { return }
        if wv.isLoading { wv.stopLoading() } else { errorView.isHidden = true; wv.reload() }
    }

    func urlBarDidTapReader(_ bar: URLBarView) { openReaderMode() }

    func urlBarDidTapCollapsed(_ bar: URLBarView) { setBarsHidden(false, animated: true) }
}

extension BrowserViewController: TopTabsViewDelegate {
    func topTabsDidSelect(_ tab: Tab) { tabManager.selectTab(tab) }
    func topTabsDidClose(_ tab: Tab) { tabManager.removeTab(tab) }
    func topTabsDidTapAdd() { tabManager.addTab(url: nil) }
}
