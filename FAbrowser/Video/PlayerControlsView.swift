import UIKit
import AVKit

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Overlay controls for the floating player. Layout adapts to the floating mode.
final class PlayerControlsView: UIView {
    enum Style { case top, mini, fullscreen }

    var onClose: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onShrink: (() -> Void)?
    var onExpand: (() -> Void)?
    var onFullscreen: (() -> Void)?
    var onPiP: (() -> Void)?
    var onSubtitles: (() -> Void)?
    var onSpeed: (() -> Void)?
    var onMore: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onScrubbing: ((Bool) -> Void)?
    var onLockChanged: ((Bool) -> Void)?

    private(set) var style: Style = .top
    private(set) var locked = false
    private var hideWork: DispatchWorkItem?
    private(set) var visible = true

    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()
    private let topBar = UIStackView()
    private let bottomBar = UIStackView()
    let titleLabel = UILabel()
    private let closeButton = PlayerControlsView.button("xmark")
    private let shrinkButton = PlayerControlsView.button("chevron.down")
    private let expandButton = PlayerControlsView.button("arrow.up.left.and.arrow.down.right", size: 13)
    let subtitleButton = PlayerControlsView.button("captions.bubble")
    private let pipButton = PlayerControlsView.button("pip.enter")
    private let moreButton = PlayerControlsView.button("ellipsis")
    private let routePicker = AVRoutePickerView()
    let playButton = PlayerControlsView.button("play.fill", size: 30)
    private let currentLabel = PlayerControlsView.timeLabel()
    private let durationLabel = PlayerControlsView.timeLabel()
    let slider = UISlider()
    let speedButton = UIButton(type: .system)
    private let fullscreenButton = PlayerControlsView.button("arrow.up.left.and.arrow.down.right", size: 15)
    private let lockButton = PlayerControlsView.button("lock.open", size: 17)
    private let clockLabel = UILabel()
    private var clockTimer: Timer?
    let centerBadge = PaddingLabel()

    private var scrubbing = false
    private var duration: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        topGradient.colors = [UIColor.black.withAlphaComponent(0.65).cgColor, UIColor.clear.cgColor]
        bottomGradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        layer.addSublayer(topGradient)
        layer.addSublayer(bottomGradient)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        routePicker.tintColor = .white
        routePicker.activeTintColor = Theme.accent
        routePicker.prioritizesVideoDevices = true
        routePicker.widthAnchor.constraint(equalToConstant: 36).isActive = true

        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 2
        [closeButton, shrinkButton, titleLabel, subtitleButton, pipButton, routePicker, moreButton].forEach { topBar.addArrangedSubview($0) }

        slider.minimumTrackTintColor = Theme.accent
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        slider.setThumbImage(PlayerControlsView.thumb(), for: .normal)
        slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        speedButton.setTitleColor(.white, for: .normal)
        speedButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        speedButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        bottomBar.axis = .horizontal
        bottomBar.alignment = .center
        bottomBar.spacing = 8
        [currentLabel, slider, durationLabel, speedButton, fullscreenButton].forEach { bottomBar.addArrangedSubview($0) }

        clockLabel.textColor = .white
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        centerBadge.textColor = .white
        centerBadge.font = .systemFont(ofSize: 15, weight: .semibold)
        centerBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        centerBadge.layer.cornerRadius = 8
        centerBadge.clipsToBounds = true
        centerBadge.alpha = 0
        centerBadge.isUserInteractionEnabled = false

        [topBar, bottomBar, playButton, expandButton, lockButton, clockLabel, centerBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 2),
            topBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            topBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            topBar.heightAnchor.constraint(equalToConstant: 40),
            bottomBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            bottomBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -2),
            bottomBar.heightAnchor.constraint(equalToConstant: 38),
            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 60),
            playButton.heightAnchor.constraint(equalToConstant: 60),
            expandButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            expandButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            lockButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 14),
            lockButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clockLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            clockLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 0),
            centerBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerBadge.topAnchor.constraint(equalTo: topAnchor, constant: 46),
        ])

        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        shrinkButton.addAction(UIAction { [weak self] _ in self?.onShrink?() }, for: .touchUpInside)
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
        subtitleButton.addAction(UIAction { [weak self] _ in self?.onSubtitles?(); self?.scheduleHide() }, for: .touchUpInside)
        pipButton.addAction(UIAction { [weak self] _ in self?.onPiP?() }, for: .touchUpInside)
        moreButton.addAction(UIAction { [weak self] _ in self?.onMore?() }, for: .touchUpInside)
        playButton.addAction(UIAction { [weak self] _ in self?.onPlayPause?(); self?.scheduleHide() }, for: .touchUpInside)
        speedButton.addAction(UIAction { [weak self] _ in self?.onSpeed?() }, for: .touchUpInside)
        fullscreenButton.addAction(UIAction { [weak self] _ in self?.onFullscreen?() }, for: .touchUpInside)
        lockButton.addAction(UIAction { [weak self] _ in self?.toggleLock() }, for: .touchUpInside)
        apply(style: .top)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = min(90, bounds.height * 0.4)
        topGradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h + safeAreaInsets.top)
        bottomGradient.frame = CGRect(x: 0, y: bounds.height - h - safeAreaInsets.bottom, width: bounds.width, height: h + safeAreaInsets.bottom)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    func apply(style: Style) {
        self.style = style
        let mini = style == .mini
        let full = style == .fullscreen
        topBar.isHidden = mini || locked
        bottomBar.isHidden = mini || locked
        topGradient.isHidden = mini
        bottomGradient.isHidden = mini
        expandButton.isHidden = !mini
        closeButton.isHidden = false
        shrinkButton.isHidden = full
        lockButton.isHidden = !full
        clockLabel.isHidden = !(full && Prefs.showTimeBattery)
        titleLabel.font = .systemFont(ofSize: full ? 16 : 14, weight: .semibold)
        fullscreenButton.setImage(Theme.symbol(full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 15, weight: .semibold), for: .normal)
        playButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: mini ? 22 : 30, weight: .semibold), forImageIn: .normal)
        if mini {
            closeButton.removeFromSuperview()
            addSubview(closeButton)
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                                         closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)])
        } else if closeButton.superview !== topBar {
            closeButton.removeFromSuperview()
            closeButton.translatesAutoresizingMaskIntoConstraints = true
            topBar.insertArrangedSubview(closeButton, at: 0)
        }
        clockTimer?.invalidate()
        if full && Prefs.showTimeBattery {
            UIDevice.current.isBatteryMonitoringEnabled = true
            updateClock()
            clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.updateClock() }
        }
        setNeedsLayout()
    }

    private func updateClock() {
        let df = DateFormatter()
        df.timeStyle = .short
        let level = UIDevice.current.batteryLevel
        clockLabel.text = df.string(from: Date()) + (level >= 0 ? "   \(Int(level * 100))%" : "")
    }

    func setPiPAvailable(_ ok: Bool) { pipButton.isHidden = !ok }

    func update(playing: Bool) {
        playButton.setImage(Theme.symbol(playing ? "pause.fill" : "play.fill", size: style == .mini ? 22 : 30, weight: .semibold), for: .normal)
    }

    func update(time: Double, duration: Double) {
        self.duration = duration
        guard !scrubbing else { return }
        currentLabel.text = Self.format(time)
        durationLabel.text = duration > 0 ? Self.format(duration) : "LIVE"
        slider.isEnabled = duration > 0
        slider.value = duration > 0 ? Float(time / duration) : 0
    }

    func update(rate: Float) {
        speedButton.setTitle(rate == 1 ? "1.0x" : String(format: "%gx", rate), for: .normal)
    }

    func setSubtitlesOn(_ on: Bool) {
        subtitleButton.setImage(Theme.symbol(on ? "captions.bubble.fill" : "captions.bubble", size: 17, weight: .semibold), for: .normal)
        subtitleButton.tintColor = on ? Theme.accent : .white
    }

    func showBadge(_ text: String?, autoHide: Bool = true) {
        centerBadge.text = text
        UIView.animate(withDuration: 0.15) { self.centerBadge.alpha = text == nil ? 0 : 1 }
        if autoHide, text != nil {
            let current = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                if self?.centerBadge.text == current { self?.showBadge(nil) }
            }
        }
    }

    // MARK: Visibility

    func setVisible(_ show: Bool, animated: Bool = true) {
        visible = show
        hideWork?.cancel()
        let targets: [UIView] = locked ? [lockButton] : subviews.filter { $0 !== centerBadge }
        let changes = {
            targets.forEach { $0.alpha = show ? 1 : 0 }
            self.topGradient.opacity = show && !self.locked ? 1 : 0
            self.bottomGradient.opacity = show && !self.locked ? 1 : 0
        }
        if animated { UIView.animate(withDuration: 0.2, animations: changes) } else { changes() }
        if show { scheduleHide() }
    }

    func toggleVisible() { setVisible(!visible) }

    func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.scrubbing else { return }
            self.setVisible(false)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }

    /// The lock button only exists in fullscreen, so a lock must not outlive it.
    func unlock() { if locked { toggleLock() } }

    private func toggleLock() {
        locked.toggle()
        lockButton.setImage(Theme.symbol(locked ? "lock.fill" : "lock.open", size: 17, weight: .semibold), for: .normal)
        topBar.isHidden = locked
        bottomBar.isHidden = locked
        playButton.isHidden = locked
        onLockChanged?(locked)
        setVisible(true)
    }

    // MARK: Slider

    @objc private func sliderBegan() { scrubbing = true; onScrubbing?(true); hideWork?.cancel() }
    @objc private func sliderChanged() {
        let t = Double(slider.value) * duration
        currentLabel.text = Self.format(t)
        showBadge("\(Self.format(t)) / \(Self.format(duration))", autoHide: false)
    }
    @objc private func sliderEnded() {
        scrubbing = false
        onScrubbing?(false)
        onSeek?(Double(slider.value) * duration)
        showBadge(nil)
        scheduleHide()
    }

    // MARK: Helpers

    static func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func button(_ symbol: String, size: CGFloat = 17) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(Theme.symbol(symbol, size: size, weight: .semibold), for: .normal)
        b.tintColor = .white
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.35
        b.layer.shadowRadius = 2
        b.layer.shadowOffset = .zero
        return b
    }

    private static func timeLabel() -> UILabel {
        let l = UILabel()
        l.textColor = .white
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.text = "00:00"
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private static func thumb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 12, height: 12)).fill()
        }
    }
}

/// Round button shown above the toolbar when the page has a video (Alook's lower-right video button).
final class VideoFloatButton: UIButton {
    var active = false { didSet { refresh() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.cardBackground
        layer.cornerRadius = 22
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityLabel = L("Video Floating")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        setImage(Theme.symbol(active ? "pip.fill" : "play.rectangle.fill", size: 19, weight: .semibold), for: .normal)
        tintColor = active ? .white : Theme.accent
        backgroundColor = active ? Theme.accent : Theme.cardBackground
    }
}
