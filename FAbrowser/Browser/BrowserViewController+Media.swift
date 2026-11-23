import UIKit
import WebKit

// MARK: - Floating video, offline translation and live subtitles

extension BrowserViewController {
    func setupMedia() {
        translateBar.onShowOriginal = { [weak self] in
            guard let self, let tab = self.currentTab else { return }
            self.pageTranslator.showOriginal(tab: tab)
        }
        translateBar.onTranslate = { [weak self] in
            guard let self, let tab = self.currentTab else { return }
            self.pageTranslator.accept(tab: tab)
        }
        translateBar.onClose = { [weak self] in
            guard let self, let tab = self.currentTab else { return }
            self.pageTranslator.dismiss(tab: tab)
        }
        translateBar.onChangeTarget = { [weak self] in self?.chooseTranslateTarget() }
        translateBar.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.view.setNeedsLayout()
            UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        }
        view.insertSubview(translateBar, aboveSubview: webContainer)

        pageSubtitles.isHidden = true
        pageSubtitles.onTap = { [weak self] in self?.showSubtitleOptions() }
        view.insertSubview(pageSubtitles, aboveSubview: translateBar)

        videoButton.isHidden = true
        videoButton.addTarget(self, action: #selector(videoButtonTapped), for: .touchUpInside)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(videoButtonLongPressed(_:)))
        videoButton.addGestureRecognizer(lp)
        view.insertSubview(videoButton, belowSubview: toolbar)

        floatingPlayer.subtitleView.onTap = { [weak self] in self?.showSubtitleOptions() }
        LiveSubtitles.shared.onStateChange = { [weak self] on in self?.subtitlesStateChanged(on) }
        AdBlocker.shared.autoUpdateIfNeeded()
    }

    func layoutMedia() {
        if floatingPlayer.isActive { floatingPlayer.layout() }
        let playerHeight = floatingPlayer.reservedTopHeight
        let reserved = playerHeight + (translateBar.isHidden ? 0 : 38)
        if abs(webContainerTop.constant - reserved) > 0.5 {
            webContainerTop.constant = reserved
            view.setNeedsLayout()
        }
        let wc = webContainer.frame
        translateBar.frame = CGRect(x: wc.minX, y: wc.minY - (translateBar.isHidden ? 0 : 38), width: wc.width, height: 38)
        let size: CGFloat = 44
        let safe = view.safeAreaInsets
        videoButton.frame = CGRect(x: view.bounds.width - safe.right - size - 14, y: toolbar.frame.minY - size - 16, width: size, height: size)
        let bottomInset: CGFloat = videoButton.isHidden ? 18 : size + 26
        pageSubtitles.layoutIn(bounds: wc, bottomInset: bottomInset, compact: false)
    }

    func mediaTabChanged(_ tab: Tab) {
        if tab.translateActive, let from = tab.translatedFrom {
            translateBar.show(from: from, to: Prefs.translateTarget, progress: 1)
        } else if let s = tab.translateSuggested {
            translateBar.showSuggestion(from: s, to: Prefs.translateTarget, original: false)
        } else {
            translateBar.hide()
        }
        videoStateChanged()
    }

    // MARK: Video detection

    func handleVideoMessage(_ body: [String: Any], frame: WKFrameInfo, tab: Tab) {
        guard let v = DetectedVideo(message: body, frame: frame) else { return }
        if let i = tab.videos.firstIndex(where: { $0.key == v.key }) {
            var merged = v
            if merged.title.isEmpty { merged.title = tab.videos[i].title }
            tab.videos[i] = merged
        } else {
            tab.videos.append(v)
            if tab.videos.count > 30 { tab.videos.removeFirst() }
        }
        guard tab === currentTab else { return }
        videoStateChanged()
        guard Prefs.videoFloating else { return }

        if v.isAd {
            if v.reason == "play", !floatingPlayer.isActive, !tab.adNoticeShown {
                tab.adNoticeShown = true
                Toast.show(L("Waiting for the video ad to finish…"))
            }
            return
        }
        // A stream played through MSE shows up as a blob; open the playlist the page fetched instead.
        let target = v.isBlob ? streamCandidate(for: v, in: tab) : v
        let fp = floatingPlayer
        if fp.isActive {
            guard let target, let url = target.src, url != fp.source?.url else { return }
            // The window caught an ad (or a short teaser) first: switch to the real video once it starts.
            let caughtShort = fp.duration > 0 && fp.duration <= 60 && (target.duration == 0 || target.duration > 60)
            if (v.reason == "replace" && Prefs.allowAutoReplace) || (v.reason == "play" || v.reason == "replace") && caughtShort {
                play(target, in: tab)
            }
            return
        }
        // "Video Floating": open the window as soon as a real video starts playing.
        let started: Bool = {
            if v.reason == "play" { return true }
            // m3u8 fetched after its blob <video> already started.
            if v.reason == "net" { return tab.videos.contains { $0.isBlob && $0.playing && !$0.isAd && Date().timeIntervalSince($0.reportedAt) < 15 } }
            return false
        }()
        guard started, let target, !v.loop, v.viewWidth == 0 || v.viewWidth >= 120,
              v.reason == "net" || v.userGesture || !v.muted && (v.duration == 0 || v.duration > 45) else { return }
        play(target, in: tab)
    }

    /// For a blob/MSE video, the most recent playlist URL the page requested, carrying the
    /// blob video's position and frame.
    private func streamCandidate(for v: DetectedVideo, in tab: Tab) -> DetectedVideo? {
        if !v.isBlob { return v }
        guard var s = tab.videos.last(where: { $0.reason == "net" && !$0.isBlob && !$0.isAd }) else { return nil }
        if let blob = tab.videos.last(where: { $0.isBlob && !$0.isAd }) {
            s.time = blob.time
            s.duration = blob.duration
            s.frame = blob.frame ?? s.frame
            if s.title.isEmpty { s.title = blob.title }
        }
        return s
    }

    /// Best candidate for the floating button: the playing video, else the most recent non-stream one.
    private func candidates(for tab: Tab) -> [DetectedVideo] {
        let real = tab.videos.filter { !$0.isBlob && !$0.isAd }
        let playable = real.isEmpty ? tab.videos.filter { !$0.isBlob } : real
        return playable.sorted { a, b in
            if a.playing != b.playing { return a.playing }
            return a.reportedAt > b.reportedAt
        }
    }

    func videoStateChanged() {
        let tab = currentTab
        let hasVideo = tab?.showingHome == false && !(tab?.videos.isEmpty ?? true)
        let show = floatingPlayer.isActive ? floatingPlayer.mode != .mini : hasVideo
        videoButton.active = floatingPlayer.isActive
        if videoButton.isHidden == show {
            videoButton.isHidden = !show
            if show {
                videoButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) { self.videoButton.transform = .identity }
            }
            view.setNeedsLayout()
        }
    }

    func play(_ v: DetectedVideo, in tab: Tab) {
        guard let url = v.src, let wv = tab.webView else { return }
        let fp = floatingPlayer
        if let old = fp.originFrame, fp.isActive { wv.evaluateJavaScript("window.__faV && __faV.setTakeover(false)", in: old, in: .page) }
        fp.originFrame = v.frame
        fp.originTab = tab
        let js = Prefs.allowAutoReplace ? "window.__faV && __faV.setTakeover(true)" : "window.__faV && __faV.pause()"
        wv.evaluateJavaScript(js, in: v.frame, in: .page)
        let title = v.title.isEmpty ? (tab.title ?? url.lastPathComponent) : v.title
        fp.onPlayInPage = { [weak self, weak tab] t in
            guard let self, let tab, let wv = tab.webView else { return }
            self.floatingPlayer.originFrame = nil
            wv.evaluateJavaScript("window.__faV && __faV.resumeAt(\(t))", in: v.frame, in: .page)
        }
        fp.onClosed = { [weak tab] _ in
            guard let wv = tab?.webView else { return }
            wv.evaluateJavaScript("window.__faV && __faV.setTakeover(false)", in: v.frame, in: .page)
        }
        fp.onModeChanged = { [weak self] _ in
            guard let self else { return }
            self.videoStateChanged()
            self.view.setNeedsLayout()
            UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
        }
        fp.play(VideoSource(url: url, title: title, pageURL: v.page ?? tab.url, startTime: v.time, isPrivate: tab.isPrivate), in: self)
        videoStateChanged()
    }

    @objc func videoButtonTapped() {
        if floatingPlayer.isActive {
            floatingPlayer.setMode(floatingPlayer.mode == .top ? .mini : .top)
            return
        }
        playPageVideo()
    }

    @objc private func videoButtonLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if floatingPlayer.isActive { floatingPlayer.close(); return }
        Prefs.videoFloating.toggle()
        Toast.show(L("Video Floating") + ": " + (Prefs.videoFloating ? L("On") : L("Off")))
    }

    /// Menu "Video" item and the floating button: open the page's video in the native floating player.
    func playPageVideo() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        wv.evaluateJavaScript("window.__faV ? __faV.list() : []") { [weak self] r, _ in
            guard let self else { return }
            for d in r as? [[String: Any]] ?? [] {
                var body = d
                body["reason"] = "meta"
                if let v = DetectedVideo(message: body, frame: nil), !tab.videos.contains(where: { $0.key == v.key }) {
                    tab.videos.append(v)
                }
            }
            let list = self.candidates(for: tab)
            if list.isEmpty {
                if tab.videos.contains(where: { $0.isBlob }) { self.showStreamVideoOptions(tab: tab) } else {
                    Toast.show(L("No video found. Start playing the video in the page first."))
                }
                return
            }
            if list.count == 1 || list[0].playing { self.play(list[0], in: tab); return }
            let sheet = UIAlertController(title: L("Video"), message: nil, preferredStyle: .actionSheet)
            for v in list.prefix(8) {
                let name = v.src?.lastPathComponent.isEmpty == false ? v.src!.lastPathComponent : (v.src?.host ?? "video")
                let dur = v.duration > 0 ? "  " + PlayerControlsView.format(v.duration) : ""
                sheet.addAction(UIAlertAction(title: name + dur, style: .default) { _ in self.play(v, in: tab) })
            }
            sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            self.presentSheet(sheet, from: self.videoButton.isHidden ? nil : self.videoButton)
        }
    }

    /// Streaming (MSE/blob) videos can't be opened natively; offer the in-page alternatives.
    private func showStreamVideoOptions(tab: Tab) {
        let sheet = UIAlertController(title: L("Streaming Video"), message: L("This site streams the video in pieces, so it can't be opened in the floating player directly."), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L("Picture in Picture"), style: .default) { [weak self] _ in self?.evalInVideoFrames(tab: tab, "window.__faV && __faV.pip()") })
        sheet.addAction(UIAlertAction(title: L("Fullscreen"), style: .default) { [weak self] _ in self?.evalInVideoFrames(tab: tab, "window.__faV && __faV.fullscreen()") })
        if !Prefs.videoCompatMode {
            sheet.addAction(UIAlertAction(title: L("Turn On Video Compatibility Mode"), style: .default) { _ in
                Prefs.videoCompatMode = true
                Toast.show(L("Reloading…"))
            })
        }
        if !tab.isDesktop {
            sheet.addAction(UIAlertAction(title: L("Try Switching to Desktop"), style: .default) { [weak self] _ in self?.toggleDesktop(adjustM: true) })
        }
        sheet.addAction(UIAlertAction(title: L("Live Subtitles"), style: .default) { [weak self] _ in self?.toggleSubtitles(forPlayer: false) })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet, from: videoButton.isHidden ? nil : videoButton)
    }

    private func evalInVideoFrames(tab: Tab, _ js: String) {
        guard let wv = tab.webView else { return }
        let frames = tab.videos.compactMap(\.frame)
        if frames.isEmpty { wv.evaluateJavaScript(js) } else { frames.forEach { wv.evaluateJavaScript(js, in: $0, in: .page) } }
    }

    // MARK: Translation

    func translatePage() {
        guard let tab = currentTab, tab.webView?.url?.isWebURL == true else { return }
        if tab.translateActive {
            let sheet = UIAlertController(title: L("Translate"), message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: L("Show Original"), style: .default) { [weak self] _ in self?.pageTranslator.showOriginal(tab: tab) })
            sheet.addAction(UIAlertAction(title: L("Stop Translating"), style: .destructive) { [weak self] _ in self?.pageTranslator.dismiss(tab: tab) })
            sheet.addAction(UIAlertAction(title: L("Target Language") + ": " + TranslateLanguages.name(Prefs.translateTarget), style: .default) { [weak self] _ in self?.chooseTranslateTarget() })
            sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            presentSheet(sheet)
            return
        }
        pageTranslator.translate(tab: tab, userInitiated: true)
    }

    func chooseTranslateTarget() {
        let sheet = UIAlertController(title: L("Target Language"), message: nil, preferredStyle: .actionSheet)
        for lang in TranslateLanguages.all {
            let mark = TranslateLanguages.normalize(Prefs.translateTarget) == lang.code ? "  ✓" : ""
            sheet.addAction(UIAlertAction(title: lang.name + mark, style: .default) { _ in Prefs.translateTarget = lang.code })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        presentSheet(sheet)
    }

    // MARK: Live subtitles

    func toggleSubtitles(forPlayer: Bool) {
        let ls = LiveSubtitles.shared
        if ls.isOn { ls.stop(); return }
        let host = topMost
        if forPlayer, floatingPlayer.isActive {
            floatingPlayer.setSubtitlesShown(true)
            ls.start(target: .player, overlay: floatingPlayer.subtitleView, item: floatingPlayer.player.currentItem, presenter: host)
        } else {
            pageSubtitles.isHidden = false
            view.setNeedsLayout()
            ls.start(target: .page, overlay: pageSubtitles, item: nil, presenter: host)
        }
    }

    private func subtitlesStateChanged(_ on: Bool) {
        let ls = LiveSubtitles.shared
        floatingPlayer.setSubtitlesShown(on && ls.target == .player)
        pageSubtitles.isHidden = !(on && ls.target == .page)
        if on { Toast.show(L("Live Subtitles") + ": " + SubtitleLanguages.name(Prefs.subtitleSource) + " → " + TranslateLanguages.name(Prefs.translateTarget)) }
    }

    func showSubtitleOptions() {
        let sheet = UIAlertController(title: L("Live Subtitles"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L("Spoken Language") + ": " + SubtitleLanguages.name(Prefs.subtitleSource), style: .default) { [weak self] _ in
            guard let self else { return }
            let s = UIAlertController(title: L("Spoken Language"), message: nil, preferredStyle: .actionSheet)
            for src in SubtitleLanguages.sources {
                s.addAction(UIAlertAction(title: src.name + (Prefs.subtitleSource == src.code ? "  ✓" : ""), style: .default) { _ in
                    Prefs.subtitleSource = src.code
                    LiveSubtitles.shared.restartRecognition()
                })
            }
            s.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            self.topMost.presentSheet(s)
        })
        sheet.addAction(UIAlertAction(title: L("Display") + ": " + LiveSubtitles.shared.mode.title, style: .default) { [weak self] _ in
            guard let self else { return }
            let s = UIAlertController(title: L("Display"), message: nil, preferredStyle: .actionSheet)
            for m in SubtitleMode.allCases {
                s.addAction(UIAlertAction(title: m.title + (Prefs.subtitleModeRaw == m.rawValue ? "  ✓" : ""), style: .default) { _ in Prefs.subtitleModeRaw = m.rawValue })
            }
            s.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
            self.topMost.presentSheet(s)
        })
        sheet.addAction(UIAlertAction(title: L("Target Language") + ": " + TranslateLanguages.name(Prefs.translateTarget), style: .default) { [weak self] _ in self?.chooseTranslateTarget() })
        sheet.addAction(UIAlertAction(title: L("Turn Off Live Subtitles"), style: .destructive) { _ in LiveSubtitles.shared.stop() })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        topMost.presentSheet(sheet)
    }
}
