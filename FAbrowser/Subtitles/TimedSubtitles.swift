import Foundation
import AVFoundation

/// A sentence placed on the video's timeline, cut into caption-sized parts.
struct TimedSentence {
    struct Part {
        var text: String
        var start: Double
        var end: Double
    }
    let locale: String
    let text: String
    let parts: [Part]
    var start: Double { parts.first?.start ?? 0 }
    var end: Double { parts.last?.end ?? 0 }
}

/// Subtitles prepared ahead of playback from audio that is already downloaded (HLS through the
/// proxy). Every utterance is recognized before it is heard, so a sentence is judged by what
/// follows it: pieces split by pauses are joined back, a short reply stays with its neighbour so it
/// is translated in context, and each caption carries the time it is spoken (the model's token
/// times, else the voice detector's bounds).
final class TimedSenseVoice: SpeechChannel {
    private(set) var locale: String
    let kind = SpeechEngineKind.senseVoice
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onLanguage: ((String) -> Void)?
    /// Each finished sentence, on the main queue.
    var onSentence: ((TimedSentence) -> Void)?

    var finalTranscript: String { "" }
    var volatileTranscript: String { "" }
    var heard: String { "" }
    var confidence: Double { -1 }

    struct Piece {
        /// What follows the text: a comma, a sentence end, or the end of an utterance, where the
        /// model's full stop may or may not be a real one.
        enum Boundary { case comma, end(Character), soft(Character?) }
        var text: String
        var start: Double
        var end: Double
        var boundary: Boundary
    }

    private struct Draft {
        var language: String
        var pieces: [Piece]
        var start: Double { pieces[0].start }
        var end: Double { pieces[pieces.count - 1].end }
        var tail: Piece.Boundary { pieces[pieces.count - 1].boundary }
        var text: String { pieces.map(\.text).joined() }
        var length: Int { pieces.reduce(0) { $0 + $1.text.count } }
    }

    private static let rate = 16000.0
    static let commas: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
    private let forced: String?
    private let resampler = MonoResampler()
    private let work = DispatchQueue(label: "fa.sensevoice.timed", qos: .userInitiated)
    private let coverLock = NSLock()
    private var covered: [ClosedRange<Double>] = []

    // Worker state, touched only on `work`.
    private var ready = false
    private var cancelled = false
    private var queued: [(start: Double, samples: [Float])] = []
    private var vad: SileroVAD?
    private var origin = 0.0
    private var rangeStart = 0.0
    private var expected = -1.0
    private var accepted = 0
    private var startedInSpeech: Bool?
    private var firstEnd: Double?
    private var solidEnd: Double?
    private var carry: [Float] = []
    private var draft: Draft?
    private var language: String?
    private var votes: [String] = []

    // Main-thread state.
    private var stopped = false

    init(locale: String?) {
        forced = locale.map(SenseVoiceModel.code)
        language = forced
        self.locale = locale ?? "auto"
    }

    func start() {
        let lang = forced ?? "auto"
        work.async { [weak self] in
            guard let self, !self.cancelled else { return }
            guard SenseVoiceModel.vadPath != nil, SenseVoiceEngine.shared.prepare(language: lang) else {
                DispatchQueue.main.async { self.fail(NSError(domain: "SenseVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Couldn't load the speech model.")])) }
                return
            }
            guard !self.cancelled else { return }
            self.ready = true
            let waiting = self.queued
            self.queued = []
            waiting.forEach { self.ingest($0.samples, at: $0.start) }
        }
    }

    func stop() {
        stopped = true
        work.async { [self] in
            cancelled = true
            vad = nil
            queued = []
        }
        SenseVoiceEngine.shared.unloadSoon()
    }

    func append(_ buffer: AVAudioPCMBuffer) {}
    func append(_ sample: CMSampleBuffer) {}
    func tick() {}

    /// Audio found at `start` seconds into the stream. Any thread.
    func feed(_ buffer: AVAudioPCMBuffer, at start: Double) {
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        work.async { [weak self] in self?.ingest(samples, at: start) }
    }

    /// No audio follows (end of the video): close the last sentence.
    func finish() {
        work.async { [weak self] in
            guard let self, self.ready, !self.cancelled else { return }
            self.flushStream()
            self.emitDraft()
        }
    }

    /// Where already-processed audio running through `t` ends. Any thread.
    func coveredEnd(at t: Double) -> Double? {
        coverLock.lock(); defer { coverLock.unlock() }
        return covered.first { $0.lowerBound <= t + 0.05 && $0.upperBound >= t }?.upperBound
    }

    // MARK: Worker

    private func ingest(_ input: [Float], at start: Double) {
        guard !cancelled else { return }
        guard ready else { queued.append((start, input)); return }
        var samples = input
        if vad == nil || expected < 0 || start < expected - 0.5 || start > expected + 0.3 {
            restart(at: start)
        } else if start < expected {
            let skip = Int((expected - start) * Self.rate)
            guard skip < samples.count else { return }
            samples.removeFirst(skip)
        } else if start > expected + 0.01 {
            // Segments decoded one by one can lose a few milliseconds at their edges (fMP4 priming):
            // bridge with silence rather than cutting the utterance there.
            samples.insert(contentsOf: [Float](repeating: 0, count: Int((start - expected) * Self.rate)), at: 0)
        }
        guard let vad else { return }
        expected += Double(samples.count) / Self.rate
        carry.append(contentsOf: samples)
        let w = SileroVAD.window
        var i = 0
        carry.withUnsafeBufferPointer { p in
            while i + w <= p.count {
                vad.accept(p.baseAddress! + i)
                i += w
                accepted += w
                if startedInSpeech == nil, vad.speechDetected {
                    startedInSpeech = Double(accepted) / Self.rate < 0.6
                }
            }
        }
        carry.removeFirst(i)
        drainSegments(flushing: false)
        // Processed for good: from the first utterance's end when the run began mid-speech (a seek
        // may have cut it), up to the last utterance that ended on its own.
        let lower = startedInSpeech == true ? firstEnd : rangeStart
        let upper = vad.speechDetected ? solidEnd : expected
        if let lower, let upper, upper > lower { cover(lower...upper) }
        // Nothing has been said for a while after the open sentence: it has ended.
        if let d = draft, !vad.speechDetected, expected - d.end > 1.5 { emitDraft() }
    }

    /// Audio that doesn't continue what came before (a seek): finish the old run, start a new one.
    private func restart(at t: Double) {
        flushStream()
        emitDraft()
        vad = SileroVAD(minSilence: 0.4, maxSpeech: 14)
        origin = t
        rangeStart = t
        expected = t
        accepted = 0
        startedInSpeech = nil
        firstEnd = nil
        solidEnd = nil
        carry = []
    }

    private func flushStream() {
        guard let vad else { return }
        vad.flush()
        drainSegments(flushing: true)
    }

    private func drainSegments(flushing: Bool) {
        guard let vad else { return }
        while let seg = vad.popTimedSegment() {
            guard !seg.samples.isEmpty else { continue }
            let start = origin + Double(seg.start) / Self.rate
            let end = start + Double(seg.samples.count) / Self.rate
            if firstEnd == nil { firstEnd = end }
            if !flushing { solidEnd = end }
            recognize(seg.samples, at: start)
        }
    }

    private func cover(_ r: ClosedRange<Double>) {
        coverLock.lock(); defer { coverLock.unlock() }
        var merged = r
        covered.removeAll { other in
            guard other.lowerBound <= merged.upperBound + 0.05, other.upperBound >= merged.lowerBound - 0.05 else { return false }
            merged = min(other.lowerBound, merged.lowerBound)...max(other.upperBound, merged.upperBound)
            return true
        }
        covered.append(merged)
    }

    private func recognize(_ samples: [Float], at t0: Double) {
        let duration = Double(samples.count) / Self.rate
        guard let r = SenseVoiceEngine.shared.decode(samples, language: forced ?? "auto") else { return }
        if forced == nil, SenseVoiceModel.languages.contains(r.language), duration >= 1.0 {
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
        guard let lang = language ?? (SenseVoiceModel.languages.contains(r.language) ? r.language : nil) else { return }
        #if DEBUG
        NSLog("[subs] utterance %.2f-%.2f tokens=%d %@", t0, t0 + duration, r.tokens.count, r.text)
        #endif
        Self.pieces(r, at: t0, duration: duration).forEach { add($0, language: lang) }
    }

    private func setLanguage(_ code: String) {
        language = code
        votes.removeAll()
        let loc = SenseVoiceModel.locale(for: code) ?? code
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.locale = loc
            self.onLanguage?(loc)
        }
    }

    // MARK: Pieces

    /// Splits one decoded utterance at its punctuation, timing each piece by its tokens.
    static func pieces(_ r: SenseVoiceEngine.Result, at t0: Double, duration: Double) -> [Piece] {
        let segEnd = t0 + duration
        var raw: [Piece] = []
        let tokens = r.tokens.filter { !$0.text.hasPrefix("<|") }
        if !tokens.isEmpty {
            func mark(_ s: String) -> Character? {
                let t = s.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
                guard t.count == 1, let c = t.first, SenseVoiceChannel.enders.contains(c) || commas.contains(c) else { return nil }
                return c
            }
            var text = ""
            var start: Double?
            var lastWord = t0
            for (k, tok) in tokens.enumerated() {
                let piece = tok.text.replacingOccurrences(of: "▁", with: " ")
                let time = t0 + tok.time
                guard let m = mark(tok.text) else {
                    if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                        if start == nil { start = time }
                        lastWord = time
                    }
                    text += piece
                    continue
                }
                text += String(m)
                guard let s = start else {
                    // A stray mark with no words before it belongs to the previous piece.
                    if var last = raw.popLast() { last.text += String(m); raw.append(last) }
                    text = ""
                    continue
                }
                let next = tokens[(k + 1)...].first { mark($0.text) == nil }.map { t0 + $0.time } ?? segEnd
                let end = min(lastWord + 0.35, next, segEnd)
                raw.append(Piece(text: text, start: s, end: max(end, s + 0.2), boundary: SenseVoiceChannel.enders.contains(m) ? .end(m) : .comma))
                text = ""
                start = nil
            }
            if let s = start { raw.append(Piece(text: text, start: s, end: max(min(segEnd, lastWord + 0.5), s + 0.2), boundary: .soft(nil))) }
        } else {
            raw = proportional(r.text, from: t0, to: segEnd)
        }
        var out: [Piece] = []
        for var p in raw {
            p.text = SenseVoiceChannel.clean(p.text)
            if !p.text.isEmpty { out.append(p) }
        }
        guard var last = out.popLast() else { return [] }
        // The model ends every decode with a full stop, whether or not the sentence ended there.
        switch last.boundary {
        case .end(let c):
            if last.text.last == c { last.text.removeLast() }
            last.boundary = .soft(c)
        case .comma:
            if let c = last.text.last, commas.contains(c) { last.text.removeLast() }
            last.boundary = .soft(nil)
        case .soft:
            break
        }
        last.text = last.text.trimmingCharacters(in: .whitespaces)
        if !last.text.isEmpty { out.append(last) }
        return out
    }

    /// Without token times: pieces timed by their share of the characters.
    private static func proportional(_ text: String, from t0: Double, to t1: Double) -> [Piece] {
        var parts: [(String, Piece.Boundary)] = []
        var cur = ""
        for c in text {
            cur.append(c)
            if SenseVoiceChannel.enders.contains(c) { parts.append((cur, .end(c))); cur = "" }
            else if commas.contains(c) { parts.append((cur, .comma)); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append((cur, .soft(nil))) }
        let total = Double(max(1, parts.reduce(0) { $0 + $1.0.count }))
        var t = t0
        return parts.map { s, b in
            let d = (t1 - t0) * Double(s.count) / total
            defer { t += d }
            return Piece(text: s, start: t, end: t + d, boundary: b)
        }
    }

    // MARK: Sentences

    private func add(_ piece: Piece, language lang: String) {
        guard var d = draft, d.language == lang else {
            emitDraft()
            draft = Draft(language: lang, pieces: [piece])
            return
        }
        let cjk = SenseVoiceChannel.cjk(lang)
        let gap = piece.start - d.end
        let fits = d.length + piece.text.count <= (cjk ? 56 : 170) && piece.end - d.start <= 12
        var next = piece
        var join = false
        let last = d.pieces.count - 1
        switch d.tail {
        case .comma:
            join = fits && gap < 1.5
        case .end:
            join = fits && gap < 0.6 && Self.keepTogether(d.text, piece.text, cjk: cjk)
        case .soft(let c):
            if let c, "?？!！".contains(c) {
                join = fits && gap < 0.6 && Self.keepTogether(d.text, piece.text, cjk: cjk)
                if join { d.pieces[last].text += String(c); d.pieces[last].boundary = .end(c) }
            } else if fits, gap < 1.5, c == nil || Self.endsOpen(d.text, language: lang) {
                // Cut mid-phrase (no full stop, or it stops on a particle/article): carry on.
                join = true
                d.pieces[last].boundary = .comma
                next.text = Self.lowered(next.text, cjk: cjk)
            } else if fits, gap < 0.6 {
                // A short pause inside a sentence: the model's full stop becomes a comma.
                join = true
                d.pieces[last].text += cjk ? "，" : ","
                d.pieces[last].boundary = .comma
                next.text = Self.lowered(next.text, cjk: cjk)
            }
        }
        if join {
            if !cjk { next.text = " " + next.text }
            d.pieces.append(next)
            draft = d
        } else {
            emitDraft()
            draft = Draft(language: lang, pieces: [piece])
        }
    }

    /// A short reply ("Yes." "对。") is captioned and translated together with its neighbour.
    private static func keepTogether(_ a: String, _ b: String, cjk: Bool) -> Bool {
        func short(_ s: String) -> Bool { cjk ? s.count <= 6 : s.split(separator: " ").count <= 3 }
        return (short(a) || short(b)) && a.count + b.count <= (cjk ? 20 : 64)
    }

    private static func endsOpen(_ text: String, language: String) -> Bool {
        switch language {
        case "ja": return SenseVoiceChannel.jaParticles.contains { text.hasSuffix($0) }
        case "zh", "yue": return text.last.map(SenseVoiceChannel.zhOpen.contains) == true
        case "ko": return false
        default:
            return text.lowercased().split { !$0.isLetter && $0 != "'" }.last.map { SenseVoiceChannel.enOpen.contains(String($0)) } == true
        }
    }

    /// "…the story, So there's" → "so there's".
    private static func lowered(_ text: String, cjk: Bool) -> String {
        guard !cjk, let first = text.first, first.isUppercase else { return text }
        let word = text.prefix { $0.isLetter || $0 == "'" }
        guard word != "I", !word.hasPrefix("I'"), word.dropFirst().allSatisfy({ $0.isLowercase }) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func emitDraft() {
        guard var d = draft else { return }
        draft = nil
        let cjk = SenseVoiceChannel.cjk(d.language)
        let last = d.pieces.count - 1
        if case .soft(let c) = d.tail {
            if let l = d.pieces[last].text.last, Self.commas.contains(l) { d.pieces[last].text.removeLast() }
            d.pieces[last].text += String(c ?? (cjk ? "。" : "."))
        }
        let parts = Self.parts(d.pieces, cjk: cjk)
        guard !parts.isEmpty else { return }
        let sentence = TimedSentence(locale: SenseVoiceModel.locale(for: d.language) ?? d.language, text: d.text.trimmingCharacters(in: .whitespaces), parts: parts)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onSentence?(sentence)
        }
    }

    /// Groups pieces into captions short enough to read at a glance.
    static func parts(_ pieces: [Piece], cjk: Bool) -> [TimedSentence.Part] {
        let limit = cjk ? 22 : 72
        var out: [TimedSentence.Part] = []
        for p in pieces.flatMap({ split($0, limit: limit, cjk: cjk) }) {
            let text = p.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.text.count + text.count <= limit, p.end - last.start <= 6.5 {
                last.text += (cjk ? "" : " ") + text
                last.end = p.end
                out[out.count - 1] = last
            } else {
                out.append(TimedSentence.Part(text: text, start: p.start, end: p.end))
            }
        }
        return out
    }

    /// Cuts a piece longer than a caption into even chunks (at spaces for spaced languages), timed proportionally.
    private static func split(_ p: Piece, limit: Int, cjk: Bool) -> [Piece] {
        let chars = Array(p.text)
        guard chars.count > limit + limit / 3 else { return [p] }
        let n = Int((Double(chars.count) / Double(limit)).rounded(.up))
        var cuts = Set([0, chars.count])
        for k in 1..<n {
            var i = chars.count * k / n
            if !cjk, let j = (max(1, i - 15)..<min(chars.count, i + 15)).filter({ chars[$0] == " " }).min(by: { abs($0 - i) < abs($1 - i) }) { i = j }
            cuts.insert(i)
        }
        let sorted = cuts.sorted()
        let d = p.end - p.start
        var out: [Piece] = []
        for k in 0..<(sorted.count - 1) {
            let a = sorted[k], b = sorted[k + 1]
            let text = String(chars[a..<b]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(Piece(text: text, start: p.start + d * Double(a) / Double(chars.count), end: p.start + d * Double(b) / Double(chars.count), boundary: .comma))
        }
        return out
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        onFailure?(error)
    }
}

// MARK: - Timeline

/// Sentences on the video timeline and the caption due at a given moment. Main thread.
final class CueTimeline {
    struct Entry {
        let sentence: TimedSentence
        /// The whole sentence's translation shared out over its parts.
        var translated: [String]?
        var target: String?
        var failed = false
    }

    struct Cue: Equatable {
        let entry: Int
        let part: Int
        let start: Double
        let end: Double
    }

    private(set) var entries: [Int: Entry] = [:]
    private var cues: [Cue] = []
    private var nextID = 0

    var isEmpty: Bool { entries.isEmpty }

    func removeAll() {
        entries = [:]
        cues = []
    }

    /// Adds a sentence where the video has none yet. Where it overlaps others (audio read twice
    /// around a seek), the longest wins: a sentence cut short by the seek gives way to the whole one.
    @discardableResult
    func add(_ s: TimedSentence) -> Int? {
        let overlapping = entries.filter { _, e in
            let overlap = min(e.sentence.end, s.end) - max(e.sentence.start, s.start)
            return overlap > 0.5 * max(0.1, min(s.end - s.start, e.sentence.end - e.sentence.start))
        }
        let length = s.end - s.start
        guard !overlapping.contains(where: { $0.value.sentence.end - $0.value.sentence.start >= length - 0.05 }) else { return nil }
        for id in overlapping.keys { entries[id] = nil }
        if !overlapping.isEmpty { cues.removeAll { overlapping[$0.entry] != nil } }
        let id = nextID
        nextID += 1
        entries[id] = Entry(sentence: s)
        for (k, p) in s.parts.enumerated() { cues.append(Cue(entry: id, part: k, start: p.start, end: p.end)) }
        cues.sort { $0.start < $1.start }
        return id
    }

    /// The caption showing at `t`: up a moment before it is spoken, held long enough to read,
    /// and never over the next one.
    func cue(at t: Double) -> Cue? {
        guard let i = cues.lastIndex(where: { $0.start - 0.12 <= t }) else { return nil }
        let c = cues[i]
        let text = entries[c.entry]?.sentence.parts[c.part].text ?? ""
        var until = max(c.end + 0.35, c.start + min(SubtitleOverlayView.readingTime(text) * 0.55, 3.5))
        if i + 1 < cues.count { until = min(until, max(c.end, cues[i + 1].start - 0.12)) }
        return t < until ? c : nil
    }

    func texts(for c: Cue, target: String) -> (original: String, translated: String?, locale: String)? {
        guard let e = entries[c.entry], c.part < e.sentence.parts.count else { return nil }
        let tr = e.target == target ? e.translated.flatMap { c.part < $0.count ? $0[c.part] : nil } : nil
        return (e.sentence.parts[c.part].text, tr, e.sentence.locale)
    }

    /// Sentences still to translate into `target`: what's on screen or coming up first, then the
    /// most recent ones behind (for seeking back).
    func untranslated(target: String, near t: Double, limit: Int, needs: (String) -> Bool) -> [Int] {
        let open = entries.filter { $0.value.target != target && !$0.value.failed && needs($0.value.sentence.locale) }
        let ahead = open.filter { $0.value.sentence.end >= t - 1 }.sorted { $0.value.sentence.start < $1.value.sentence.start }
        let behind = open.filter { $0.value.sentence.end < t - 1 }.sorted { $0.value.sentence.start > $1.value.sentence.start }
        return (ahead + behind).prefix(limit).map(\.key)
    }

    func setTranslation(_ id: Int, _ text: String, target: String, cjk: Bool) {
        guard var e = entries[id] else { return }
        e.translated = Self.distribute(text, over: e.sentence.parts.map(\.text), cjk: cjk)
        e.target = target
        e.failed = false
        entries[id] = e
    }

    func markFailed(_ id: Int) { entries[id]?.failed = true }

    func clearFailures() {
        for id in entries.keys { entries[id]?.failed = false }
    }

    /// A sentence translated whole, shared out over its caption parts: kept whole while short
    /// enough for one caption, else cut near where the original divides.
    static func distribute(_ text: String, over parts: [String], cjk: Bool) -> [String] {
        let n = parts.count
        guard n > 1, text.count > (cjk ? 36 : 100) else { return Array(repeating: text, count: n) }
        let chars = Array(text)
        let total = Double(max(1, parts.reduce(0) { $0 + $1.count }))
        var cuts = [0]
        var acc = 0.0
        for k in 0..<(n - 1) {
            acc += Double(parts[k].count)
            cuts.append(cut(chars, near: Int(Double(chars.count) * acc / total), after: cuts[cuts.count - 1], cjk: cjk))
        }
        cuts.append(chars.count)
        let out = (0..<n).map { String(chars[cuts[$0]..<max(cuts[$0], cuts[$0 + 1])]).trimmingCharacters(in: .whitespaces) }
        return out.contains(where: \.isEmpty) ? Array(repeating: text, count: n) : out
    }

    private static func cut(_ c: [Character], near i: Int, after lo: Int, cjk: Bool) -> Int {
        let window = cjk ? 6 : 18
        let a = max(lo + 1, i - window), b = min(c.count - 1, i + window)
        guard a <= b else { return min(max(i, lo), c.count) }
        let marks: Set<Character> = [",", "，", "、", ";", "；", ".", "。", "!", "?", "！", "？", ":", "："]
        if let j = (a...b).filter({ marks.contains(c[$0 - 1]) }).min(by: { abs($0 - i) < abs($1 - i) }) { return j }
        if !cjk, let j = (a...b).filter({ c[$0] == " " }).min(by: { abs($0 - i) < abs($1 - i) }) { return j }
        return min(max(i, a), b)
    }
}
