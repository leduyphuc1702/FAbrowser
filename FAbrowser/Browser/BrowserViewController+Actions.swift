import UIKit
import WebKit
import AVKit
import UniformTypeIdentifiers

// MARK: - Navigation helpers

extension BrowserViewController {
    func load(_ url: URL, in tab: Tab? = nil) {
        guard let tab = tab ?? currentTab else { return }
        tabManager.load(url, in: tab)
        if tab === currentTab { display(tab: tab) }
    }

    func openInNewTab(_ url: URL, isPrivate: Bool? = nil) {
        if let tab = currentTab, tab.showingHome, tab.webView?.url == nil, isPrivate == nil || isPrivate == tab.isPrivate {
            load(url, in: tab)
        } else {
            tabManager.addTab(url: url, isPrivate: isPrivate, select: true)
        }
    }

    /// Handles what the user typed: URL, or a search with the given (or default) engine.
    func submit(text: String, engine: SearchEngine? = nil) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        if engine == nil, let url = URL.fromUserInput(t) {
            load(url)
            return
        }
        HistoryStore.shared.recordSearch(t)
        let e = engine ?? SearchEngineStore.shared.current
        if let url = e.url(for: t) { load(url) }
    }

    func presentSearch(initialText: String? = nil) {
        let vc = SearchViewController(initialText: initialText, isPrivate: tabManager.isPrivate)
        vc.onSubmit = { [weak self] text, engine in self?.submit(text: text, engine: engine) }
        vc.onOpenURL = { [weak self] url in self?.load(url) }
        vc.onScan = { [weak self] in self?.presentScanner() }
        vc.modalPresentationStyle = .overFullScreen
        vc.modalTransitionStyle = .crossDissolve
        present(vc, animated: true)
    }

    func goHome() {
        switch Prefs.homepageMode {
        case .navigation:
            showHome(true)
        case .customURL:
            if let u = URL.fromUserInput(Prefs.homepageURL) ?? URL(string: Prefs.homepageURL), u.scheme != nil { load(u) } else { showHome(true) }
        case .blank:
            load(URL(string: "about:blank")!)
        }
    }

    func handleShortcut(_ type: String) {
        dismiss(animated: false)
        switch type {
        case "Search": presentSearch()
        case "ScanQRCode": presentScanner()
        case "Library": presentLibrary()
        case "Files": presentFiles()
        default: break
        }
    }

    func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        if ext == "html" || ext == "htm", let s = try? String(contentsOf: url), s.contains("NETSCAPE-Bookmark") {
            confirm(L("Import Bookmarks"), message: L("Bookmarks file detected.Would you like to import bookmarks from this file?"), action: L("Import")) {
                let n = BookmarkStore.shared.importHTML(s)
                Toast.show(n > 0 ? L("Import Success") : L("Import Failed"))
            }
            return
        }
        if ext == "js", let s = try? String(contentsOf: url) {
            confirm(L("JavaScript Extensions"), message: L("JavaScript Extension Detected"), action: L("Add")) {
                JSExtensionStore.shared.upsert(JSExtensionStore.parse(fileContent: s, fallbackName: url.deletingPathExtension().lastPathComponent))
                Toast.show(L("Added"))
            }
            return
        }
        let dest = FileManager.default.uniqueURL(for: FileManager.default.downloadsURL.appendingPathComponent(url.lastPathComponent))
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            Toast.show(L("Added to Files"))
            presentFiles()
        } catch {
            showAlert(L("Error"), message: error.localizedDescription)
        }
    }
}

// MARK: - Toolbar

extension BrowserViewController: TabToolbarDelegate {
    func toolbarDidTapBack() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        if tab.showingHome {
            if wv.url != nil { showHome(false) }
            return
        }
        if !errorView.isHidden { errorView.isHidden = true }
        if wv.canGoBack { wv.goBack() } else { showHome(true) }
    }

    func toolbarDidTapForward() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        if tab.showingHome {
            if wv.url != nil { showHome(false) }
            return
        }
        if wv.canGoForward { wv.goForward() }
        else if Prefs.forwardPrefersNextPage, let next = tab.nextPageURL { load(next) }
    }

    func toolbarDidLongPressBack() { showBackForwardList(back: true) }
    func toolbarDidLongPressForward() { showBackForwardList(back: false) }

    private func showBackForwardList(back: Bool) {
        guard let wv = currentWebView else { return }
        let items = back ? Array(wv.backForwardList.backList.reversed().prefix(12)) : Array(wv.backForwardList.forwardList.prefix(12))
        guard !items.isEmpty else { return }
        let sheet = UIAlertController(title: L("Show Back Forward List"), message: nil, preferredStyle: .actionSheet)
        for item in items {
            let title = item.title?.isEmpty == false ? item.title! : item.url.displayString
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.showHome(false)
                wv.go(to: item)
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: back ? toolbar.backButton : toolbar.forwardButton)
    }

    func toolbarDidTapMenu() { presentMenu() }
    func toolbarDidLongPressMenu() { presentSettings() }
    func toolbarDidTapTabs() { presentTabTray() }

    func toolbarDidLongPressTabs() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L("New Tab"), style: .default) { [weak self] _ in self?.tabManager.addTab(url: nil, isPrivate: false) })
        sheet.addAction(UIAlertAction(title: L("New Private Tab"), style: .default) { [weak self] _ in self?.tabManager.addTab(url: nil, isPrivate: true) })
        sheet.addAction(UIAlertAction(title: L("Close Current Tab"), style: .default) { [weak self] _ in
            if let t = self?.currentTab { self?.tabManager.removeTab(t) }
        })
        let isPrivate = tabManager.isPrivate
        sheet.addAction(UIAlertAction(title: isPrivate ? L("Close All and Exit Private") : L("Close All Tabs"), style: .destructive) { [weak self] _ in
            self?.tabManager.removeAll(private: isPrivate)
        })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: toolbar.tabsButton)
    }

    func toolbarDidTapHome() { goHome() }

    func toolbarDidLongPressHome() {
        if Prefs.homepageMode != .navigation { showHome(true) } else { presentSettings(open: .homepage) }
    }
}

// MARK: - Homepage

extension BrowserViewController: HomePageDelegate {
    func homePage(_ vc: HomePageViewController, didSelect url: URL) { load(url) }
    func homePageDidRequestSearch(_ vc: HomePageViewController) { presentSearch() }
    func homePage(_ vc: HomePageViewController, openInNewTab url: URL, background: Bool) {
        tabManager.addTab(url: url, isPrivate: tabManager.isPrivate, select: !background)
        if background { Toast.show(L("Background Tab")) }
    }
    func homePageDidRequestScan(_ vc: HomePageViewController) { presentScanner() }
}

// MARK: - Presenters

extension BrowserViewController {
    func presentTabTray() {
        let show = { [weak self] in
            guard let self else { return }
            let tray = TabTrayController(tabManager: self.tabManager)
            tray.modalPresentationStyle = .fullScreen
            tray.modalTransitionStyle = .crossDissolve
            self.present(tray, animated: true)
        }
        guard let tab = currentTab else { show(); return }
        if tab.showingHome {
            tab.screenshot = homeVC.view.snapshotImage()
            show()
        } else if let wv = tab.webView {
            wv.takeSnapshot(with: nil) { img, _ in
                if let img { tab.screenshot = img }
                show()
            }
        } else {
            show()
        }
    }

    func presentLibrary(segment: Int = 0) {
        let lib = LibraryViewController(segment: segment)
        lib.onOpen = { [weak self] url, newTab in
            if newTab { self?.tabManager.addTab(url: url, select: true) } else { self?.load(url) }
        }
        present(UINavigationController(rootViewController: lib), animated: true)
    }

    func presentFiles() {
        let files = FilesViewController(directory: FileManager.default.documentsURL)
        files.onOpenWeb = { [weak self] url in self?.openInNewTab(url) }
        present(UINavigationController(rootViewController: files), animated: true)
    }

    func presentSettings(open: SettingsViewController.Page? = nil) {
        let settings = SettingsViewController(page: .root)
        settings.browser = self
        let nav = UINavigationController(rootViewController: settings)
        present(nav, animated: true) {
            if let open {
                let sub = SettingsViewController(page: open)
                sub.browser = self
                nav.pushViewController(sub, animated: true)
            }
        }
    }

    func presentScanner() {
        let scanner = QRScannerViewController()
        scanner.onResult = { [weak self] text in self?.handleScanned(text) }
        scanner.modalPresentationStyle = .fullScreen
        topMost.present(scanner, animated: true)
    }

    func handleScanned(_ text: String) {
        let sheet = UIAlertController(title: L("QR Code"), message: text, preferredStyle: .alert)
        if let url = URL.fromUserInput(text) ?? URL(string: text).flatMap({ $0.scheme != nil ? $0 : nil }) {
            sheet.addAction(UIAlertAction(title: L("Open in New Tab"), style: .default) { [weak self] _ in self?.openInNewTab(url) })
        } else {
            sheet.addAction(UIAlertAction(title: L("Search"), style: .default) { [weak self] _ in self?.submit(text: text) })
        }
        sheet.addAction(UIAlertAction(title: L("Copy"), style: .default) { _ in UIPasteboard.general.string = text; Toast.show(L("Copied")) })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        topMost.present(sheet, animated: true)
    }
}

// MARK: - Menu

extension BrowserViewController {
    func presentMenu() {
        let tab = currentTab
        let wv = currentWebView
        let onPage = tab?.showingHome == false && wv?.url != nil
        let url = wv?.url
        let isBookmarked = onPage && BookmarkStore.shared.isBookmarked(url)

        let items: [GridItem] = [
            GridItem(title: L("Bookmarks/History"), symbol: "book") { [weak self] in self?.presentLibrary() },
            GridItem(title: isBookmarked ? L("Remove Favorite") : L("Add Favorite"), symbol: isBookmarked ? "star.fill" : "star", isOn: isBookmarked, enabled: onPage) { [weak self] in self?.toggleBookmark() },
            GridItem(title: L("Files"), symbol: "folder", badge: DownloadManager.shared.activeCount > 0 ? "\(DownloadManager.shared.activeCount)" : nil) { [weak self] in self?.presentFiles() },
            GridItem(title: Prefs.nightMode ? L("Day Mode") : L("Night Mode"), symbol: Prefs.nightMode ? "sun.max" : "moon", isOn: Prefs.nightMode,
                     action: { Prefs.nightMode.toggle() },
                     longPress: {
                         Prefs.themeMode = Prefs.themeMode == .dark ? .light : .dark
                         Toast.show(Prefs.themeMode.title)
                     }),
            GridItem(title: L("Ad Block"), symbol: "shield.lefthalf.filled", isOn: Prefs.adBlock) {
                Prefs.adBlock.toggle()
                Toast.show(L("Ad Block") + ": " + (Prefs.adBlock ? L("On") : L("Off")))
            },
            GridItem(title: L("Text-Only"), symbol: Prefs.noImage ? "photo.badge.exclamationmark" : "photo", isOn: Prefs.noImage) { Prefs.noImage.toggle() },
            GridItem(title: Prefs.fullscreen ? L("Exit Fullscreen") : L("Fullscreen"), symbol: Prefs.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", isOn: Prefs.fullscreen) { Prefs.fullscreen.toggle() },
            GridItem(title: tab?.isDesktop == true ? L("Request Mobile") : L("Request Desktop"), symbol: tab?.isDesktop == true ? "iphone" : "desktopcomputer", isOn: tab?.isDesktop == true,
                     action: { [weak self] in self?.toggleDesktop(adjustM: false) },
                     longPress: { [weak self] in self?.toggleDesktop(adjustM: true) }),
            GridItem(title: L("Toolbox"), symbol: "wrench.and.screwdriver") { [weak self] in self?.presentToolbox() },
            GridItem(title: L("Settings"), symbol: "gearshape") { [weak self] in self?.presentSettings() },

            GridItem(title: L("Share"), symbol: "square.and.arrow.up", enabled: onPage) { [weak self] in
                guard let self, let url else { return }
                self.share([url])
            },
            GridItem(title: L("Refresh"), symbol: "arrow.clockwise", enabled: onPage) { [weak self] in self?.currentWebView?.reload() },
            GridItem(title: L("Private"), symbol: "eyeglasses", isOn: tabManager.isPrivate) { [weak self] in self?.togglePrivate() },
            GridItem(title: L("Find in Page"), symbol: "doc.text.magnifyingglass", enabled: onPage) { [weak self] in self?.showFindBar() },
            GridItem(title: L("Translate"), symbol: "character.bubble", isOn: tab?.translateActive == true, enabled: onPage) { [weak self] in self?.translatePage() },
            GridItem(title: L("Page Images"), symbol: "photo.on.rectangle", enabled: onPage) { [weak self] in self?.showPageImages() },
            GridItem(title: L("Video"), symbol: "play.rectangle", enabled: onPage) { [weak self] in self?.playPageVideo() },
            GridItem(title: L("JavaScript Extensions"), symbol: "puzzlepiece.extension") { [weak self] in self?.showActiveExtensions() },
            GridItem(title: L("Reader Mode"), symbol: "doc.plaintext", enabled: onPage) { [weak self] in self?.openReaderMode() },
            GridItem(title: L("Scan QRCode"), symbol: "qrcode.viewfinder") { [weak self] in self?.presentScanner() },
        ]
        let sheet = GridSheetViewController(title: onPage ? (wv?.title ?? url?.displayString) : nil, items: items, columns: 5, rowsPerPage: 2)
        sheet.isPrivate = tabManager.isPrivate
        present(sheet, animated: false)
    }

    func presentToolbox() {
        let tab = currentTab
        let onPage = tab?.showingHome == false && currentWebView?.url != nil
        let items: [GridItem] = [
            GridItem(title: L("Find in Page"), symbol: "doc.text.magnifyingglass", enabled: onPage) { [weak self] in self?.showFindBar() },
            GridItem(title: L("In-Page Translate"), symbol: "character.bubble", isOn: tab?.translateActive == true, enabled: onPage) { [weak self] in self?.translatePage() },
            GridItem(title: L("Live Subtitles"), symbol: "captions.bubble", isOn: LiveSubtitles.shared.isOn) { [weak self] in self?.toggleSubtitles(forPlayer: self?.floatingPlayer.isActive == true) },
            GridItem(title: L("Hide Element"), symbol: "eye.slash", enabled: onPage) { [weak self] in self?.startElementPicker() },
            GridItem(title: L("Page Images"), symbol: "photo.on.rectangle", enabled: onPage) { [weak self] in self?.showPageImages() },
            GridItem(title: L("View Page Source"), symbol: "chevron.left.forwardslash.chevron.right", enabled: onPage) { [weak self] in self?.viewSource() },
            GridItem(title: L("Snapshot"), symbol: "camera.viewfinder", enabled: onPage) { [weak self] in self?.takeSnapshot(full: false) },
            GridItem(title: L("Full Page Snapshot"), symbol: "rectangle.portrait.on.rectangle.portrait", enabled: onPage) { [weak self] in self?.takeSnapshot(full: true) },
            GridItem(title: L("Create PDF"), symbol: "doc.richtext", enabled: onPage) { [weak self] in self?.createPDF() },
            GridItem(title: L("Save page as..."), symbol: "square.and.arrow.down", enabled: onPage) { [weak self] in self?.savePageArchive() },
            GridItem(title: L("Print"), symbol: "printer", enabled: onPage) { [weak self] in self?.printPage() },
            GridItem(title: L("Generate QR Code"), symbol: "qrcode", enabled: onPage) { [weak self] in self?.showQRCode() },
            GridItem(title: L("Get All Text in Page"), symbol: "text.alignleft", enabled: onPage) { [weak self] in self?.showAllText() },
            GridItem(title: L("Search in Site"), symbol: "magnifyingglass", enabled: onPage) { [weak self] in
                if let host = self?.currentWebView?.url?.host { self?.presentSearch(initialText: "site:\(host) ") }
            },
            GridItem(title: tab?.autoRefreshInterval ?? 0 > 0 ? L("Stop Auto Refresh") : L("Auto Refresh"), symbol: "timer", isOn: (tab?.autoRefreshInterval ?? 0) > 0, enabled: onPage) { [weak self] in self?.chooseAutoRefresh() },
            GridItem(title: tab?.isScreenAlwaysOn == true ? L("Stop Screen Always On") : L("Screen Always On"), symbol: "sun.max.circle", isOn: tab?.isScreenAlwaysOn == true) { [weak self] in self?.toggleScreenAlwaysOn() },
            GridItem(title: L("Page Zoom"), symbol: "textformat.size") { [weak self] in self?.choosePageZoom() },
            GridItem(title: L("Add to homepage"), symbol: "plus.square.on.square", enabled: onPage) { [weak self] in self?.addCurrentToHomepage() },
            GridItem(title: L("User Hide Ad"), symbol: "list.bullet.rectangle") { [weak self] in
                let vc = HiddenElementsViewController(host: nil)
                self?.present(UINavigationController(rootViewController: vc), animated: true)
            },
            GridItem(title: L("Developer Tools"), symbol: "hammer", enabled: onPage) { [weak self] in self?.openDevTools() },
            GridItem(title: L("Wi-Fi Transfer"), symbol: "wifi") { [weak self] in
                self?.present(UINavigationController(rootViewController: WiFiTransferViewController()), animated: true)
            },
            GridItem(title: L("Webpage Green Background"), symbol: "leaf", isOn: Prefs.eyeCare) { Prefs.eyeCare.toggle() },
            GridItem(title: L("Desktop/Mobile Switch"), symbol: "arrow.left.arrow.right", enabled: onPage) { [weak self] in self?.toggleDesktop(adjustM: true) },
            GridItem(title: L("Clear Data"), symbol: "trash") { [weak self] in self?.presentSettings(open: .privacy) },
        ]
        let sheet = GridSheetViewController(title: L("Toolbox"), items: items, columns: 5, rowsPerPage: 3)
        sheet.isPrivate = tabManager.isPrivate
        present(sheet, animated: false)
    }

    func toggleBookmark() {
        guard let wv = currentWebView, let url = wv.url else { return }
        if let b = BookmarkStore.shared.bookmark(for: url) {
            BookmarkStore.shared.remove(id: b.id)
            Toast.show(L("Removed"))
        } else {
            let vc = BookmarkEditViewController(mode: .new(title: wv.title ?? url.displayString, url: url.absoluteString))
            present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

    func togglePrivate() {
        let toPrivate = !tabManager.isPrivate
        if let t = tabManager.tabs(private: toPrivate).max(by: { $0.lastActive < $1.lastActive }) {
            tabManager.selectTab(t)
        } else {
            tabManager.addTab(url: nil, isPrivate: toPrivate)
        }
        Toast.show(toPrivate ? L("Private Browsing") : L("Normal"))
    }

    func toggleDesktop(adjustM: Bool) {
        guard let tab = currentTab, let wv = tab.webView else { return }
        tab.isDesktop.toggle()
        wv.customUserAgent = tab.isDesktop ? UserAgent.desktop : UserAgent.mobile
        if adjustM, let url = wv.url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host {
            if tab.isDesktop, host.hasPrefix("m.") { comps.host = String(host.dropFirst(2)) }
            else if !tab.isDesktop, !host.hasPrefix("m.") { comps.host = "m." + host.replacingOccurrences(of: "www.", with: "") }
            if let u = comps.url { wv.load(URLRequest(url: u)); Toast.show(tab.isDesktop ? L("Request Desktop Site") : L("Request Mobile Site")); return }
        }
        if wv.url != nil { wv.reload() }
        Toast.show(tab.isDesktop ? L("Request Desktop Site") : L("Request Mobile Site"))
    }

    func chooseAutoRefresh() {
        guard let tab = currentTab else { return }
        if tab.autoRefreshInterval > 0 {
            tab.stopAutoRefresh()
            Toast.show(L("Stop Auto Refresh"))
            return
        }
        let sheet = UIAlertController(title: L("Auto Refresh"), message: nil, preferredStyle: .actionSheet)
        for i in AutoRefreshInterval.allCases {
            sheet.addAction(UIAlertAction(title: i.title, style: .default) { _ in
                tab.startAutoRefresh(seconds: i.rawValue)
                Toast.show(L("Start Refresh") + " · " + i.title)
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    func toggleScreenAlwaysOn() {
        guard let tab = currentTab else { return }
        tab.isScreenAlwaysOn.toggle()
        UIApplication.shared.isIdleTimerDisabled = tab.isScreenAlwaysOn
        Toast.show(tab.isScreenAlwaysOn ? L("Screen Always On") : L("Stop Screen Always On"))
    }

    func choosePageZoom() {
        let sheet = UIAlertController(title: L("Page Zoom") + " · \(Prefs.pageZoom)%", message: nil, preferredStyle: .actionSheet)
        for z in [50, 75, 85, 100, 115, 125, 150, 175, 200] {
            sheet.addAction(UIAlertAction(title: "\(z)%" + (z == Prefs.pageZoom ? " ✓" : ""), style: .default) { _ in Prefs.pageZoom = z })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    func addCurrentToHomepage() {
        guard let wv = currentWebView, let url = wv.url else { return }
        BookmarkStore.shared.addHomeSite(HomeSite(title: wv.title?.isEmpty == false ? wv.title! : url.displayString, url: url.absoluteString))
        Toast.show(L("Added"))
    }

    func openDevTools() {
        let js = "(function(){if(window.eruda){eruda.show();return;}var s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/eruda';s.onload=function(){eruda.init();eruda.show();};document.body.appendChild(s);})();"
        currentWebView?.evaluateJavaScript(js)
    }

    func showActiveExtensions() {
        let url = currentWebView?.url
        let active = JSExtensionStore.shared.active(for: url)
        let sheet = UIAlertController(title: L("Active Extension"), message: active.isEmpty ? L("No Active Extension Hint") : nil, preferredStyle: .actionSheet)
        if currentTab?.showingHome == false {
            for ext in active {
                sheet.addAction(UIAlertAction(title: ext.name, style: .default) { [weak self] _ in
                    self?.currentWebView?.evaluateJavaScript(ScriptManager.wrap(ext)) { _, err in
                        Toast.show(err == nil ? ext.name : (L("Error") + ": " + (err?.localizedDescription ?? "")))
                    }
                })
            }
        }
        sheet.addAction(UIAlertAction(title: L("JavaScript Extensions") + "…", style: .default) { [weak self] _ in
            self?.present(UINavigationController(rootViewController: ExtensionsViewController()), animated: true)
        })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    func showSiteSettings() {
        guard let tab = currentTab else { return }
        let vc = SiteSettingsViewController(tab: tab, browser: self)
        let nav = UINavigationController(rootViewController: vc)
        if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(nav, animated: true)
    }
}

// MARK: - Page tools

extension BrowserViewController {
    func showFindBar() {
        guard currentTab?.showingHome == false else { return }
        findBar.isHidden = false
        view.bringSubviewToFront(findBar)
        findBar.field.becomeFirstResponder()
        if let t = findBar.field.text, !t.isEmpty { find(t) }
    }

    func hideFindBar() {
        findBar.field.resignFirstResponder()
        findBar.isHidden = true
        currentWebView?.evaluateJavaScript("window.__fa && __fa.findClear()")
    }

    func find(_ q: String) {
        currentWebView?.evaluateJavaScript("window.__fa ? __fa.find(\(q.jsEscaped)) : null") { [weak self] r, _ in
            let d = r as? [String: Any]
            self?.findBar.setCount(current: d?["i"] as? Int ?? 0, total: d?["n"] as? Int ?? 0)
        }
    }

    func findStep(_ d: Int) {
        currentWebView?.evaluateJavaScript("window.__fa ? __fa.findStep(\(d)) : null") { [weak self] r, _ in
            let d = r as? [String: Any]
            self?.findBar.setCount(current: d?["i"] as? Int ?? 0, total: d?["n"] as? Int ?? 0)
        }
    }

    func showPageImages() {
        currentWebView?.evaluateJavaScript("window.__fa ? __fa.images() : []") { [weak self] r, _ in
            let urls = (r as? [String] ?? []).compactMap(URL.init(string:))
            guard !urls.isEmpty else { Toast.show(L("No Image Found")); return }
            let vc = GalleryViewController(urls: urls)
            vc.onSave = { url in self?.saveImage(url: url) }
            self?.present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

    func viewSource() {
        currentWebView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] r, _ in
            let vc = TextViewerViewController(title: L("View Page Source"), text: r as? String ?? "", monospaced: true)
            self?.present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

    func showAllText() {
        currentWebView?.evaluateJavaScript("window.__fa ? __fa.text() : document.body.innerText") { [weak self] r, _ in
            var text = r as? String ?? ""
            if Prefs.removeLineBreaks { text = text.replacingOccurrences(of: "\n", with: " ") }
            let vc = TextViewerViewController(title: L("Get All Text in Page"), text: text, monospaced: false)
            self?.present(UINavigationController(rootViewController: vc), animated: true)
        }
    }

    func takeSnapshot(full: Bool) {
        guard let wv = currentWebView else { return }
        if !full {
            wv.takeSnapshot(with: nil) { [weak self] img, _ in
                guard let img else { Toast.show(L("Screenshot failed")); return }
                self?.present(UINavigationController(rootViewController: ImagePreviewViewController(image: img)), animated: true)
            }
            return
        }
        Toast.show(L("Capture..."))
        wv.createPDF { [weak self] result in
            guard case .success(let data) = result, let img = PDFRenderer.longImage(from: data) else {
                Toast.show(L("Screenshot failed") + "\n" + L("Screenshot Hint Content"))
                return
            }
            self?.present(UINavigationController(rootViewController: ImagePreviewViewController(image: img)), animated: true)
        }
    }

    private func safeFileName(_ s: String?) -> String {
        let base = (s?.isEmpty == false ? s! : "page").components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "_")
        return String(base.prefix(80))
    }

    func createPDF() {
        guard let wv = currentWebView else { return }
        wv.createPDF { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                let url = FileManager.default.uniqueURL(for: FileManager.default.downloadsURL.appendingPathComponent(self.safeFileName(wv.title) + ".pdf"))
                do { try data.write(to: url); Toast.show(L("Saved to files")); self.share([url]) } catch { self.showAlert(L("Save Failed"), message: error.localizedDescription) }
            case .failure(let e):
                self.showAlert(L("Create Error"), message: e.localizedDescription)
            }
        }
    }

    func savePageArchive() {
        guard let wv = currentWebView else { return }
        wv.createWebArchiveData { [weak self] result in
            guard let self else { return }
            if case .success(let data) = result {
                let url = FileManager.default.uniqueURL(for: FileManager.default.downloadsURL.appendingPathComponent(self.safeFileName(wv.title) + ".webarchive"))
                try? data.write(to: url)
                Toast.show(L("Saved to files"))
            } else {
                Toast.show(L("Save Failed"))
            }
        }
    }

    func printPage() {
        guard let wv = currentWebView else { return }
        let pc = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = wv.title ?? "FAbrowser"
        pc.printInfo = info
        pc.printFormatter = wv.viewPrintFormatter()
        pc.present(animated: true)
    }

    func showQRCode() {
        guard let url = currentWebView?.url, let img = QRCode.generate(url.absoluteString) else { return }
        present(UINavigationController(rootViewController: ImagePreviewViewController(image: img, caption: url.absoluteString)), animated: true)
    }

    func openReaderMode() {
        guard let wv = currentWebView else { return }
        wv.evaluateJavaScript("window.__fa ? __fa.reader() : null") { [weak self] r, _ in
            guard let d = r as? [String: Any], let html = d["html"] as? String else {
                Toast.show(L("Reader mode is not available for this page"))
                return
            }
            let vc = ReaderViewController(title: d["title"] as? String ?? "", html: html, baseURL: wv.url,
                                          next: (d["next"] as? String).flatMap(URL.init(string:)), isPrivate: self?.tabManager.isPrivate ?? false)
            vc.modalPresentationStyle = .fullScreen
            self?.present(vc, animated: true)
        }
    }

    // MARK: Element picker

    func startElementPicker() {
        guard let wv = currentWebView, pickerBar == nil else { return }
        wv.evaluateJavaScript("window.__fa && __fa.pickStart()")
        let bar = ElementPickerBar()
        bar.setHint(L("Tap an element to select it"))
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12),
        ])
        bar.onExpand = { [weak self] in
            self?.currentWebView?.evaluateJavaScript("window.__fa && __fa.pickParent()") { r, _ in
                if let s = r as? String { self?.pickerBar?.setHint(s) }
            }
        }
        bar.onHide = { [weak self] in
            guard let wv = self?.currentWebView else { return }
            wv.evaluateJavaScript("window.__fa && __fa.pickHide()") { r, _ in
                guard let sel = r as? String, !sel.isEmpty, let host = wv.url?.normalizedHost else { return }
                AdBlocker.shared.addUserRule(host: host, selector: sel)
                Toast.show(L("Element Hidden"))
            }
        }
        bar.onDone = { [weak self] in self?.stopElementPicker() }
        pickerBar = bar
    }

    func stopElementPicker() {
        currentWebView?.evaluateJavaScript("window.__fa && __fa.pickStop()")
        pickerBar?.removeFromSuperview()
        pickerBar = nil
    }
}

enum PDFRenderer {
    /// Stitches all PDF pages vertically into one image (used for full page snapshots).
    static func longImage(from data: Data, maxHeight: CGFloat = 16000) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else { return nil }
        var pages: [CGPDFPage] = []
        var size = CGSize.zero
        for i in 1...doc.numberOfPages {
            guard let p = doc.page(at: i) else { continue }
            let r = p.getBoxRect(.mediaBox)
            if size.height + r.height > maxHeight { break }
            size.width = max(size.width, r.width)
            size.height += r.height
            pages.append(p)
        }
        guard size.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var y: CGFloat = 0
            let cg = ctx.cgContext
            for p in pages {
                let r = p.getBoxRect(.mediaBox)
                cg.saveGState()
                cg.translateBy(x: 0, y: y + r.height)
                cg.scaleBy(x: 1, y: -1)
                cg.drawPDFPage(p)
                cg.restoreGState()
                y += r.height
            }
        }
    }
}
