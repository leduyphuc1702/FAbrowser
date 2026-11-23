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
        ("auto", L("Auto Detect")), ("en-US", "English"), ("ja-JP", "日本語"), ("zh-CN", "中文 (普通话)"),
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
///
/// Spoken language: with SenseVoice the model identifies it. Otherwise a guess from the site/title/page
/// starts subtitles immediately while the other candidate languages run alongside for a few seconds;
/// the best-fitting recognizer wins.
final class LiveSubtitles: NSObject {
    static let shared = LiveSubtitles()

    enum Target { case player, page }

    private(set) var isOn = false
    private(set) var target: Target = .player
    var onStateChange: ((Bool) -> Void)?
    weak var overlay: SubtitleOverlayView?

    private var channels: [SpeechChannel] = [] {
        didSet { sinkLock.lock(); sinks = channels; sinkLock.unlock() }
    }
    private let sinkLock = NSLock()
    private var sinks: [SpeechChannel] = []
    private(set) var resolvedLocale: String?
    private var provisional = false
    private var firstHeard: Date?
    private var hint: SubtitleHint?
    private var generation = 0
    private var finalText = ""
    private var partialText = ""
    private var lastTextChange = Date.distantPast
    private var shownUnit = ""
    private var recentStable: [String] = []
    private var displayedGeneration = 0
    private var upgrading: String?
    private var senseVoiceFailed = false
    private weak var presenter: UIViewController?
    private var tap: PlayerAudioTap?
    private weak var playerItem: AVPlayerItem?
    private var usingReplayKit = false
    private var tick: Timer?
    private var lastInterimTranslate = Date.distantPast
    private var translateGeneration = 0
    private var lastUpdate = Date()

    var mode: SubtitleMode { SubtitleMode(rawValue: Prefs.subtitleModeRaw) ?? .translation }

    /// Name of the engine in use, for the settings page.
    var engineName: String? {
        guard isOn, let ch = channels.first(where: { $0.locale == resolvedLocale }) ?? channels.first else { return nil }
        switch ch.kind {
        case .senseVoice: return "SenseVoice"
        case .apple: return L("New Speech Model")
        case .basic: return L("Basic Speech Model")
        }
    }

    // MARK: Public control

    func start(target: Target, overlay: SubtitleOverlayView, item: AVPlayerItem?, presenter: UIViewController, hint: SubtitleHint? = nil) {
        stop()
        self.target = target
        self.overlay = overlay
        self.hint = hint
        self.presenter = presenter
        senseVoiceFailed = false
        requestPermission(presenter: presenter) { [weak self] ok in
            guard let self, ok else { return }
            self.isOn = true
            self.onStateChange?(true)
            self.startRecognition()
            if target == .player, let item { self.attachAudio(to: item) } else { self.startReplayKit() }
            self.tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
            if SpeechEngine.senseVoiceAllowed, !SenseVoiceModel.isDownloaded, SenseVoiceModel.progress == nil, !Prefs.senseVoiceOffered {
                self.offerSenseVoice()
            }
        }
    }

    func stop() {
        generation += 1
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
        resetText()
        if was { onStateChange?(false) }
    }

    /// Restart recognition after the user changes the spoken language.
    func restartRecognition() {
        guard isOn else { return }
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
        // SenseVoice runs entirely in the app and needs no Speech Recognition permission.
        if SpeechEngine.senseVoiceHandles(Prefs.subtitleSource) { completion(true); return }
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

    private func forEachSink(_ body: (SpeechChannel) -> Void) {
        sinkLock.lock(); let s = sinks; sinkLock.unlock()
        s.forEach(body)
    }

    private func attachAudio(to item: AVPlayerItem) {
        playerItem = item
        Task { @MainActor in
            let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            guard self.isOn, self.playerItem === item else { return }
            if let track = tracks.first, let tap = PlayerAudioTap(track: track) {
                tap.onBuffer = { [weak self] buf in self?.forEachSink { $0.append(buf) } }
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
            self.forEachSink { $0.append(sample) }
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
        generation += 1
        let gen = generation
        channels.forEach { $0.stop() }
        channels = []
        resolvedLocale = nil
        provisional = false
        firstHeard = nil
        resetText()

        let chosen = Prefs.subtitleSource
        var locales = [chosen]
        var prior: String?
        if chosen == "auto" {
            prior = LanguageGuess.prior(hint)
            locales = SubtitleLanguages.autoCandidates
            if let p = prior { locales.removeAll { $0 == p }; locales.insert(p, at: 0) }
        }
        overlay?.showStatus(locales.count > 1 && prior == nil ? L("Detecting spoken language…") : L("Listening…"))

        if !senseVoiceFailed, SpeechEngine.senseVoiceHandles(chosen) {
            startSenseVoice(locale: chosen == "auto" ? nil : chosen)
            return
        }

        Task { @MainActor in
            var made: [SpeechChannel] = []
            for loc in locales {
                if let ch = await SpeechEngine.makeChannel(loc) { made.append(ch) }
            }
            guard gen == self.generation, self.isOn else { return }
            guard !made.isEmpty else {
                self.overlay?.showStatus(L("Speech recognition is not available for this language."))
                return
            }
            made.forEach(self.wire)
            self.log("channels " + made.map { $0.locale + "(\($0.kind))" }.joined(separator: ",") + " prior=" + (prior ?? "-"))
            self.channels = made
            if made.count == 1 {
                self.resolve(made[0], provisional: false)
            } else if let p = prior, let ch = made.first(where: { $0.locale == p }) {
                self.resolve(ch, provisional: true)
            }
            made.forEach { $0.start() }
        }
    }

    /// One SenseVoice channel replaces the per-language recognizers: it identifies the language itself.
    private func startSenseVoice(locale: String?) {
        let ch = SenseVoiceChannel(locale: locale)
        wire(ch)
        ch.onLanguage = { [weak self, weak ch] _ in
            guard let self, let ch, self.channels.first === ch else { return }
            self.resolve(ch, provisional: false)
        }
        channels = [ch]
        log("channels sensevoice " + (locale ?? "auto"))
        if locale != nil { resolve(ch, provisional: false) }
        ch.start()
    }

    private func offerSenseVoice() {
        guard let presenter, presenter.view.window != nil, presenter.presentedViewController == nil else { return }
        Prefs.senseVoiceOffered = true
        let a = UIAlertController(title: L("Better Subtitles"), message: String(format: L("Download the SenseVoice speech model (%d MB, free, works offline)? It recognizes Chinese, English, Japanese, Korean and Cantonese far more accurately and detects the spoken language in about a second."), SenseVoiceModel.downloadMB), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("Not Now"), style: .cancel))
        a.addAction(UIAlertAction(title: L("Download"), style: .default) { [weak self] _ in self?.downloadSenseVoice() })
        presenter.present(a, animated: true)
    }

    /// Downloads the SenseVoice model and switches to it if subtitles are still on.
    func downloadSenseVoice() {
        SenseVoiceModel.download(progress: { [weak self] p in
            guard let self, self.isOn else { return }
            self.overlay?.showStatus(String(format: L("Downloading speech model… %d%%"), Int(p * 100)), duration: 2)
        }, completion: { [weak self] error in
            guard let self, self.isOn else { return }
            if let error {
                if !(error is CancellationError) { self.overlay?.showStatus(L("Couldn't download the speech model.") + " " + error.localizedDescription, duration: 3) }
                return
            }
            guard SpeechEngine.senseVoiceHandles(Prefs.subtitleSource) else { return }
            self.senseVoiceFailed = false
            self.startRecognition()
            self.overlay?.showStatus(L("Using the new speech model"), duration: 2)
        })
    }

    private func wire(_ ch: SpeechChannel) {
        ch.onPartial = { [weak self, weak ch] text in
            guard let self, let ch else { return }
            if self.firstHeard == nil { self.firstHeard = Date() }
            guard ch.locale == self.resolvedLocale else { return }
            self.partialText = text
            self.textChanged()
        }
        ch.onFinal = { [weak self, weak ch] text in
            guard let self, let ch else { return }
            if self.firstHeard == nil { self.firstHeard = Date() }
            guard ch.locale == self.resolvedLocale else { return }
            self.partialText = ""
            self.finalText = Sentences.join(self.finalText, text, cjk: SubtitleLanguages.isCJK(ch.locale))
            if self.finalText.count > 500 { self.finalText = String(self.finalText.suffix(300)) }
            self.textChanged()
        }
        ch.onFailure = { [weak self, weak ch] error in
            guard let self, let ch else { return }
            self.channelFailed(ch, error)
        }
    }

    /// The new engine can refuse to run (no resources, model removed): fall back to the basic one.
    private func channelFailed(_ ch: SpeechChannel, _ error: Error) {
        guard let i = channels.firstIndex(where: { $0 === ch }) else { return }
        ch.stop()
        if ch.kind == .senseVoice {
            senseVoiceFailed = true
            overlay?.showStatus(error.localizedDescription, duration: 3)
            startRecognition()
            return
        }
        if ch.kind == .apple, let legacy = LegacySpeechChannel(locale: ch.locale) {
            wire(legacy)
            channels[i] = legacy
            legacy.start()
            return
        }
        channels.remove(at: i)
        if channels.isEmpty {
            overlay?.showStatus(error.localizedDescription, duration: 4)
        } else if ch.locale == resolvedLocale, channels.count == 1 {
            resolve(channels[0], provisional: false)
        }
    }

    private func resolve(_ ch: SpeechChannel, provisional: Bool) {
        if resolvedLocale != ch.locale {
            resolvedLocale = ch.locale
            resetText()
            // Show what the winning recognizer already heard instead of starting blank.
            finalText = ch.finalTranscript
            partialText = ch.volatileTranscript
            if !finalText.isEmpty || !partialText.isEmpty { textChanged() }
        }
        self.provisional = provisional
        log("resolve \(ch.locale) provisional=\(provisional) after " + (firstHeard.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "-") + " scores=" + channels.map { $0.locale + String(format: ":%.2f", LanguageGuess.score($0)) }.joined(separator: " "))
        overlay?.showStatus(SubtitleLanguages.name(ch.locale), duration: provisional ? 2 : 1.5)
        guard !provisional else { return }
        channels.filter { $0 !== ch }.forEach { $0.stop() }
        channels = [ch]
        if Prefs.subtitleSource == "auto" { LanguageGuess.remember(ch.locale, host: hint?.host) }
        upgradeIfPossible(ch)
    }

    /// Picks the candidate whose output best fits its own language. Decides as soon as one
    /// recognizer clearly leads instead of waiting for every recognizer to finish a sentence.
    private func evaluateDetection() {
        guard let heardAt = firstHeard,
              let best = LanguageGuess.decide(channels, favoring: provisional ? resolvedLocale : nil, elapsed: Date().timeIntervalSince(heardAt)) else { return }
        resolve(best, provisional: false)
    }

    /// Basic recognizer in use but the new on-device model supports this language: fetch it and switch.
    private func upgradeIfPossible(_ ch: SpeechChannel) {
        guard !ch.isModern, upgrading == nil else { return }
        let locale = ch.locale
        let gen = generation
        Task { @MainActor in
            guard await SpeechEngine.canUpgrade(locale) else { return }
            self.upgrading = locale
            defer { self.upgrading = nil }
            do {
                try await SpeechEngine.download(locale) { [weak self] p in
                    guard let self, self.isOn else { return }
                    self.overlay?.showStatus(String(format: L("Downloading speech model… %d%%"), Int(p * 100)), duration: 2)
                }
            } catch {
                self.overlay?.showStatus(L("Couldn't download the speech model.") + " " + error.localizedDescription, duration: 3)
                return
            }
            guard gen == self.generation, self.isOn, self.channels.count == 1, self.channels[0] === ch,
                  let modern = await SpeechEngine.makeChannel(locale), modern.isModern,
                  gen == self.generation, self.channels.first === ch else { return }
            self.wire(modern)
            modern.start()
            self.channels = [modern]
            ch.stop()
            self.overlay?.showStatus(L("Using the new speech model"), duration: 2)
        }
    }

    private func onTick() {
        channels.forEach { $0.tick() }
        if channels.count > 1 { evaluateDetection() }
        if Date().timeIntervalSince(lastTextChange) > 1.4 { refreshDisplay() }
        if Date().timeIntervalSince(lastUpdate) > 6 { overlay?.fadeOut() }
    }

    private func log(_ s: String) {
        #if DEBUG
        NSLog("[subs] %@", s)
        #endif
    }

    // MARK: Display

    private func needsTranslation(_ locale: String) -> Bool {
        mode != .original && SubtitleLanguages.translationCode(locale) != TranslateLanguages.normalize(Prefs.translateTarget)
    }

    private func resetText() {
        finalText = ""
        partialText = ""
        shownUnit = ""
        recentStable = []
    }

    private func textChanged() {
        lastUpdate = Date()
        lastTextChange = Date()
        refreshDisplay()
    }

    /// Shows the last complete sentence, or the sentence in progress once it is long enough.
    /// Complete sentences are translated (and cached) once; the one in progress is re-translated
    /// at most every 0.8 s and replaced when it completes.
    private func refreshDisplay() {
        guard let locale = resolvedLocale else { return }
        let cjk = SubtitleLanguages.isCJK(locale)
        let live = Sentences.join(finalText, partialText, cjk: cjk)
        let paused = Date().timeIntervalSince(lastTextChange) > 1.4
        guard let unit = Sentences.displayUnit(live, cjk: cjk, paused: paused), unit.text != shownUnit else { return }
        // Never step back to a sentence that newer text already replaced.
        if unit.stable {
            guard !recentStable.contains(unit.text) else { return }
            recentStable.append(unit.text)
            if recentStable.count > 6 { recentStable.removeFirst() }
        }
        guard needsTranslation(locale) else {
            shownUnit = unit.text
            overlay?.show(original: unit.text, translated: nil, mode: .original)
            return
        }
        if !unit.stable {
            guard Date().timeIntervalSince(lastInterimTranslate) > 0.8 else { return }
            lastInterimTranslate = Date()
        } else {
            log("sentence: " + unit.text)
        }
        shownUnit = unit.text
        if mode == .bilingual { overlay?.updateOriginal(unit.text) }
        translate(unit.text, locale: locale, final: unit.stable)
    }

    private func translate(_ text: String, locale: String, final: Bool) {
        translateGeneration += 1
        let gen = translateGeneration
        let mode = self.mode
        Task { @MainActor in
            do {
                let out = try await TranslationService.shared.translate([text], from: SubtitleLanguages.translationCode(locale), to: Prefs.translateTarget, cache: final)
                // Results can arrive out of order; never replace a newer caption with an older one.
                guard self.isOn, gen > self.displayedGeneration else { return }
                self.displayedGeneration = gen
                self.overlay?.show(original: text, translated: out.first, mode: mode)
            } catch {
                guard self.isOn, gen > self.displayedGeneration else { return }
                self.displayedGeneration = gen
                self.overlay?.show(original: text, translated: nil, mode: .original)
                if final { self.overlay?.showStatus(error.localizedDescription, duration: 3) }
            }
        }
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
