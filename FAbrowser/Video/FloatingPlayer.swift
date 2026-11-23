import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import WebKit

struct VideoSource {
    var url: URL
    var title: String
    var pageURL: URL?
    var startTime: Double = 0
    var isPrivate = false
}

/// Remembers where each video was left so "Resume Playback" can continue it.
enum ResumeStore {
    private static let key = "videoResumePositions"

    private static func id(_ url: URL) -> String { (url.host ?? "") + url.path }

    static func position(for url: URL) -> Double? {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        return d[id(url)]?.first
    }

    static func save(_ time: Double, duration: Double, for url: URL) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        let k = id(url)
        if time < 10 || (duration > 0 && duration - time < 15) { d[k] = nil } else { d[k] = [time, Date().timeIntervalSince1970] }
        if d.count > 300 {
            let old = d.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(d.count - 300).map(\.key)
            old.forEach { d[$0] = nil }
        }
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Native floating video player modelled on Alook's "Video Floating":
/// a window pinned at the top (swipe up to close, swipe sideways to seek, pull down to shrink),
/// a small draggable window in the lower right (swipe right to close, double tap to go back),
/// and a landscape fullscreen with brightness/volume gestures, lock, time and battery.
final class FloatingPlayerController: NSObject {
    enum Mode { case hidden, top, mini, fullscreen }

    weak var browser: BrowserViewController?
    private(set) var mode: Mode = .hidden
    private(set) var source: VideoSource?
    /// Frame the source video came from, so the page copy can be paused/resumed.
    var originFrame: WKFrameInfo?
    weak var originTab: Tab?

    var onClosed: ((Double) -> Void)?
    var onPlayInPage: ((Double) -> Void)?
    var onModeChanged: ((Mode) -> Void)?

    let player = AVPlayer()
    private let container = UIView()
    let contentView = UIView()
    private let playerView = PlayerLayerView()
    let subtitleView = SubtitleOverlayView()
    private let controls = PlayerControlsView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var pip: AVPictureInPictureController?
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var rateObserver: NSKeyValueObservation?
    private var miniCenter: CGPoint?
    private var fullscreenVC: FullscreenPlayerViewController?
    private var boosting = false
    private var zoom: CGFloat = 1
    private var panMode = 0 // 0 none, 1 seek, 2 vertical, 3 drag, 4 brightness, 5 volume
    private var panStartTime: Double = 0
    private var panStartValue: Float = 0
    private var pipWillStart = false
    private lazy var volumeSlider: UISlider? = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        contentView.addSubview(v)
        return v.subviews.compactMap { $0 as? UISlider }.first
    }()

    var isActive: Bool { mode != .hidden }
    /// Height the browser keeps free above the web page while the player is pinned at the top.
    var reservedTopHeight: CGFloat { mode == .top ? targetFrame(for: .top).height : 0 }
    var currentTime: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double { player.currentItem?.duration.seconds.isFinite == true ? player.currentItem!.duration.seconds : 0 }
    var isPlaying: Bool { player.timeControlStatus != .paused }
    var rate: Float { Float(Prefs.playbackRate) }

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init()
        setupViews()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(prefsChanged(_:)), name: .prefsChanged, object: nil)
        nc.addObserver(self, selector: #selector(itemEnded), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    // MARK: Setup

    private func setupViews() {
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.3
        container.layer.shadowRadius = 10
        container.layer.shadowOffset = CGSize(width: 0, height: 3)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = Self.gravities[Prefs.videoGravity % 3]
        player.allowsExternalPlayback = true

        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 14, weight: .medium)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        spinner.color = .white
        spinner.hidesWhenStopped = true

        container.addSubview(contentView)
        [playerView, subtitleView, spinner, errorLabel, controls].forEach { contentView.addSubview($0) }
        subtitleView.isHidden = true

        controls.onClose = { [weak self] in self?.close() }
        controls.onPlayPause = { [weak self] in self?.togglePlay() }
        controls.onShrink = { [weak self] in self?.setMode(.mini) }
        controls.onExpand = { [weak self] in self?.setMode(.top) }
        controls.onFullscreen = { [weak self] in
            guard let self else { return }
            self.setMode(self.mode == .fullscreen ? .top : .fullscreen)
        }
        controls.onPiP = { [weak self] in self?.togglePiP() }
        controls.onSubtitles = { [weak self] in self?.browser?.toggleSubtitles(forPlayer: true) }
        controls.onSpeed = { [weak self] in self?.chooseSpeed() }
        controls.onMore = { [weak self] in self?.showMore() }
        controls.onSeek = { [weak self] t in self?.seek(to: t) }
        controls.onLockChanged = { [weak self] locked in self?.setGesturesLocked(locked) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(cycleGravity))
        twoFinger.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.4
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        [tap, doubleTap, twoFinger, pan, long, pinch].forEach { g in
            g.delegate = self
            contentView.addGestureRecognizer(g)
        }
    }

    private static let gravities: [AVLayerVideoGravity] = [.resizeAspect, .resizeAspectFill, .resize]

    // MARK: Playback

    func play(_ source: VideoSource, in browser: BrowserViewController) {
        self.source = source
        errorLabel.isHidden = true
        spinner.startAnimating()
        controls.titleLabel.text = source.title
        zoom = 1
        playerView.transform = .identity
        let headers: [String: String] = {
            var h = ["User-Agent": UserAgent.mobile]
            if let p = source.pageURL { h["Referer"] = p.absoluteString }
            return h
        }()
        let store: WKWebsiteDataStore = source.isPrivate ? (originTab?.webView?.configuration.websiteDataStore ?? .default()) : .default()
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let host = source.url.host?.lowercased() ?? ""
            let matching = cookies.filter { c in
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == d || host.hasSuffix("." + d)
            }
            let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers, AVURLAssetHTTPCookiesKey: matching])
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            self.observe(item)
            self.player.replaceCurrentItem(with: item)
            var start = source.startTime
            if start < 1, Prefs.resumePlayback, let saved = ResumeStore.position(for: source.url) {
                start = saved
                Toast.show(L("Resume Playback") + " " + PlayerControlsView.format(saved))
            }
            if start > 1 { self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) }
            self.player.defaultRate = self.rate
            self.player.playImmediately(atRate: self.rate)
            self.configureAudioSession()
            self.updateNowPlaying()
            LiveSubtitles.shared.playerItemChanged(item, url: source.url)
        }
        if mode == .hidden { install(in: browser); setMode(.top) }
        setupPiP()
        setupRemoteCommands()
        controls.update(rate: rate)
        controls.setVisible(true)
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if item.status == .failed {
                        self.spinner.stopAnimating()
                        self.errorLabel.text = L("Video failed to play.") + "\n" + (item.error?.localizedDescription ?? "")
                        self.errorLabel.isHidden = false
                    } else if item.status == .readyToPlay {
                        self.updateNowPlaying()
                    }
                }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { if item.isPlaybackBufferEmpty { self?.spinner.startAnimating() } }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { if item.isPlaybackLikelyToKeepUp { self?.spinner.stopAnimating() } }
            },
        ]
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controls.update(playing: p.timeControlStatus != .paused)
                if p.timeControlStatus == .playing { self.spinner.stopAnimating() }
                self.updateNowPlaying()
                self.browser?.videoStateChanged()
            }
        }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            guard let self else { return }
            self.controls.update(time: self.currentTime, duration: self.duration)
            if let url = self.source?.url, Int(self.currentTime) % 5 == 0 { ResumeStore.save(self.currentTime, duration: self.duration, for: url) }
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if duration > 0, currentTime >= duration - 0.5 { player.seek(to: .zero) }
            player.playImmediately(atRate: boosting ? Float(Prefs.longPressSpeed) : rate)
        }
    }

    func seek(to t: Double) {
        let target = max(0, duration > 0 ? min(t, duration - 0.5) : t)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        controls.update(time: target, duration: duration)
    }

    func setRate(_ r: Double) {
        Prefs.playbackRate = r
        player.defaultRate = Float(r)
        if isPlaying, !boosting { player.rate = Float(r) }
        controls.update(rate: Float(r))
    }

    @objc private func itemEnded(_ n: Notification) {
        guard (n.object as? AVPlayerItem) === player.currentItem, let url = source?.url else { return }
        ResumeStore.save(0, duration: duration, for: url)
        controls.setVisible(true)
    }

    func close() {
        guard mode != .hidden else { return }
        let t = currentTime
        if let url = source?.url { ResumeStore.save(t, duration: duration, for: url) }
        if mode == .fullscreen { exitFullscreen(animated: false) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        pip?.delegate = nil
        pip = nil
        LiveSubtitles.shared.playerClosed()
        UIView.animate(withDuration: 0.2, animations: { self.container.alpha = 0 }) { _ in
            self.container.removeFromSuperview()
            self.container.alpha = 1
        }
        mode = .hidden
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onModeChanged?(.hidden)
        onClosed?(t)
        (UIApplication.shared.delegate as? AppDelegate)?.configureAudioSession()
        browser?.videoStateChanged()
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Modes & layout

    private func install(in browser: BrowserViewController) {
        container.removeFromSuperview()
        browser.view.insertSubview(container, belowSubview: browser.toolbar)
        container.frame = targetFrame(for: .top).offsetBy(dx: 0, dy: -40)
        container.alpha = 0
        UIView.animate(withDuration: 0.25) { self.container.alpha = 1 }
    }

    func setMode(_ m: Mode) {
        guard let browser else { return }
        let old = mode
        if old == .fullscreen && m != .fullscreen { exitFullscreen(animated: true) }
        mode = m
        if m == .fullscreen { enterFullscreen(); onModeChanged?(m); return }
        if container.superview == nil { browser.view.insertSubview(container, belowSubview: browser.toolbar) }
        if contentView.superview !== container { container.addSubview(contentView) }
        controls.apply(style: m == .mini ? .mini : .top)
        controls.setVisible(m != .mini || old != .mini)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.3) {
            self.layout()
        }
        onModeChanged?(m)
    }

    /// Called from the browser's viewDidLayoutSubviews.
    func layout() {
        guard mode == .top || mode == .mini else { return }
        container.frame = targetFrame(for: mode)
        contentView.frame = container.bounds
        contentView.layer.cornerRadius = mode == .mini ? 10 : 0
        container.layer.shadowPath = UIBezierPath(roundedRect: container.bounds, cornerRadius: contentView.layer.cornerRadius).cgPath
        layoutContent()
    }

    private func layoutContent() {
        let b = contentView.bounds
        playerView.bounds = b
        playerView.center = CGPoint(x: b.midX, y: b.midY)
        controls.frame = b
        spinner.center = CGPoint(x: b.midX, y: b.midY)
        errorLabel.frame = b.insetBy(dx: 16, dy: 40)
        subtitleView.layoutIn(bounds: b, bottomInset: mode == .fullscreen ? 56 : (mode == .mini ? 6 : 40), compact: mode == .mini)
    }

    private func targetFrame(for m: Mode) -> CGRect {
        guard let browser else { return .zero }
        let v = browser.view!
        let safe = v.safeAreaInsets
        let width = v.bounds.width - safe.left - safe.right
        switch m {
        case .mini:
            let w = min(max(v.bounds.width * 0.48, 180), 300)
            let h = w * 9 / 16
            let defaultCenter = CGPoint(x: v.bounds.width - safe.right - w / 2 - 12, y: browser.toolbar.frame.minY - h / 2 - 12)
            var c = miniCenter ?? defaultCenter
            c.x = min(max(c.x, w / 2 + 8), v.bounds.width - w / 2 - 8)
            c.y = min(max(c.y, safe.top + h / 2 + 8), browser.toolbar.frame.minY - h / 2 - 8)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        default:
            let h = min(width * 9 / 16, v.bounds.height * 0.42)
            return CGRect(x: safe.left, y: browser.contentTop, width: width, height: h)
        }
    }

    private func enterFullscreen() {
        guard let browser else { return }
        let vc = FullscreenPlayerViewController()
        vc.landscape = isLandscapeVideo
        vc.modalPresentationStyle = .fullScreen
        vc.modalTransitionStyle = .crossDissolve
        fullscreenVC = vc
        container.isHidden = true
        vc.loadViewIfNeeded()
        vc.view.addSubview(contentView)
        contentView.frame = vc.view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.layer.cornerRadius = 0
        controls.apply(style: .fullscreen)
        vc.onLayout = { [weak self] in self?.layoutContent() }
        browser.topMost.present(vc, animated: true) { vc.rotate() }
        layoutContent()
        controls.setVisible(true)
    }

    private func exitFullscreen(animated: Bool) {
        guard let vc = fullscreenVC else { return }
        fullscreenVC = nil
        contentView.autoresizingMask = []
        container.addSubview(contentView)
        container.isHidden = false
        vc.restorePortrait()
        vc.dismiss(animated: animated)
    }

    private var isLandscapeVideo: Bool {
        guard let size = player.currentItem?.presentationSize, size.width > 0 else { return true }
        return size.width >= size.height
    }

    // MARK: Gestures

    private func setGesturesLocked(_ locked: Bool) {
        contentView.gestureRecognizers?.forEach { g in
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 1, t.numberOfTouchesRequired == 1 { return }
            g.isEnabled = !locked
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) { controls.toggleVisible() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if mode == .mini { setMode(.top); return }
        let x = g.location(in: contentView).x
        let w = contentView.bounds.width
        if x < w * 0.25 {
            seek(to: currentTime - 5)
            controls.showBadge("⏪ 5s")
        } else if x > w * 0.75 {
            seek(to: currentTime + 5)
            controls.showBadge("5s ⏩")
        } else {
            togglePlay()
        }
    }

    @objc private func cycleGravity() {
        Prefs.videoGravity = (Prefs.videoGravity + 1) % 3
        playerView.playerLayer.videoGravity = Self.gravities[Prefs.videoGravity]
        controls.showBadge(L("Video Gravity:") + " " + [L("Fit"), L("Fill"), L("Stretch")][Prefs.videoGravity])
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard mode != .mini else { return }
        if g.state == .changed {
            zoom = min(max(zoom * g.scale, 1), 3)
            g.scale = 1
            playerView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        } else if g.state == .ended {
            controls.showBadge(L("Video Size:") + " \(Int(zoom * 100))%")
        }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard isPlaying else { return }
            boosting = true
            player.rate = Float(Prefs.longPressSpeed)
            controls.showBadge(String(format: "%gx ▶▶", Prefs.longPressSpeed), autoHide: false)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .ended, .cancelled, .failed:
            guard boosting else { return }
            boosting = false
            if isPlaying { player.rate = rate }
            controls.showBadge(nil)
        default: break
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let browser else { return }
        let t = g.translation(in: browser.view)
        let vel = g.velocity(in: browser.view)
        switch g.state {
        case .began:
            if mode == .mini { panMode = 3; return }
            if abs(vel.x) > abs(vel.y) {
                panMode = duration > 0 ? 1 : 0
                panStartTime = currentTime
            } else if mode == .fullscreen {
                let left = g.location(in: contentView).x < contentView.bounds.width / 2
                panMode = left ? 4 : 5
                panStartValue = left ? Float(UIScreen.main.brightness) : (volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            } else {
                panMode = 2
            }
        case .changed:
            switch panMode {
            case 1:
                let span = min(duration, 600.0)
                let target = max(0, min(duration, panStartTime + Double(t.x / contentView.bounds.width) * span))
                let delta = Int(target - panStartTime)
                controls.showBadge("\(delta >= 0 ? "+" : "")\(delta)s   \(PlayerControlsView.format(target)) / \(PlayerControlsView.format(duration))", autoHide: false)
            case 2:
                container.transform = CGAffineTransform(translationX: 0, y: t.y < 0 ? t.y : t.y * 0.5)
                container.alpha = t.y < 0 ? max(0.3, 1 + t.y / 200) : 1
            case 3:
                container.center = CGPoint(x: container.center.x + t.x, y: container.center.y + t.y)
                g.setTranslation(.zero, in: browser.view)
            case 4:
                let v = min(max(panStartValue - Float(t.y / contentView.bounds.height), 0), 1)
                UIScreen.main.brightness = CGFloat(v)
                controls.showBadge("☀︎ \(Int(v * 100))%", autoHide: false)
            case 5:
                let v = min(max(panStartValue - Float(t.y / contentView.bounds.height), 0), 1)
                volumeSlider?.value = v
                controls.showBadge("🔊 \(Int(v * 100))%", autoHide: false)
            default: break
            }
        case .ended, .cancelled:
            switch panMode {
            case 1:
                let span = min(duration, 600.0)
                seek(to: panStartTime + Double(t.x / contentView.bounds.width) * span)
                controls.showBadge(nil)
            case 2:
                if t.y < -60 || vel.y < -700 {
                    UIView.animate(withDuration: 0.18, animations: {
                        self.container.transform = CGAffineTransform(translationX: 0, y: -self.container.frame.maxY)
                        self.container.alpha = 0
                    }) { _ in
                        self.container.transform = .identity
                        self.close()
                    }
                } else if t.y > 70 || vel.y > 700 {
                    container.transform = .identity
                    container.alpha = 1
                    setMode(.mini)
                } else {
                    UIView.animate(withDuration: 0.2) { self.container.transform = .identity; self.container.alpha = 1 }
                }
            case 3:
                let w = browser.view.bounds.width
                if vel.x > 900 || container.frame.minX > w - container.frame.width * 0.35 {
                    UIView.animate(withDuration: 0.18, animations: { self.container.center.x = w + self.container.frame.width }) { _ in self.close() }
                } else {
                    miniCenter = container.center
                    UIView.animate(withDuration: 0.2) { self.layout() }
                }
            case 4, 5:
                controls.showBadge(nil)
            default: break
            }
            panMode = 0
        default: break
        }
    }

    // MARK: Menus

    private func chooseSpeed() {
        guard let host = browser?.topMost else { return }
        let sheet = UIAlertController(title: L("Playback Rate"), message: nil, preferredStyle: .actionSheet)
        for r in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0] {
            let title = (r == 1 ? L("Normal") : String(format: "%gx", r)) + (abs(r - Prefs.playbackRate) < 0.01 ? "  ✓" : "")
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.setRate(r) })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        host.presentSheet(sheet, from: controls.speedButton)
    }

    private func showMore() {
        guard let host = browser?.topMost, let source else { return }
        let sheet = UIAlertController(title: source.title.isEmpty ? nil : source.title, message: source.url.absoluteString, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L("Play in Webpage"), style: .default) { [weak self] _ in
            guard let self else { return }
            let t = self.currentTime
            self.onPlayInPage?(t)
            self.close()
        })
        sheet.addAction(UIAlertAction(title: L("Live Subtitles"), style: .default) { [weak self] _ in self?.browser?.toggleSubtitles(forPlayer: true) })
        sheet.addAction(UIAlertAction(title: L("Video Gravity:") + " " + [L("Fit"), L("Fill"), L("Stretch")][Prefs.videoGravity % 3], style: .default) { [weak self] _ in self?.cycleGravity() })
        sheet.addAction(UIAlertAction(title: L("Copy Link"), style: .default) { _ in
            UIPasteboard.general.url = source.url
            Toast.show(L("Copied"))
        })
        if source.url.pathExtension.lowercased() != "m3u8" {
            sheet.addAction(UIAlertAction(title: L("Download File"), style: .default) { _ in
                DownloadManager.shared.download(url: source.url)
                Toast.show(L("Downloading"))
            })
        }
        sheet.addAction(UIAlertAction(title: L("Share"), style: .default) { [weak host] _ in host?.share([source.url]) })
        sheet.addAction(UIAlertAction(title: L("Close Video"), style: .destructive) { [weak self] _ in self?.close() })
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        host.presentSheet(sheet, from: contentView)
    }

    // MARK: Picture in Picture

    private func setupPiP() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else {
            controls.setPiPAvailable(AVPictureInPictureController.isPictureInPictureSupported())
            return
        }
        pip = AVPictureInPictureController(playerLayer: playerView.playerLayer)
        pip?.delegate = self
        pip?.canStartPictureInPictureAutomaticallyFromInline = Prefs.autoPiP
        controls.setPiPAvailable(true)
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // MARK: Background

    @objc private func didEnterBackground() {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, UIApplication.shared.applicationState == .background else { return }
            if self.pip?.isPictureInPictureActive == true || self.pipWillStart { return }
            if Prefs.backgroundPlay {
                self.playerView.playerLayer.player = nil
            } else {
                self.player.pause()
            }
        }
    }

    @objc private func willEnterForeground() {
        playerView.playerLayer.player = player
    }

    @objc private func prefsChanged(_ n: Notification) {
        guard let key = n.object as? String else { return }
        if key == "autoPiP" { pip?.canStartPictureInPictureAutomaticallyFromInline = Prefs.autoPiP }
        if key == "subtitleFontSize" || key == "subtitleMode" { subtitleView.refreshStyle() }
    }

    // MARK: Now playing

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.skipForwardCommand.removeTarget(nil)
        c.skipBackwardCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.playCommand.addTarget { [weak self] _ in self?.player.playImmediately(atRate: self?.rate ?? 1); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in guard let self else { return .commandFailed }; self.seek(to: self.currentTime + 15); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in guard let self else { return .commandFailed }; self.seek(to: self.currentTime - 15); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let source else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: source.title.isEmpty ? (source.pageURL?.host ?? "Video") : source.title,
            MPMediaItemPropertyArtist: source.pageURL?.host ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.rate) : 0,
        ]
    }

    func setSubtitlesShown(_ on: Bool) {
        subtitleView.isHidden = !on
        controls.setSubtitlesOn(on)
        layoutContent()
    }
}

extension FloatingPlayerController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl) && !(touch.view?.superview is UIControl)
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIPinchGestureRecognizer { return mode != .mini }
        return true
    }
}

extension FloatingPlayerController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        pipWillStart = true
        if mode == .top || mode == .mini { UIView.animate(withDuration: 0.2) { self.container.alpha = 0 } }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { pipWillStart = false }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipWillStart = false
        container.alpha = 1
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        pipWillStart = false
        UIView.animate(withDuration: 0.2) { self.container.alpha = 1 }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        container.alpha = 1
        completion(true)
    }
}

/// Landscape host for the floating player's content view.
final class FullscreenPlayerViewController: UIViewController {
    var landscape = true
    var onLayout: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscape ? .landscape : .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { landscape ? .landscapeRight : .portrait }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }

    func rotate() {
        guard landscape, let scene = view.window?.windowScene else { return }
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
    }

    func restorePortrait() {
        guard landscape, let scene = view.window?.windowScene else { return }
        landscape = false
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }
}
