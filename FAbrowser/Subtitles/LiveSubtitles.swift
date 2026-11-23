import UIKit
import Speech
import ReplayKit
import AVFoundation
import MediaToolbox

enum SubtitleMode: Int, CaseIterable {
    case translation, bilingual, original
    var title: String { [L("Translation Only"), L("Bilingual"), L("Original Only")][rawValue] }
}

enum SubtitleLanguages {
    /// Speech recognizer locales offered for the spoken language.
    static let sources: [(code: String, name: String)] = [
        ("auto", L("Auto Detect (EN/JA/ZH)")), ("en-US", "English"), ("ja-JP", "日本語"), ("zh-CN", "中文 (普通话)"),
        ("zh-TW", "中文 (台灣)"), ("yue-CN", "粵語"), ("ko-KR", "한국어"), ("vi-VN", "Tiếng Việt"), ("th-TH", "ไทย"),
        ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("es-ES", "Español"), ("ru-RU", "Русский"), ("id-ID", "Bahasa Indonesia"),
    ]
    static let autoCandidates = ["en-US", "ja-JP", "zh-CN"]

    static func name(_ code: String) -> String { sources.first { $0.code == code }?.name ?? code }

    /// Recognizer locale → translation language.
    static func translationCode(_ locale: String) -> String {
        switch locale {
        case "zh-CN": return "zh-Hans"
        case "zh-TW", "yue-CN": return "zh-Hant"
        default: return TranslateLanguages.normalize(locale)
        }
    }

    static func isCJK(_ locale: String) -> Bool { ["ja", "zh", "yu", "ko"].contains(String(locale.prefix(2))) }
}

/// Speech-to-text + offline translation for whatever audio FAbrowser is playing.
/// Audio comes from an MTAudioProcessingTap on the native player (progressive files) or,
/// for HLS and in-page video, from ReplayKit's app-audio capture.
final class LiveSubtitles: NSObject {
    static let shared = LiveSubtitles()

    enum Target { case player, page }

    private(set) var isOn = false
    private(set) var target: Target = .player
    var onStateChange: ((Bool) -> Void)?
    weak var overlay: SubtitleOverlayView?

    private var channels: [RecognitionChannel] = []
    private(set) var resolvedLocale: String?
    private var detectStart = Date()
    private var tap: PlayerAudioTap?
    private weak var playerItem: AVPlayerItem?
    private var usingReplayKit = false
    private var tick: Timer?
    private var lastPartialTranslate = Date.distantPast
    private var translateGeneration = 0
    private var lastUpdate = Date()

    var mode: SubtitleMode { SubtitleMode(rawValue: Prefs.subtitleModeRaw) ?? .translation }

    // MARK: Public control

    func start(target: Target, overlay: SubtitleOverlayView, item: AVPlayerItem?, presenter: UIViewController) {
        stop()
        self.target = target
        self.overlay = overlay
        requestPermission(presenter: presenter) { [weak self] ok in
            guard let self, ok else { return }
            self.isOn = true
            self.onStateChange?(true)
            overlay.showStatus(L("Listening…"))
            self.startRecognition()
            if target == .player, let item { self.attachAudio(to: item) } else { self.startReplayKit() }
            self.tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
        }
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        channels.forEach { $0.stop() }
        channels = []
        detachTap()
        if usingReplayKit {
            RPScreenRecorder.shared().stopCapture { _ in }
            usingReplayKit = false
        }
        overlay?.clear()
        let was = isOn
        isOn = false
        resolvedLocale = nil
        if was { onStateChange?(false) }
    }

    /// Restart recognition after the user changes the spoken language.
    func restartRecognition() {
        guard isOn else { return }
        channels.forEach { $0.stop() }
        channels = []
        resolvedLocale = nil
        overlay?.showStatus(L("Listening…"))
        startRecognition()
    }

    func playerItemChanged(_ item: AVPlayerItem, url: URL) {
        guard isOn, target == .player else { return }
        detachTap()
        if usingReplayKit { return }
        attachAudio(to: item)
    }

    func playerClosed() {
        if target == .player { stop() }
    }

    // MARK: Permission

    private func requestPermission(presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized { completion(true); return }
                let a = UIAlertController(title: L("Live Subtitles"), message: L("Please allow Speech Recognition for FAbrowser in Settings."), preferredStyle: .alert)
                a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
                a.addAction(UIAlertAction(title: L("Settings"), style: .default) { _ in
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                })
                presenter.present(a, animated: true)
                completion(false)
            }
        }
    }

    // MARK: Audio sources

    private func attachAudio(to item: AVPlayerItem) {
        playerItem = item
        Task { @MainActor in
            let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            guard self.isOn, self.playerItem === item else { return }
            if let track = tracks.first, let tap = PlayerAudioTap(track: track) {
                tap.onBuffer = { [weak self] buf in self?.channels.forEach { $0.append(buf) } }
                item.audioMix = tap.audioMix
                self.tap = tap
            } else {
                // HLS streams expose no audio tracks to a tap; capture the app's audio output instead.
                self.startReplayKit()
            }
        }
    }

    private func detachTap() {
        playerItem?.audioMix = nil
        tap = nil
    }

    private func startReplayKit() {
        guard !usingReplayKit else { return }
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable else {
            overlay?.showStatus(L("Audio capture is not available on this device."))
            return
        }
        rec.isMicrophoneEnabled = false
        usingReplayKit = true
        rec.startCapture(handler: { [weak self] sample, type, error in
            guard error == nil, type == .audioApp, let self else { return }
            self.channels.forEach { $0.append(sample) }
        }, completionHandler: { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.usingReplayKit = false
                self?.overlay?.showStatus(L("Audio capture was denied.") + " " + error.localizedDescription)
            }
        })
    }

    // MARK: Recognition

    private func startRecognition() {
        let chosen = Prefs.subtitleSource
        let locales = chosen == "auto" ? SubtitleLanguages.autoCandidates : [chosen]
        detectStart = Date()
        channels = locales.compactMap { loc in
            let ch = RecognitionChannel(locale: loc)
            ch?.onPartial = { [weak self, weak ch] text in
                guard let self, let ch, ch.locale == self.resolvedLocale || (self.channels.count == 1) else { return }
                self.showPartial(text, locale: ch.locale)
            }
            ch?.onFinal = { [weak self, weak ch] text in
                guard let self, let ch else { return }
                if self.resolvedLocale == nil { self.evaluateDetection() }
                if ch.locale == self.resolvedLocale || self.channels.count == 1 { self.commit(text, locale: ch.locale) }
            }
            return ch
        }
        if channels.isEmpty {
            overlay?.showStatus(L("Speech recognition is not available for this language."))
            return
        }
        if channels.count == 1 { resolvedLocale = channels[0].locale }
        channels.forEach { $0.start() }
        if channels.count > 1 { overlay?.showStatus(L("Detecting spoken language…")) }
    }

    /// Picks the auto-detect candidate whose recognizer is most confident, then stops the others.
    private func evaluateDetection() {
        guard resolvedLocale == nil, channels.count > 1 else { return }
        let ready = channels.filter { $0.finalCount > 0 }
        let waited = Date().timeIntervalSince(detectStart)
        guard ready.count == channels.count || (waited > 10 && !ready.isEmpty) else { return }
        let best = ready.max { $0.score < $1.score }!
        resolvedLocale = best.locale
        channels.filter { $0 !== best }.forEach { $0.stop() }
        channels = [best]
        overlay?.showStatus(SubtitleLanguages.name(best.locale), duration: 1.2)
    }

    private func onTick() {
        channels.forEach { $0.tick() }
        if resolvedLocale == nil, Date().timeIntervalSince(detectStart) > 10 { evaluateDetection() }
        if Date().timeIntervalSince(lastUpdate) > 6 { overlay?.fadeOut() }
    }

    // MARK: Display

    private func needsTranslation(_ locale: String) -> Bool {
        mode != .original && SubtitleLanguages.translationCode(locale) != TranslateLanguages.normalize(Prefs.translateTarget)
    }

    private func showPartial(_ text: String, locale: String) {
        lastUpdate = Date()
        guard needsTranslation(locale) else { overlay?.show(original: text, translated: nil, mode: .original); return }
        if mode == .bilingual { overlay?.updateOriginal(text) }
        guard Date().timeIntervalSince(lastPartialTranslate) > 0.7 else { return }
        lastPartialTranslate = Date()
        translate(text, locale: locale, final: false)
    }

    private func commit(_ text: String, locale: String) {
        lastUpdate = Date()
        guard needsTranslation(locale) else { overlay?.show(original: text, translated: nil, mode: .original); return }
        translate(text, locale: locale, final: true)
    }

    private func translate(_ text: String, locale: String, final: Bool) {
        translateGeneration += 1
        let gen = translateGeneration
        let mode = self.mode
        Task { @MainActor in
            do {
                let out = try await TranslationService.shared.translate([text], from: SubtitleLanguages.translationCode(locale), to: Prefs.translateTarget)
                guard final || gen == self.translateGeneration else { return }
                self.overlay?.show(original: text, translated: out.first, mode: mode)
            } catch {
                self.overlay?.show(original: text, translated: nil, mode: .original)
                if final { self.overlay?.showStatus(error.localizedDescription, duration: 3) }
            }
        }
    }
}

/// One SFSpeechRecognizer stream. Requests are rotated at pauses so every utterance gets a final result.
final class RecognitionChannel {
    let locale: String
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    private(set) var finalCount = 0
    private var confidenceSum: Double = 0
    private var charSum = 0

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = 0
    private var partial = ""
    private var partialChanged = Date()
    private var requestStart = Date()
    private var active = false

    init?(locale: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else { return nil }
        self.locale = locale
        recognizer = r
        recognizer.defaultTaskHint = .dictation
    }

    var score: Double {
        guard finalCount > 0 else { return 0 }
        return confidenceSum / Double(finalCount) + min(Double(charSum), 60) / 600
    }

    func start() {
        active = true
        newRequest()
    }

    func stop() {
        active = false
        lock.lock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }

    func append(_ sample: CMSampleBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.appendAudioSampleBuffer(sample)
    }

    /// Called on the main thread every 250 ms.
    func tick() {
        guard active, !partial.isEmpty else { return }
        let maxLen = SubtitleLanguages.isCJK(locale) ? 38 : 110
        let paused = Date().timeIntervalSince(partialChanged) > 0.9
        if paused || partial.count > maxLen || Date().timeIntervalSince(requestStart) > 14 { rotate() }
    }

    private func newRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if #available(iOS 16.0, *) { req.addsPunctuation = true }
        token += 1
        let myToken = token
        partial = ""
        requestStart = Date()
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error, token: myToken) }
        }
        lock.lock()
        request = req
        task = t
        lock.unlock()
    }

    private var pendingFinal: [Int: String] = [:]

    private func rotate() {
        let oldToken = token
        pendingFinal[oldToken] = partial
        lock.lock()
        let oldRequest = request
        lock.unlock()
        newRequest()
        oldRequest?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let text = self.pendingFinal.removeValue(forKey: oldToken), !text.isEmpty else { return }
            self.emitFinal(text, confidence: 0.5)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, token t: Int) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                if t == token {
                    partial = ""
                    if !text.isEmpty { emitFinal(text, confidence: Self.confidence(result)) }
                    if active { newRequest() }
                } else if pendingFinal.removeValue(forKey: t) != nil, !text.isEmpty {
                    emitFinal(text, confidence: Self.confidence(result))
                }
                return
            }
            if t == token, text != partial {
                partial = text
                partialChanged = Date()
                onPartial?(text)
            }
        }
        if error != nil, t == token, active {
            if !partial.isEmpty { emitFinal(partial, confidence: 0.4); partial = "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.active, self.token == t else { return }
                self.newRequest()
            }
        }
    }

    private func emitFinal(_ text: String, confidence: Double) {
        finalCount += 1
        confidenceSum += confidence
        charSum += text.count
        onFinal?(text)
    }

    private static func confidence(_ r: SFSpeechRecognitionResult) -> Double {
        let segs = r.bestTranscription.segments
        guard !segs.isEmpty else { return 0 }
        let total = segs.reduce(0.0) { $0 + max($1.duration, 0.05) }
        return segs.reduce(0.0) { $0 + Double($1.confidence) * max($1.duration, 0.05) } / total
    }
}

/// MTAudioProcessingTap that copies the player's PCM output for speech recognition.
final class PlayerAudioTap {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    fileprivate var format: AVAudioFormat?
    let audioMix: AVMutableAudioMix

    init?(track: AVAssetTrack) {
        audioMix = AVMutableAudioMix()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)
        callbacks.clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(TapBox(self)).toOpaque())
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        audioMix.inputParameters = [params]
    }

    fileprivate func handle(_ list: UnsafeMutablePointer<AudioBufferList>, frames: AVAudioFrameCount) {
        guard let format, frames > 0, let onBuffer,
              let src = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        copy.frameLength = frames
        let s = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let d = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(s.count, d.count) {
            guard let sp = s[i].mData, let dp = d[i].mData else { continue }
            memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
        }
        onBuffer(copy)
    }
}

/// Weak box passed through the tap's C storage pointer.
private final class TapBox {
    weak var tap: PlayerAudioTap?
    init(_ t: PlayerAudioTap) { tap = t }
}

private func box(_ tap: MTAudioProcessingTap) -> TapBox {
    Unmanaged<TapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, asbd in
    box(tap).tap?.format = AVAudioFormat(streamDescription: asbd)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
    box(tap).tap?.handle(bufferList, frames: AVAudioFrameCount(framesOut.pointee))
}

// MARK: - Overlay

/// Caption view used both inside the floating player and above the web page.
final class SubtitleOverlayView: UIView {
    var onTap: (() -> Void)?

    private let stack = UIStackView()
    private let primary = PaddingLabel()
    private let secondary = PaddingLabel()
    private let status = PaddingLabel()
    private var compact = false
    private var statusWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 3
        for l in [status, secondary, primary] {
            l.numberOfLines = 3
            l.textAlignment = .center
            l.textColor = .white
            l.backgroundColor = UIColor.black.withAlphaComponent(0.62)
            l.layer.cornerRadius = 6
            l.clipsToBounds = true
            l.insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
            l.isHidden = true
            stack.addArrangedSubview(l)
        }
        status.textColor = UIColor(white: 1, alpha: 0.85)
        addSubview(stack)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        refreshStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        stack.arrangedSubviews.contains { !$0.isHidden && $0.frame.insetBy(dx: -8, dy: -8).contains(convert(point, to: stack)) }
    }

    func refreshStyle() {
        let size = CGFloat(Prefs.subtitleFontSize) * (compact ? 0.72 : 1)
        primary.font = .systemFont(ofSize: size, weight: .semibold)
        secondary.font = .systemFont(ofSize: size * 0.8, weight: .regular)
        secondary.textColor = UIColor(white: 1, alpha: 0.82)
        status.font = .systemFont(ofSize: max(11, size * 0.7), weight: .medium)
    }

    func layoutIn(bounds b: CGRect, bottomInset: CGFloat, compact: Bool) {
        self.compact = compact
        refreshStyle()
        frame = b
        let maxW = b.width - 24
        stack.frame = CGRect(x: 12, y: 0, width: maxW, height: b.height - bottomInset)
        [primary, secondary, status].forEach { $0.preferredMaxLayoutWidth = maxW - 16 }
        stack.layoutIfNeeded()
        let h = stack.systemLayoutSizeFitting(CGSize(width: maxW, height: UIView.layoutFittingCompressedSize.height)).height
        stack.frame = CGRect(x: 12, y: b.height - bottomInset - h, width: maxW, height: h)
    }

    private func relayout() {
        guard let sv = superview else { return }
        if sv.bounds == frame { layoutIn(bounds: frame, bottomInset: bounds.height - stack.frame.maxY, compact: compact) }
        else { setNeedsLayout() }
    }

    func show(original: String, translated: String?, mode: SubtitleMode) {
        alpha = 1
        switch mode {
        case .original:
            set(primary, original); set(secondary, nil)
        case .translation:
            set(primary, translated ?? original); set(secondary, nil)
        case .bilingual:
            set(primary, translated ?? original); set(secondary, translated == nil ? nil : original)
        }
        relayout()
    }

    func updateOriginal(_ text: String) {
        alpha = 1
        set(secondary, text)
        if primary.isHidden { set(primary, "…") }
        relayout()
    }

    func showStatus(_ text: String, duration: TimeInterval = 0) {
        alpha = 1
        set(status, text)
        statusWork?.cancel()
        if duration > 0 {
            let w = DispatchWorkItem { [weak self] in self?.set(self?.status, nil); self?.relayout() }
            statusWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
        }
        relayout()
    }

    func fadeOut() {
        guard alpha > 0, !primary.isHidden || !secondary.isHidden else { return }
        UIView.animate(withDuration: 0.3) { self.alpha = 0 } completion: { _ in
            self.set(self.primary, nil); self.set(self.secondary, nil); self.alpha = 1
        }
    }

    func clear() {
        [primary, secondary, status].forEach { set($0, nil) }
    }

    private func set(_ l: PaddingLabel?, _ text: String?) {
        guard let l else { return }
        if l === status, text != nil { /* status yields to captions */ } else if l !== status, text != nil, !status.isHidden, statusWork == nil { status.isHidden = true }
        l.text = text
        l.isHidden = text?.isEmpty != false
    }
}
