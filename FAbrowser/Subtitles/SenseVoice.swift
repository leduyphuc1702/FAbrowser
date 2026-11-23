import Foundation
import AVFoundation
import SherpaOnnxC

/// SenseVoiceSmall (FunAudioLLM, int8) running on device through sherpa-onnx. Free and offline;
/// far more accurate than SFSpeechRecognizer for Chinese, English, Japanese, Korean and Cantonese,
/// and it tells which of them is spoken from about a second of speech.
enum SenseVoiceModel {
    static let languages = ["zh", "en", "ja", "ko", "yue"]
    private static let files: [(name: String, size: Int64)] = [("model.int8.onnx", 239_233_841), ("tokens.txt", 315_894)]
    private static let remote = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/")!
    static let changed = Notification.Name("SenseVoiceModelChanged")

    static var downloadMB: Int { Int(files.reduce(0) { $0 + $1.size } / 1_000_000) }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("SenseVoice", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    static var modelPath: String { directory.appendingPathComponent(files[0].name).path }
    static var tokensPath: String { directory.appendingPathComponent(files[1].name).path }
    static var vadPath: String? { Bundle.main.path(forResource: "silero_vad", ofType: "onnx") }

    static var isDownloaded: Bool {
        files.allSatisfy { f in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.name).path)[.size] as? NSNumber)?.int64Value
            return size == f.size
        }
    }

    /// `locale` is "auto" or a recognizer locale such as "ja-JP".
    static func supports(_ locale: String) -> Bool { locale == "auto" || languages.contains(code(for: locale)) }
    static func code(for locale: String) -> String { locale.hasPrefix("yue") ? "yue" : String(locale.prefix(2)) }
    static func locale(for code: String) -> String? { ["zh": "zh-CN", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "yue": "yue-CN"][code] }

    // MARK: Download

    /// Fraction downloaded while a download runs, else nil. Main thread only.
    private(set) static var progress: Double?
    private static var downloader: ModelDownloader?
    private static var completions: [(Error?) -> Void] = []
    private static var progressHandlers: [(Double) -> Void] = []

    static var statusText: String {
        if let p = progress { return String(format: L("Downloading… %d%%"), Int(p * 100)) }
        return isDownloaded ? String(format: L("Downloaded · %d MB"), downloadMB) : L("Not Downloaded")
    }

    static func download(progress onProgress: ((Double) -> Void)? = nil, completion: ((Error?) -> Void)? = nil) {
        if let onProgress { progressHandlers.append(onProgress) }
        if let completion { completions.append(completion) }
        guard downloader == nil else { return }
        if isDownloaded { finish(nil); return }
        progress = 0
        NotificationCenter.default.post(name: changed, object: nil)
        let items = files.map { (remote.appendingPathComponent($0.name), directory.appendingPathComponent($0.name), $0.size) }
        let d = ModelDownloader(items: items) { p in
            let percent = Int(p * 100)
            guard percent != Int((progress ?? 0) * 100) else { return }
            progress = p
            progressHandlers.forEach { $0(p) }
            NotificationCenter.default.post(name: changed, object: nil)
        } finished: { error in
            finish(error)
        }
        downloader = d
        d.start()
    }

    static func cancel() {
        downloader?.cancel()
        finish(CancellationError())
    }

    static func delete() {
        SenseVoiceEngine.shared.unload()
        for f in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(f.name)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func finish(_ error: Error?) {
        downloader = nil
        progress = nil
        let done = completions
        completions = []
        progressHandlers = []
        done.forEach { $0(error) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Downloads files one after another, reporting overall progress on the main queue.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var items: [(remote: URL, local: URL, size: Int64)]
    private let total: Int64
    private var done: Int64 = 0
    private let onProgress: (Double) -> Void
    private var onFinish: ((Error?) -> Void)?
    private var session: URLSession?

    init(items: [(URL, URL, Int64)], progress: @escaping (Double) -> Void, finished: @escaping (Error?) -> Void) {
        self.items = items.map { (remote: $0.0, local: $0.1, size: $0.2) }
        total = max(items.reduce(0) { $0 + $1.2 }, 1)
        onProgress = progress
        onFinish = finished
    }

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        next()
    }

    func cancel() {
        onFinish = nil
        session?.invalidateAndCancel()
    }

    private func next() {
        // Files already complete from an earlier attempt are skipped.
        while let item = items.first, (try? FileManager.default.attributesOfItem(atPath: item.local.path)[.size] as? NSNumber)?.int64Value == item.size {
            done += item.size
            items.removeFirst()
        }
        guard let item = items.first else { finish(nil); return }
        session?.downloadTask(with: item.remote).resume()
    }

    private func finish(_ error: Error?) {
        guard let f = onFinish else { return }
        onFinish = nil
        session?.finishTasksAndInvalidate()
        f(error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(min(Double(done + totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = items.first else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { finish(URLError(.badServerResponse)); return }
        do {
            try? FileManager.default.removeItem(at: item.local)
            try FileManager.default.moveItem(at: location, to: item.local)
        } catch {
            finish(error)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: item.local.path)[.size] as? NSNumber)?.int64Value
        guard size == item.size else {
            try? FileManager.default.removeItem(at: item.local)
            finish(URLError(.cannotDecodeContentData))
            return
        }
        done += item.size
        items.removeFirst()
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}

// MARK: - Engine

/// Keeps C strings alive while a sherpa-onnx config is being read.
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func make(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        pointers.append(p)
        return UnsafePointer(p)
    }
    deinit { pointers.forEach { free($0) } }
}

/// One shared recognizer (the model takes ~250 MB of memory). All calls are serialized.
final class SenseVoiceEngine {
    static let shared = SenseVoiceEngine()

    struct Result {
        let text: String
        let language: String
    }

    private let lock = NSLock()
    private var recognizer: OpaquePointer?
    private var language = ""
    private var unloadWork: DispatchWorkItem?

    /// Loads the model for `language` ("auto" or a SenseVoice code). Slow; call off the main thread.
    func prepare(language: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load(language) != nil
    }

    func decode(_ samples: [Float], language: String) -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty, let r = load(language), let stream = SherpaOnnxCreateOfflineStream(r) else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(r, stream)
        guard let res = SherpaOnnxGetOfflineStreamResult(stream) else { return nil }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(res) }
        let text = res.pointee.text.map { String(cString: $0) } ?? ""
        let lang = res.pointee.lang.map { String(cString: $0) } ?? ""
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: lang.trimmingCharacters(in: CharacterSet(charactersIn: "<|> ")))
    }

    /// Frees the model a while after subtitles stop, unless they start again.
    func unloadSoon() {
        lock.lock(); defer { lock.unlock() }
        unloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unload() }
        unloadWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: work)
    }

    func unload() {
        lock.lock(); defer { lock.unlock() }
        if let r = recognizer { SherpaOnnxDestroyOfflineRecognizer(r) }
        recognizer = nil
    }

    private func load(_ language: String) -> OpaquePointer? {
        unloadWork?.cancel()
        unloadWork = nil
        if let r = recognizer, self.language == language { return r }
        if let r = recognizer { SherpaOnnxDestroyOfflineRecognizer(r) }
        recognizer = nil
        guard SenseVoiceModel.isDownloaded else { return nil }
        let s = CStrings()
        var c = SherpaOnnxOfflineRecognizerConfig()
        c.feat_config.sample_rate = 16000
        c.feat_config.feature_dim = 80
        c.model_config.sense_voice.model = s.make(SenseVoiceModel.modelPath)
        c.model_config.sense_voice.language = s.make(language)
        c.model_config.sense_voice.use_itn = 1
        c.model_config.tokens = s.make(SenseVoiceModel.tokensPath)
        c.model_config.num_threads = 2
        c.model_config.provider = s.make("cpu")
        c.decoding_method = s.make("greedy_search")
        recognizer = withExtendedLifetime(s) { SherpaOnnxCreateOfflineRecognizer(&c) }
        self.language = language
        return recognizer
    }
}

/// Silero voice activity detector (bundled, 640 KB): finds where utterances start and end.
private final class SileroVAD {
    static let window = 512
    private let vad: OpaquePointer

    init?(minSilence: Float, maxSpeech: Float) {
        guard let path = SenseVoiceModel.vadPath else { return nil }
        let s = CStrings()
        var c = SherpaOnnxVadModelConfig()
        c.silero_vad.model = s.make(path)
        c.silero_vad.threshold = 0.5
        c.silero_vad.min_silence_duration = minSilence
        c.silero_vad.min_speech_duration = 0.25
        c.silero_vad.window_size = Int32(Self.window)
        c.silero_vad.max_speech_duration = maxSpeech
        c.sample_rate = 16000
        c.num_threads = 1
        c.provider = s.make("cpu")
        guard let v = withExtendedLifetime(s, { SherpaOnnxCreateVoiceActivityDetector(&c, 60) }) else { return nil }
        vad = v
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    func accept(_ samples: UnsafePointer<Float>) { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(Self.window)) }
    var speechDetected: Bool { SherpaOnnxVoiceActivityDetectorDetected(vad) != 0 }

    /// The next finished utterance, if any.
    func popSegment() -> [Float]? {
        guard SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0, let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { return nil }
        defer {
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        guard let p = seg.pointee.samples, seg.pointee.n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(seg.pointee.n)))
    }
}

/// Converts any PCM to 16 kHz mono float and queues it for the worker.
final class MonoResampler: @unchecked Sendable {
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var pending: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard buffer.frameLength > 0 else { return }
        if source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            source = buffer.format
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
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        if pending.count > 16000 * 30 { pending.removeFirst(pending.count - 16000 * 30) }
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let p = pending
        pending = []
        return p
    }
}

// MARK: - Channel

/// Near-real-time captions from an offline model: the VAD cuts the audio into utterances; the one
/// in progress is re-decoded every 0.3 s (cheap: SenseVoice is non-autoregressive) and each
/// finished utterance is decoded once more as final text. With no language given it detects it.
final class SenseVoiceChannel: SpeechChannel {
    private(set) var locale: String
    let kind = SpeechEngineKind.senseVoice
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    /// The detected (or changed) spoken language, as a recognizer locale.
    var onLanguage: ((String) -> Void)?

    private let forced: String?
    private let input = MonoResampler()
    private let work = DispatchQueue(label: "fa.sensevoice", qos: .userInitiated)

    // Worker state, touched only on `work`.
    private var timer: DispatchSourceTimer?
    private var running = false
    private var cancelled = false
    private var vad: SileroVAD?
    private var buffer: [Float] = []
    private var vadOffset = 0
    private var speaking = false
    private var lastPartialAt: TimeInterval = 0
    private var lastPartialSamples = 0
    private var held: (text: String, end: Character?)?
    private var heldAt: TimeInterval = 0
    private var lowerNext = false
    private var language: String?
    private var votes: [String] = []

    // Main-thread state.
    private var finalText = ""
    private var partial = ""
    private var stopped = false

    init(locale: String?) {
        forced = locale.map(SenseVoiceModel.code)
        language = forced
        self.locale = locale ?? "auto"
    }

    var heard: String { partial.isEmpty ? finalText : finalText + " " + partial }
    var finalTranscript: String { finalText }
    var volatileTranscript: String { partial }
    var confidence: Double { -1 }

    func start() {
        let lang = forced ?? "auto"
        work.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.vad = SileroVAD(minSilence: 0.5, maxSpeech: 9)
            guard self.vad != nil, SenseVoiceEngine.shared.prepare(language: lang) else {
                DispatchQueue.main.async { self.fail(NSError(domain: "SenseVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Couldn't load the speech model.")])) }
                return
            }
            guard !self.cancelled else { return }
            let t = DispatchSource.makeTimerSource(queue: self.work)
            t.schedule(deadline: .now(), repeating: 0.1)
            t.setEventHandler { [weak self] in self?.step() }
            t.resume()
            self.timer = t
            self.running = true
        }
    }

    func stop() {
        stopped = true
        work.async { [self] in
            cancelled = true
            timer?.cancel()
            timer = nil
            running = false
        }
        SenseVoiceEngine.shared.unloadSoon()
    }

    func append(_ buffer: AVAudioPCMBuffer) { input.append(buffer) }

    func append(_ sample: CMSampleBuffer) {
        if let b = AudioPCM.buffer(from: sample) { input.append(b) }
    }

    func tick() {}

    // MARK: Worker

    private var decodeLanguage: String { forced ?? "auto" }

    private func step() {
        guard running, let vad else { return }
        let fresh = input.drain()
        if !fresh.isEmpty { buffer.append(contentsOf: fresh) }
        let now = ProcessInfo.processInfo.systemUptime
        let w = SileroVAD.window
        while vadOffset + w <= buffer.count {
            buffer.withUnsafeBufferPointer { vad.accept($0.baseAddress! + vadOffset) }
            vadOffset += w
            if !speaking, vad.speechDetected {
                speaking = true
                speechBegan()
                lastPartialAt = now - 0.25
            }
            while let segment = vad.popSegment() {
                buffer.removeFirst(vadOffset)
                vadOffset = 0
                speaking = vad.speechDetected
                lastPartialSamples = 0
                finished(segment)
            }
        }
        if !speaking, buffer.count > w * 10 {
            // Keep a short lead-in so the first syllable isn't clipped.
            let drop = buffer.count - w * 10
            buffer.removeFirst(drop)
            vadOffset = max(0, vadOffset - drop)
        }
        if speaking, now - lastPartialAt >= 0.3, buffer.count - lastPartialSamples >= 3200 {
            lastPartialAt = now
            lastPartialSamples = buffer.count
            if let r = SenseVoiceEngine.shared.decode(buffer, language: decodeLanguage) { inProgress(r, seconds: Double(buffer.count) / 16000) }
        }
        if held != nil, !speaking, now - heldAt >= 0.7 { releaseHeld(endsSentence: true) }
    }

    private func speechBegan() {
        // Speech resumed soon after the last utterance: it was a pause inside a sentence.
        if held != nil { releaseHeld(endsSentence: false) }
    }

    private func inProgress(_ r: SenseVoiceEngine.Result, seconds: Double) {
        if language == nil {
            guard seconds >= 1.0, SenseVoiceModel.languages.contains(r.language) else { return }
            setLanguage(r.language)
        }
        // The model closes every decode with a period; an utterance in progress isn't a sentence yet.
        var text = adjust(Self.clean(r.text))
        while let last = text.last, Self.enders.contains(last) { text.removeLast() }
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverPartial(text) }
    }

    private func finished(_ segment: [Float]) {
        let seconds = Double(segment.count) / 16000
        guard let r = SenseVoiceEngine.shared.decode(segment, language: decodeLanguage) else { return }
        if forced == nil, SenseVoiceModel.languages.contains(r.language), seconds >= 1.0 {
            if language == nil {
                setLanguage(r.language)
            } else if r.language != language {
                // Switch only when two utterances in a row agree, so one odd word doesn't flip it.
                votes.append(r.language)
                if votes.suffix(2).count == 2, Set(votes.suffix(2)).count == 1 { setLanguage(r.language) }
            } else {
                votes.removeAll()
            }
        }
        guard language != nil else { return }
        let text = adjust(Self.clean(r.text))
        if held != nil { releaseHeld(endsSentence: false) }
        lowerNext = false
        guard !text.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.deliverPartial("") }
            return
        }
        // Each utterance is decoded on its own, so the model ends every one with a period even
        // when the speaker only paused mid-sentence. Hold it until we know how long the pause is.
        var body = text
        var end: Character?
        if let last = body.last, Self.enders.contains(last) {
            end = last
            body.removeLast()
        }
        held = (body, end)
        heldAt = ProcessInfo.processInfo.systemUptime
        // A punctuated, self-contained utterance keeps its ending whatever follows: show it now.
        if end != nil, !Self.continues(body, language: language ?? "en") {
            releaseHeld(endsSentence: true)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.deliverPartial(body) }
    }

    private func releaseHeld(endsSentence: Bool) {
        guard let h = held else { return }
        held = nil
        let lang = language ?? "en"
        let out: String
        if endsSentence {
            out = h.text + String(h.end ?? (Self.cjk(lang) ? "。" : "."))
        } else if h.end == nil || Self.continues(h.text, language: lang) {
            // Cut mid-phrase (no punctuation, or it stops on a particle/article): carry on.
            out = h.text
            lowerNext = !Self.cjk(lang)
        } else {
            out = h.text + String(h.end!)
        }
        DispatchQueue.main.async { [weak self] in self?.deliverFinal(out) }
    }

    private static let jaParticles = ["は", "が", "を", "に", "で", "と", "も", "の", "へ", "や", "て", "から", "けど", "ので", "のに"]
    private static let zhOpen: Set<Character> = ["的", "和", "与", "跟", "在", "把", "被", "对", "从", "就", "是", "而", "但", "或"]
    private static let enOpen: Set<String> = ["a", "an", "the", "of", "to", "and", "or", "but", "with", "for", "in", "on", "at", "about", "from",
                                              "our", "your", "my", "his", "her", "their", "is", "are", "was", "were", "be", "that", "this",
                                              "so", "if", "because", "than", "as", "into", "very", "not", "we", "they", "i", "he", "she"]

    /// Whether an utterance obviously stops mid-sentence, so the period the model added is wrong.
    private static func continues(_ text: String, language: String) -> Bool {
        switch language {
        case "ja": return text.count < 4 || jaParticles.contains { text.hasSuffix($0) } || text.last.map("まっ".contains) == true
        case "zh", "yue": return text.count < 4 || text.last.map(zhOpen.contains) == true
        case "ko": return false
        default:
            let words = text.lowercased().split { !$0.isLetter && $0 != "'" }
            return words.count < 2 || words.last.map { enOpen.contains(String($0)) } == true
        }
    }

    /// After a soft join the next utterance continues the sentence: "…the story, So there's" → "so there's".
    private func adjust(_ text: String) -> String {
        guard lowerNext, let first = text.first, first.isUppercase else { return text }
        let word = text.prefix { $0.isLetter || $0 == "'" }
        guard word != "I", !word.hasPrefix("I'"), word.dropFirst().allSatisfy({ $0.isLowercase }) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func setLanguage(_ code: String) {
        language = code
        votes.removeAll()
        held = nil
        let loc = SenseVoiceModel.locale(for: code) ?? code
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.locale = loc
            self.finalText = ""
            self.partial = ""
            self.onLanguage?(loc)
        }
    }

    private static let enders: Set<Character> = [".", "。", "．", "?", "？", "!", "！"]
    private static func cjk(_ code: String) -> Bool { ["zh", "ja", "yue"].contains(code) }
    private static let cjkSpaces = try! NSRegularExpression(pattern: "(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}ー、。，])\\s+(?=[\\p{Han}\\p{Hiragana}\\p{Katakana}ー、。，])")

    /// Drops output with no letters at all (noise decoded as punctuation) and the stray spaces
    /// the model sometimes puts between Japanese/Chinese words.
    private static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return "" }
        if t.contains(" ") {
            t = cjkSpaces.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        return t
    }

    // MARK: Main thread

    private func deliverPartial(_ text: String) {
        guard !stopped, text != partial else { return }
        partial = text
        onPartial?(text)
    }

    private func deliverFinal(_ text: String) {
        guard !stopped else { return }
        partial = ""
        let cjk = SubtitleLanguages.isCJK(locale)
        finalText = Sentences.join(finalText, text, cjk: cjk)
        if finalText.count > 600 { finalText = String(finalText.suffix(400)) }
        onFinal?(text)
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        onFailure?(error)
    }
}
