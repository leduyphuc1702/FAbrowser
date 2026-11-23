import UIKit
import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

enum TranslationError: LocalizedError {
    case unavailableOS
    case unsupportedPair
    case sameLanguage
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableOS: return L("Offline translation requires iOS 18 or later.")
        case .unsupportedPair: return L("This language pair is not supported by offline translation.")
        case .sameLanguage: return L("The page is already in the target language.")
        case .notInstalled: return L("Language pack is not downloaded. Download it in Settings › Translate.")
        case .failed(let s): return s
        }
    }
}

/// Languages offered as targets/sources. Codes are BCP-47 identifiers understood by Locale.Language.
enum TranslateLanguages {
    static let all: [(code: String, name: String)] = [
        ("vi", "Tiếng Việt"), ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"),
        ("ko", "한국어"), ("th", "ไทย"), ("id", "Bahasa Indonesia"), ("fr", "Français"), ("de", "Deutsch"),
        ("es", "Español"), ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский"), ("uk", "Українська"),
        ("pl", "Polski"), ("nl", "Nederlands"), ("tr", "Türkçe"), ("ar", "العربية"), ("hi", "हिन्दी"),
    ]

    static func name(_ code: String?) -> String {
        guard let code else { return "?" }
        if let n = all.first(where: { $0.code == normalize(code) })?.name { return n }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Language name in the app's UI language ("tiếng Anh" rather than "English").
    static func localizedName(_ code: String) -> String {
        let ui = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return ui.localizedString(forIdentifier: normalize(code)) ?? name(code)
    }

    /// Maps legacy / recognizer codes ("zh-CN", "zh", "en-US") to our identifiers.
    static func normalize(_ code: String) -> String {
        let c = code.replacingOccurrences(of: "_", with: "-")
        switch c.lowercased() {
        case "zh-cn", "zh-sg", "zh", "zh-hans": return "zh-Hans"
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant": return "zh-Hant"
        default:
            let base = c.split(separator: "-").first.map(String.init) ?? c
            return base.lowercased()
        }
    }

    /// Detects the dominant language of a text sample.
    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(4000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        return normalize(lang.rawValue)
    }

    static func detect(_ text: String, confidenceFor code: String) -> Double {
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyp = r.languageHypotheses(withMaximum: 5)
        return hyp.first { normalize($0.key.rawValue) == normalize(code) }?.value ?? 0
    }
}

/// Entry point used by page translation and live subtitles.
final class TranslationService {
    static let shared = TranslationService()

    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Translates texts in order. Throws `TranslationError`.
    /// Cached strings are answered immediately; the rest is de-duplicated and, for larger
    /// batches, split across two translation sessions that run in parallel.
    @MainActor
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        let s = TranslateLanguages.normalize(source), t = TranslateLanguages.normalize(target)
        if s == t { return texts }
        let cache = TranslationCache.shared
        let pair = s + ">" + t
        var out = texts
        var missing: [String] = []
        var seen = Set<String>()
        for (i, x) in texts.enumerated() {
            if let c = cache.get(x, pair: pair) { out[i] = c } else if seen.insert(x).inserted { missing.append(x) }
        }
        guard !missing.isEmpty else { return out }
        let translated = try await translateUncached(missing, s, t)
        var map: [String: String] = [:]
        for (k, x) in missing.enumerated() where k < translated.count {
            map[x] = translated[k]
            cache.set(translated[k], for: x, pair: pair)
        }
        for (i, x) in texts.enumerated() { if let m = map[x] { out[i] = m } }
        return out
    }

    @MainActor
    private func translateUncached(_ texts: [String], _ s: String, _ t: String) async throws -> [String] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FAFakeTranslate") { return texts.map { "[\(t)] " + $0 } }
        #endif
        if #available(iOS 18.0, *) {
            let pool = TranslationHostPool.shared
            guard texts.count >= 16 else { return try await pool.host(source: s, target: t).translate(texts) }
            let mid = texts.count / 2
            async let a = pool.host(source: s, target: t, slot: 0).translate(Array(texts[..<mid]))
            async let b = pool.host(source: s, target: t, slot: 1).translate(Array(texts[mid...]))
            return try await a + b
        }
        throw TranslationError.unavailableOS
    }

    /// Starts the translation sessions for a pair ahead of time so the first batch doesn't
    /// pay for loading the model.
    @MainActor
    func warmUp(from source: String, to target: String, sample: String) {
        let s = TranslateLanguages.normalize(source), t = TranslateLanguages.normalize(target)
        guard s != t, #available(iOS 18.0, *) else { return }
        let pool = TranslationHostPool.shared
        let text = String(sample.prefix(120))
        Task { @MainActor in
            // Only when the pack is installed: otherwise the session would show the download sheet.
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "FAFakeTranslate") { return }
            #endif
            guard await self.status(from: s, to: t) == .installed else { return }
            _ = try? await pool.host(source: s, target: t, slot: 0).translate([text])
            _ = try? await pool.host(source: s, target: t, slot: 1).translate([text])
        }
    }

    enum PackStatus { case installed, downloadable, unsupported, unavailableOS }

    func status(from source: String, to target: String) async -> PackStatus {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FAFakeTranslate") { return .installed }
        #endif
        if #available(iOS 18.0, *) {
            let a = LanguageAvailability()
            let st = await a.status(from: Locale.Language(identifier: TranslateLanguages.normalize(source)),
                                    to: Locale.Language(identifier: TranslateLanguages.normalize(target)))
            switch st {
            case .installed: return .installed
            case .supported: return .downloadable
            default: return .unsupported
            }
        }
        return .unavailableOS
    }

    /// Shows the system download prompt for a language pair, hosted on `presenter`.
    @MainActor
    func prepare(from source: String, to target: String, presenter: UIViewController) async throws {
        if #available(iOS 18.0, *) {
            let host = TranslationHost(source: TranslateLanguages.normalize(source), target: TranslateLanguages.normalize(target))
            host.attach(to: presenter)
            defer { host.detach() }
            try await host.prepare()
            return
        }
        throw TranslationError.unavailableOS
    }
}

// MARK: - Cache

/// Translated strings per language pair, kept in memory and on disk, so revisited pages and
/// text repeated across a site (menus, headers, footers) are applied without running the model.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()
    private static let maxEntries = 40_000
    private var pairs: [String: [String: String]] = [:]
    private var dirty = Set<String>()
    private var saveScheduled = false
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("translations", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ pair: String) -> URL {
        dir.appendingPathComponent(pair.replacingOccurrences(of: ">", with: "_") + ".json")
    }

    private func table(_ pair: String) -> [String: String] {
        if let t = pairs[pair] { return t }
        let t = (try? Data(contentsOf: file(pair))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        pairs[pair] = t
        return t
    }

    func get(_ text: String, pair: String) -> String? { table(pair)[text] }

    func set(_ translation: String, for text: String, pair: String) {
        guard text.count <= 4000, translation != text || text.count < 40 else { return }
        var t = table(pair)
        if t.count >= TranslationCache.maxEntries { t = Dictionary(uniqueKeysWithValues: t.shuffled().prefix(TranslationCache.maxEntries / 2).map { ($0.key, $0.value) }) }
        t[text] = translation
        pairs[pair] = t
        dirty.insert(pair)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let jobs = self.dirty.map { (self.file($0), self.pairs[$0] ?? [:]) }
            self.dirty.removeAll()
            DispatchQueue.global(qos: .utility).async {
                for (url, t) in jobs { if let d = try? JSONEncoder().encode(t) { try? d.write(to: url, options: .atomic) } }
            }
        }
    }

    func clear() {
        pairs.removeAll()
        dirty.removeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - iOS 18 implementation

@available(iOS 18.0, *)
@MainActor
final class TranslationHostPool {
    static let shared = TranslationHostPool()
    private var hosts: [String: TranslationHost] = [:]

    func host(source: String, target: String, slot: Int = 0) -> TranslationHost {
        let key = source + ">" + target + "#\(slot)"
        if let h = hosts[key], h.isAlive { return h }
        let h = TranslationHost(source: source, target: target)
        if let root = UIApplication.shared.keyWindowCompat?.rootViewController { h.attach(to: root) }
        hosts[key] = h
        return h
    }
}

/// Keeps a `TranslationSession` alive inside an invisible SwiftUI view and feeds it jobs.
/// The session is only valid inside `.translationTask`, so the task loops over a job stream.
@available(iOS 18.0, *)
@MainActor
final class TranslationHost {
    enum Job {
        case translate([String], CheckedContinuation<[String], Error>)
        case prepare(CheckedContinuation<Void, Error>)
    }

    let source: String
    let target: String
    private let stream: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation
    private var hosting: UIHostingController<TranslationHostView>?
    private(set) var isAlive = true

    init(source: String, target: String) {
        self.source = source
        self.target = target
        var c: AsyncStream<Job>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    func attach(to vc: UIViewController) {
        let config = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        let view = TranslationHostView(config: config, stream: stream) { [weak self] in self?.isAlive = false }
        let h = UIHostingController(rootView: view)
        h.view.backgroundColor = .clear
        h.view.isUserInteractionEnabled = false
        h.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        h.view.alpha = 0.02
        vc.addChild(h)
        vc.view.addSubview(h.view)
        h.didMove(toParent: vc)
        hosting = h
    }

    func detach() {
        continuation.finish()
        hosting?.willMove(toParent: nil)
        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()
        hosting = nil
        isAlive = false
    }

    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { c in continuation.yield(.translate(texts, c)) }
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in continuation.yield(.prepare(c)) }
    }
}

@available(iOS 18.0, *)
struct TranslationHostView: View {
    let config: TranslationSession.Configuration
    let stream: AsyncStream<TranslationHost.Job>
    let onEnd: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                for await job in stream {
                    switch job {
                    case .translate(let texts, let cont):
                        do {
                            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                            let responses = try await session.translations(from: requests)
                            var out = texts
                            for r in responses {
                                if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
                            }
                            cont.resume(returning: out)
                        } catch {
                            cont.resume(throwing: TranslationHostView.map(error))
                        }
                    case .prepare(let cont):
                        do {
                            try await session.prepareTranslation()
                            cont.resume()
                        } catch {
                            cont.resume(throwing: TranslationHostView.map(error))
                        }
                    }
                }
                onEnd()
            }
    }

    static func map(_ error: Error) -> Error {
        if TranslationError.self == type(of: error) { return error }
        let text = String(describing: error).lowercased()
        if text.contains("unsupported") { return TranslationError.unsupportedPair }
        if text.contains("notinstalled") || text.contains("not installed") || text.contains("download") { return TranslationError.notInstalled }
        return TranslationError.failed(error.localizedDescription)
    }
}
