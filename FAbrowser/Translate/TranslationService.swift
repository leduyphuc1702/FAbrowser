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
    @MainActor
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        let s = TranslateLanguages.normalize(source), t = TranslateLanguages.normalize(target)
        if s == t { return texts }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FAFakeTranslate") { return texts.map { "[\(t)] " + $0 } }
        #endif
        if #available(iOS 18.0, *) {
            return try await TranslationHostPool.shared.host(source: s, target: t).translate(texts)
        }
        throw TranslationError.unavailableOS
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

// MARK: - iOS 18 implementation

@available(iOS 18.0, *)
@MainActor
final class TranslationHostPool {
    static let shared = TranslationHostPool()
    private var hosts: [String: TranslationHost] = [:]

    func host(source: String, target: String) -> TranslationHost {
        let key = source + ">" + target
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
