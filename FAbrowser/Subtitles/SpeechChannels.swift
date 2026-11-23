import Foundation
import Speech
import AVFoundation
import NaturalLanguage

/// One speech-to-text stream for a single spoken language. Callbacks arrive on the main thread;
/// `append` may be called from any thread.
enum SpeechEngineKind {
    case basic, apple, senseVoice
}

protocol SpeechChannel: AnyObject {
    var locale: String { get }
    var kind: SpeechEngineKind { get }
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    /// Finalized text so far and the words still being recognized.
    var finalTranscript: String { get }
    var volatileTranscript: String { get }
    /// Everything recognized so far (finals plus the current partial), used for language detection.
    var heard: String { get }
    /// Mean recognizer confidence 0...1, or -1 when the engine hasn't reported any yet.
    var confidence: Double { get }
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
    func append(_ sample: CMSampleBuffer)
    func tick()
}

extension SpeechChannel {
    var isModern: Bool { kind != .basic }
}

/// Engine choice (Prefs.subtitleEngine): "auto" uses SenseVoice for the languages it knows once its
/// model is downloaded, else Apple's newest model (iOS 26), else SFSpeechRecognizer.
enum SpeechEngine {
    static var appleAllowed: Bool { ["auto", "apple"].contains(Prefs.subtitleEngine) }
    static var senseVoiceAllowed: Bool { ["auto", "sensevoice"].contains(Prefs.subtitleEngine) }

    /// SenseVoice will handle `source` ("auto" or a recognizer locale).
    static func senseVoiceHandles(_ source: String) -> Bool {
        senseVoiceAllowed && SenseVoiceModel.supports(source) && SenseVoiceModel.isDownloaded
    }

    /// Creates the best available channel: SpeechAnalyzer when its model for `locale` is installed, else SFSpeechRecognizer.
    @MainActor
    static func makeChannel(_ locale: String) async -> SpeechChannel? {
        if #available(iOS 26.0, *), appleAllowed, let loc = await ModernSpeech.installedLocale(for: locale) {
            return ModernSpeechChannel(locale: locale, speechLocale: loc)
        }
        return LegacySpeechChannel(locale: locale)
    }

    /// Whether the new on-device model could be used for `locale` after a download.
    static func canUpgrade(_ locale: String) async -> Bool {
        if #available(iOS 26.0, *), appleAllowed { return await ModernSpeech.supportedLocale(for: locale) != nil }
        return false
    }

    static func download(_ locale: String, progress: @escaping (Double) -> Void) async throws {
        if #available(iOS 26.0, *), let loc = await ModernSpeech.supportedLocale(for: locale) {
            try await ModernSpeech.install(loc, progress: progress)
        }
    }

    static var modernAvailable: Bool {
        if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }
}

// MARK: - SpeechAnalyzer (iOS 26)

@available(iOS 26.0, *)
enum ModernSpeech {
    static func supportedLocale(for code: String) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code))
    }

    static func installedLocale(for code: String) async -> Locale? {
        guard let loc = await supportedLocale(for: code) else { return nil }
        let id = loc.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == id } ? loc : nil
    }

    static func install(_ locale: Locale, progress: @escaping (Double) -> Void) async throws {
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            // Too many reserved locales: give up the oldest one this app holds and retry once.
            if let old = await AssetInventory.reservedLocales.first(where: { $0.identifier(.bcp47) != locale.identifier(.bcp47) }) {
                await AssetInventory.release(reservedLocale: old)
                _ = try? await AssetInventory.reserve(locale: locale)
            }
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { progress(f) }
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}

/// Apple's long-form on-device model (the one behind Notes and Voice Memos transcripts).
/// Much more accurate than SFSpeechRecognizer, punctuates, and needs no request rotation.
@available(iOS 26.0, *)
final class ModernSpeechChannel: SpeechChannel {
    let locale: String
    let kind = SpeechEngineKind.apple
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let speechLocale: Locale
    private let feeder = AnalyzerFeeder()
    private var analyzer: SpeechAnalyzer?
    private var tasks: [Task<Void, Never>] = []
    private var finalText = ""
    private var partial = ""
    private var confSum = 0.0, confWeight = 0.0
    private var partialConf = -1.0
    private var stopped = false

    init(locale: String, speechLocale: Locale) {
        self.locale = locale
        self.speechLocale = speechLocale
    }

    var heard: String { partial.isEmpty ? finalText : finalText + " " + partial }
    var finalTranscript: String { finalText }
    var volatileTranscript: String { partial }

    var confidence: Double {
        let w = confWeight + (partialConf >= 0 ? Double(partial.count) : 0)
        guard w > 0 else { return -1 }
        return (confSum + (partialConf >= 0 ? partialConf * Double(partial.count) : 0)) / w
    }

    func start() {
        let transcriber = SpeechTranscriber(locale: speechLocale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(600))
        let feeder = self.feeder

        tasks.append(Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    var sum = 0.0, weight = 0.0
                    for run in r.text.runs {
                        guard let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
                        let n = Double(r.text[run.range].characters.count)
                        sum += c * n
                        weight += n
                    }
                    let isFinal = r.isFinal, conf = weight > 0 ? sum / weight : -1, w = weight
                    guard let me = self else { return }
                    await MainActor.run { me.handle(text, final: isFinal, conf: conf, weight: w) }
                }
            } catch {
                guard let me = self else { return }
                await MainActor.run { me.fail(error) }
            }
        })
        tasks.append(Task { [weak self] in
            do {
                let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                let format = best ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
                try await analyzer.prepareToAnalyze(in: format)
                feeder.configure(format: format, continuation: continuation)
                try await analyzer.start(inputSequence: stream)
            } catch {
                guard let me = self else { return }
                await MainActor.run { me.fail(error) }
            }
        })
    }

    func stop() {
        stopped = true
        feeder.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) { feeder.feed(buffer) }

    func append(_ sample: CMSampleBuffer) {
        if let b = AudioPCM.buffer(from: sample) { feeder.feed(b) }
    }

    func tick() {}

    private func handle(_ text: String, final: Bool, conf: Double, weight: Double) {
        guard !stopped else { return }
        if final {
            partial = ""
            partialConf = -1
            guard !text.isEmpty else { return }
            finalText = finalText.isEmpty ? text : finalText + " " + text
            if finalText.count > 600 { finalText = String(finalText.suffix(400)) }
            if conf >= 0 { confSum += conf * weight; confWeight += weight }
            onFinal?(text)
        } else if text != partial {
            partial = text
            partialConf = conf
            if !text.isEmpty { onPartial?(text) }
        }
    }

    private func fail(_ error: Error) {
        guard !stopped, !(error is CancellationError) else { return }
        onFailure?(error)
    }
}

/// Converts whatever PCM the player or ReplayKit delivers into the analyzer's format and queues it.
@available(iOS 26.0, *)
private final class AnalyzerFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var target: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func configure(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        target = format
        self.continuation = continuation
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let target, let continuation, buffer.frameLength > 0 else { return }
        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            sourceFormat = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
}

enum AudioPCM {
    /// Copies a ReplayKit audio sample buffer into an AVAudioPCMBuffer (byte-swapping big-endian app audio).
    static func buffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPtr.pointee
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if bigEndian { asbd.mFormatFlags &= ~kAudioFormatFlagIsBigEndian }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let format = AVAudioFormat(streamDescription: &asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr else { return nil }
        if bigEndian, asbd.mBitsPerChannel == 16 {
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                guard let p = b.mData?.assumingMemoryBound(to: UInt16.self) else { continue }
                for i in 0..<Int(b.mDataByteSize) / 2 { p[i] = p[i].byteSwapped }
            }
        }
        return buf
    }
}

// MARK: - SFSpeechRecognizer (iOS 16+ fallback)

/// One SFSpeechRecognizer stream. Requests are rotated at pauses so every utterance gets a final result.
final class LegacySpeechChannel: SpeechChannel {
    let locale: String
    let kind = SpeechEngineKind.basic
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var finalText = ""
    private var confidenceSum: Double = 0
    private var finalCount = 0

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = 0
    private var partial = ""
    private var partialChanged = Date()
    private var requestStart = Date()
    private var active = false
    private var pendingFinal: [Int: String] = [:]
    private var errorStreak = 0

    init?(locale: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else { return nil }
        self.locale = locale
        recognizer = r
        recognizer.defaultTaskHint = .dictation
    }

    var heard: String { partial.isEmpty ? finalText : finalText + " " + partial }
    var finalTranscript: String { finalText }
    var volatileTranscript: String { partial }
    var confidence: Double { finalCount > 0 ? confidenceSum / Double(finalCount) : -1 }

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

    /// Called on the main thread every 250 ms. Waits for a real pause so sentences aren't cut in half.
    func tick() {
        guard active, !partial.isEmpty else { return }
        let maxLen = SubtitleLanguages.isCJK(locale) ? 56 : 170
        let paused = Date().timeIntervalSince(partialChanged) > 1.3
        if paused || partial.count > maxLen || Date().timeIntervalSince(requestStart) > 40 { rotate() }
    }

    private func newRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
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
        if result != nil { errorStreak = 0 }
        if error != nil, t == token, active {
            if !partial.isEmpty { emitFinal(partial, confidence: 0.4); partial = "" }
            // Back off when the recognizer keeps failing (no network/model) instead of spinning.
            errorStreak += 1
            let delay = min(0.3 * pow(2, Double(errorStreak - 1)), 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.active, self.token == t else { return }
                self.newRequest()
            }
        }
    }

    private func emitFinal(_ text: String, confidence: Double) {
        finalCount += 1
        confidenceSum += confidence
        finalText = finalText.isEmpty ? text : finalText + " " + text
        if finalText.count > 600 { finalText = String(finalText.suffix(400)) }
        onFinal?(text)
    }

    private static func confidence(_ r: SFSpeechRecognitionResult) -> Double {
        let segs = r.bestTranscription.segments
        guard !segs.isEmpty else { return 0 }
        let total = segs.reduce(0.0) { $0 + max($1.duration, 0.05) }
        return segs.reduce(0.0) { $0 + Double($1.confidence) * max($1.duration, 0.05) } / total
    }
}

// MARK: - Sentences

/// Picks what to show and translate from the running transcript. Translating whole sentences
/// ("and then we went to the market.") gives far better results than translating fragments.
enum Sentences {
    private static let enders: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "؟", "।"]
    private static let commas: Set<Character> = [",", "，", "、", ";", "；"]

    static func join(_ a: String, _ b: String, cjk: Bool) -> String {
        a.isEmpty ? b : (b.isEmpty ? a : a + (cjk ? "" : " ") + b)
    }

    /// Splits text into complete sentences and the unfinished tail. Over-long tails are cut at a comma.
    static func split(_ text: String, cjk: Bool) -> (complete: [String], tail: String) {
        var complete: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if enders.contains(c) {
                let atBoundary = next == text.endIndex || text[next] == " " || "。！？".contains(c)
                let isDecimal = c == "." && next < text.endIndex && text[next].isNumber
                if atBoundary, !isDecimal {
                    var end = next
                    while end < text.endIndex, enders.contains(text[end]) || "\"”」』)".contains(text[end]) { end = text.index(after: end) }
                    let s = text[start..<end].trimmingCharacters(in: .whitespaces)
                    if s.count >= (cjk ? 2 : 4) { complete.append(s); start = end }
                    i = end
                    continue
                }
            }
            i = next
        }
        var tail = String(text[start...]).trimmingCharacters(in: .whitespaces)
        let maxLength = cjk ? 48 : 120
        // Long run-on speech: cut it into caption-sized pieces at commas.
        while tail.count > maxLength {
            let cuts = tail.indices.filter { commas.contains(tail[$0]) && tail.distance(from: $0, to: tail.endIndex) > 4 }
            guard let cut = cuts.last(where: { tail.distance(from: tail.startIndex, to: $0) < maxLength }) ?? cuts.first else { break }
            complete.append(String(tail[...cut]).trimmingCharacters(in: .whitespaces))
            tail = String(tail[tail.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
        }
        return (complete, tail)
    }

    /// The caption to show: the sentence in progress once it is long enough (interim), else the
    /// last complete sentence (stable). A tail counts as complete after the speaker pauses.
    static func displayUnit(_ text: String, cjk: Bool, paused: Bool) -> (text: String, stable: Bool)? {
        let (complete, tail) = split(text, cjk: cjk)
        if !tail.isEmpty {
            if paused { return (tail, true) }
            let long = cjk ? tail.count >= 8 : tail.split(separator: " ").count >= 5
            if long || complete.isEmpty && tail.count >= (cjk ? 4 : 12) { return (tail, false) }
        }
        return complete.last.map { ($0, true) }
    }
}

// MARK: - Language detection

struct SubtitleHint {
    var host: String?
    var title: String?
    var pageLanguage: String?
}

enum LanguageGuess {
    private static let memoryKey = "subtitleLangByHost"

    /// A likely spoken language before hearing anything: last language used on this site, then the
    /// language of the video title, then the page language.
    static func prior(_ hint: SubtitleHint?) -> String? {
        guard let hint else { return nil }
        if let host = hint.host.map(siteKey), let saved = (UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: String])?[host],
           SubtitleLanguages.sources.contains(where: { $0.code == saved }) {
            return saved
        }
        if let title = hint.title?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 6 {
            let r = NLLanguageRecognizer()
            r.processString(title)
            if let h = r.languageHypotheses(withMaximum: 1).first, h.value >= 0.7, let loc = speechLocale(for: h.key.rawValue) { return loc }
        }
        if let page = hint.pageLanguage, let loc = speechLocale(for: page) { return loc }
        return nil
    }

    static func remember(_ locale: String, host: String?) {
        guard let host = host.map(siteKey) else { return }
        var d = UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: String] ?? [:]
        d[host] = locale
        if d.count > 300 { d.removeValue(forKey: d.keys.first { $0 != host }!) }
        UserDefaults.standard.set(d, forKey: memoryKey)
    }

    static func speechLocale(for language: String) -> String? {
        switch TranslateLanguages.normalize(language) {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case let l: return SubtitleLanguages.sources.first { $0.code != "auto" && $0.code.hasPrefix(l + "-") }?.code
        }
    }

    private static func siteKey(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : (h.hasPrefix("m.") ? String(h.dropFirst(2)) : h)
    }

    /// How well a channel's output fits its own language. Recognizers fed the wrong language still
    /// produce text, but in the wrong script (Latin words from the Chinese model, no kana from the
    /// Japanese one) and with low confidence.
    static func score(_ ch: SpeechChannel) -> Double {
        let text = ch.heard
        guard !text.isEmpty else { return 0 }
        var s = ch.confidence >= 0 ? ch.confidence : 0.5
        var letters = 0, latin = 0, hiragana = 0, katakana = 0, han = 0, hangul = 0, thai = 0, cyrillic = 0
        for u in text.unicodeScalars where CharacterSet.letters.contains(u) {
            letters += 1
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            case 0x3040...0x309F: hiragana += 1
            case 0x30A0...0x30FF: katakana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0x0400...0x04FF: cyrillic += 1
            default: break
            }
        }
        guard letters > 0 else { return 0 }
        let n = Double(letters)
        let lang = String(ch.locale.prefix(2))
        switch lang {
        case "ja":
            // Real Japanese is full of hiragana particles; foreign speech comes out as katakana.
            let hira = Double(hiragana) / n
            s += hira >= 0.15 ? 0.2 : (Double(katakana) / n > 0.4 ? -0.35 : -0.15)
            if Double(latin) / n > 0.3 { s -= 0.4 }
        case "zh", "yu":
            if Double(hiragana + katakana) / n > 0.03 { s -= 0.35 }
            if Double(latin) / n > 0.3 { s -= 0.4 }
            if Double(han) / n > 0.8 { s += 0.05 }
        case "ko": s += Double(hangul) / n > 0.6 ? 0.1 : -0.4
        case "th": s += Double(thai) / n > 0.6 ? 0.1 : -0.4
        case "ru": s += Double(cyrillic) / n > 0.6 ? 0.1 : -0.4
        default:
            if Double(latin) / n < 0.85 { s -= 0.4 }
            if text.count >= 24 {
                let r = NLLanguageRecognizer()
                r.processString(text)
                let p = r.languageHypotheses(withMaximum: 3).first { TranslateLanguages.normalize($0.key.rawValue) == lang }?.value ?? 0
                s += (p - 0.5) * 0.3
            }
        }
        // More recognized speech is more evidence.
        return s + min(amount(ch), 60) / 600
    }

    /// Roughly comparable amount of recognized speech: one CJK character carries about as much as 2.5 Latin letters.
    static func amount(_ ch: SpeechChannel) -> Double {
        let t = ch.heard
        return SubtitleLanguages.isCJK(ch.locale) ? Double(t.count) * 2.5 : Double(t.filter { !$0.isWhitespace }.count)
    }

    /// The winning channel once one clearly leads, else nil. `favoring` is the language guessed up
    /// front, which wins ties. `elapsed` counts from the first recognized speech.
    static func decide(_ channels: [SpeechChannel], favoring: String?, elapsed: TimeInterval) -> SpeechChannel? {
        guard channels.count > 1 else { return channels.first }
        // A recognizer fed a language it doesn't know mostly gives up, so it produces much less text.
        let most = channels.map(amount).max() ?? 0
        let ranked = channels.map { ch -> (SpeechChannel, Double) in
            let ratio = most > 0 ? amount(ch) / most : 0
            return (ch, score(ch) + (ch.locale == favoring ? 0.05 : 0) - max(0, 0.5 - ratio) * 0.8)
        }.sorted { $0.1 > $1.1 }
        let (best, top) = ranked[0]
        guard !best.heard.isEmpty, elapsed >= 1.5 else { return nil }
        let margin = top - ranked[1].1
        let enough = hasEnoughText(best)
        return (enough && margin >= 0.2) || (elapsed > 3 && margin >= 0.1) || elapsed > 6 ? best : nil
    }

    /// Enough text to trust the score.
    static func hasEnoughText(_ ch: SpeechChannel) -> Bool {
        let t = ch.heard
        return SubtitleLanguages.isCJK(ch.locale) ? t.count >= 8 : t.split(separator: " ").count >= 4
    }
}
