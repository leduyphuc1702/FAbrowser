import UIKit
import WebKit
import Photos

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let tab = tabManager.tab(for: webView)
        preferences.preferredContentMode = tab?.isDesktop == true ? .desktop : .mobile

        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "file", "data", "blob", "javascript"].contains(scheme) {
            if action.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }
            // "Open Click Link in New Tab": user-activated main frame links to another page open in a new tab.
            if Prefs.openClickLinkInNewTab, action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
               let current = webView.url, url.absoluteString.components(separatedBy: "#").first != current.absoluteString.components(separatedBy: "#").first {
                tabManager.addTab(url: url, isPrivate: tab?.isPrivate, select: true)
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.allow, preferences)
            return
        }

        decisionHandler(.cancel, preferences)
        let userInitiated = action.navigationType == .linkActivated || action.navigationType == .formSubmitted
        if Prefs.blockAppJump, !userInitiated, !["tel", "mailto", "sms"].contains(scheme) {
            // Sites that bounce visitors into their app without a tap ("Block App Jump").
            Toast.show(LF("Blocked %@ from opening an app", webView.url?.host ?? scheme), action: L("Open")) { [weak self] in
                self?.openExternal(url, from: webView, userInitiated: true)
            }
            return
        }
        openExternal(url, from: webView, userInitiated: userInitiated)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if response.isForMainFrame, !response.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        Toast.show(L("Downloading"))
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
        Toast.show(L("Downloading"))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tabManager.tab(for: webView) else { return }
        tab.nextPageURL = nil
        tab.videos = []
        if tab === currentTab {
            videoStateChanged()
            errorView.isHidden = true
            if tab.showingHome { showHome(false) }
            updateUI()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabManager.tab(for: webView) else { return }
        tab.url = webView.url
        if tab === currentTab { updateUI(); updatePageUpDown() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabManager.tab(for: webView) else { return }
        tab.url = webView.url
        tab.title = webView.title
        if !tab.isPrivate, let url = webView.url { HistoryStore.shared.record(url: url, title: webView.title) }
        if tab === currentTab {
            updateUI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak tab] in
                guard let self, let tab, tab === self.currentTab, !tab.showingHome else { return }
                webView.takeSnapshot(with: nil) { img, _ in if let img { tab.screenshot = img } }
            }
        }
        if let url = webView.url { FaviconManager.shared.icon(for: url) { [weak self] _ in self?.updateTopTabs() } }
        webView.scrollView.refreshControl?.endRefreshing()
        tabManager.scheduleSave()
        if tab.translateActive { pageTranslator.pageLoaded(tab: tab) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error, webView: webView)
    }

    private func handleLoadError(_ error: Error, webView: WKWebView) {
        webView.scrollView.refreshControl?.endRefreshing()
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return } // frame load interrupted / plugin handled
        guard webView === currentWebView, currentTab?.showingHome == false else { return }
        errorView.configure(error: error, url: (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url)
        errorView.isHidden = false
        webContainer.bringSubviewToFront(errorView)
        updateUI()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM {
            let host = challenge.protectionSpace.host
            let message = challenge.protectionSpace.realm.map { LF("A username and password are being requested by %@. The site says: %@", host, $0) }
                ?? LF("A username and password are being requested by %@.", host)
            let alert = UIAlertController(title: L("Authentication required"), message: message, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = L("Username"); $0.autocapitalizationType = .none }
            alert.addTextField { $0.placeholder = L("Password"); $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in completionHandler(.cancelAuthenticationChallenge, nil) })
            alert.addAction(UIAlertAction(title: L("Log in"), style: .default) { _ in
                let cred = URLCredential(user: alert.textFields?[0].text ?? "", password: alert.textFields?[1].text ?? "", persistence: .forSession)
                completionHandler(.useCredential, cred)
            })
            topMost.present(alert, animated: true)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: External apps

    func openExternal(_ url: URL, from webView: WKWebView, userInitiated: Bool) {
        let scheme = url.scheme?.lowercased() ?? ""
        let site = webView.url?.host ?? "FAbrowser"
        if ["tel", "mailto", "sms", "facetime", "facetime-audio"].contains(scheme) {
            UIApplication.shared.open(url)
            return
        }
        let isAppStore = scheme == "itms-apps" || scheme == "itms-appss" || url.host == "apps.apple.com"
        let title = isAppStore ? LF("Open App Store Title", site) : LF("%@ want to open %@", site, scheme)
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Allow"), style: .default) { _ in
            UIApplication.shared.open(url) { ok in if !ok { Toast.show(LF("Can't open %@", url.absoluteString)) } }
        })
        topMost.present(alert, animated: true)
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if Prefs.preferCurrentTab {
            webView.load(action.request)
            return nil
        }
        let parent = tabManager.tab(for: webView)
        let tab = tabManager.addTab(url: nil, isPrivate: parent?.isPrivate, select: true, configuration: configuration)
        tab.url = url
        tab.showingHome = false
        display(tab: tab)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabManager.tab(for: webView) { tabManager.removeTab(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in completionHandler() })
        presentPanel(a, fallback: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in completionHandler(true) })
        presentPanel(a) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        presentPanel(a) { completionHandler(nil) }
    }

    private func presentPanel(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        let top = topMost
        if top.view.window == nil || top is UIAlertController { fallback(); return }
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Script messages

extension BrowserViewController: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let wv = message.webView, let tab = tabManager.tab(for: wv) else { return }
        switch type {
        case "ready", "loaded":
            if let next = body["next"] as? String, let url = URL(string: next) { tab.nextPageURL = url } else if type == "ready" { tab.nextPageURL = nil }
            if let icon = body["icon"] as? String, let iconURL = URL(string: icon), let page = wv.url {
                FaviconManager.shared.setIcon(from: iconURL, for: page)
            }
            if tab === currentTab { updateUI() }
        case "picked":
            pickerBar?.setHint((body["selector"] as? String) ?? "")
        case "video":
            handleVideoMessage(body, frame: message.frameInfo, tab: tab)
        case "trMore":
            pageTranslator.pump(tab: tab)
        case "popupBlocked":
            guard tab === currentTab else { return }
            let target = (body["url"] as? String).flatMap(URL.init(string:))
            if let target, target.isWebURL {
                Toast.show(L("Blocked a pop-up window"), action: L("Open")) { [weak self] in
                    self?.tabManager.addTab(url: target, isPrivate: tab.isPrivate, select: true)
                }
            } else {
                Toast.show(L("Blocked a pop-up window"), in: view)
            }
        default:
            break
        }
    }
}

// MARK: - Long press context menu

extension BrowserViewController {
    @objc func webLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let wv = g.view as? WKWebView else { return }
        wv.evaluateJavaScript("window.__fa ? __fa.touchInfo() : null") { [weak self] result, _ in
            guard let self, let info = result as? [String: Any] else { return }
            let link = (info["link"] as? String).flatMap(URL.init(string:))
            let image = (info["image"] as? String).flatMap(URL.init(string:))
            let title = info["title"] as? String
            guard link != nil || image != nil else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.showContextMenu(link: link, linkTitle: title, image: image, point: g.location(in: self.view))
        }
    }

    func showContextMenu(link: URL?, linkTitle: String?, image: URL?, point: CGPoint) {
        let sheet = UIAlertController(title: (link ?? image)?.absoluteString, message: nil, preferredStyle: .actionSheet)
        let isPrivate = tabManager.isPrivate
        if let link {
            sheet.addAction(UIAlertAction(title: L("Open in New Tab"), style: .default) { [weak self] _ in
                self?.tabManager.addTab(url: link, isPrivate: isPrivate, select: true)
            })
            sheet.addAction(UIAlertAction(title: L("Open in Background"), style: .default) { [weak self] _ in
                self?.tabManager.addTab(url: link, isPrivate: isPrivate, select: false)
                Toast.show(L("Background Tab"))
            })
            if !isPrivate {
                sheet.addAction(UIAlertAction(title: L("New Private Tab"), style: .default) { [weak self] _ in
                    self?.tabManager.addTab(url: link, isPrivate: true, select: true)
                })
            }
            sheet.addAction(UIAlertAction(title: L("Copy URL"), style: .default) { _ in
                UIPasteboard.general.url = link
                Toast.show(L("Copied"))
            })
            if let t = linkTitle, !t.isEmpty {
                sheet.addAction(UIAlertAction(title: L("Copy Link Text"), style: .default) { _ in
                    UIPasteboard.general.string = t
                    Toast.show(L("Copied"))
                })
            }
            sheet.addAction(UIAlertAction(title: L("Download File"), style: .default) { _ in
                DownloadManager.shared.download(url: link)
                Toast.show(L("Downloading"))
            })
            sheet.addAction(UIAlertAction(title: L("Add to Library"), style: .default) { _ in
                BookmarkStore.shared.add(title: linkTitle?.isEmpty == false ? linkTitle! : link.displayString, url: link.absoluteString)
                Toast.show(L("Added"))
            })
            sheet.addAction(UIAlertAction(title: L("Share URL"), style: .default) { [weak self] _ in self?.share([link]) })
        }
        if let image {
            sheet.addAction(UIAlertAction(title: L("Save to Album"), style: .default) { [weak self] _ in self?.saveImage(url: image) })
            sheet.addAction(UIAlertAction(title: L("Copy Image"), style: .default) { _ in
                ImageLoader.load(image) { img in
                    if let img { UIPasteboard.general.image = img; Toast.show(L("Copied")) } else { Toast.show(L("Get Image Failed")) }
                }
            })
            sheet.addAction(UIAlertAction(title: L("Copy Image URL"), style: .default) { _ in
                UIPasteboard.general.url = image
                Toast.show(L("Copied"))
            })
            sheet.addAction(UIAlertAction(title: L("Open Image in New Tab"), style: .default) { [weak self] _ in
                self?.tabManager.addTab(url: image, isPrivate: isPrivate, select: true)
            })
            sheet.addAction(UIAlertAction(title: L("Search by Image"), style: .default) { [weak self] _ in
                let enc = image.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
                if let u = URL(string: "https://lens.google.com/uploadbyurl?url=\(enc)") { self?.tabManager.addTab(url: u, isPrivate: isPrivate) }
            })
            sheet.addAction(UIAlertAction(title: L("Extract QR Code"), style: .default) { [weak self] _ in
                ImageLoader.load(image) { img in
                    guard let img, let text = QRCode.detect(in: img) else { Toast.show(L("qrcode.nocode")); return }
                    self?.handleScanned(text)
                }
            })
            sheet.addAction(UIAlertAction(title: L("Share Image"), style: .default) { [weak self] _ in
                ImageLoader.load(image) { img in if let img { self?.share([img]) } }
            })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        present(sheet, animated: true)
    }

    func saveImage(url: URL) {
        ImageLoader.loadData(url) { data in
            guard let data, let img = UIImage(data: data) else { Toast.show(L("Get Image Failed")); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { Toast.show(L("Please enable Photos for FAbrowser")) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    if url.pathExtension.lowercased() == "gif" || data.starts(with: [0x47, 0x49, 0x46]) {
                        req.addResource(with: .photo, data: data, options: nil)
                    } else {
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }
                }) { ok, _ in
                    DispatchQueue.main.async { Toast.show(ok ? L("Saved") : L("Save Failed")) }
                }
            }
        }
    }
}

enum ImageLoader {
    static func loadData(_ url: URL, completion: @escaping (Data?) -> Void) {
        if url.scheme == "data", let comma = url.absoluteString.firstIndex(of: ",") {
            let payload = String(url.absoluteString[url.absoluteString.index(after: comma)...])
            completion(Data(base64Encoded: payload.removingPercentEncoding ?? payload))
            return
        }
        var req = URLRequest(url: url)
        req.setValue(UserAgent.mobile, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async { completion(data) }
        }.resume()
    }

    static func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        loadData(url) { completion($0.flatMap(UIImage.init(data:))) }
    }
}
