import Foundation

struct JSExtension: Codable, Equatable {
    enum RunAt: Int, Codable, CaseIterable {
        case veryBeginning, domContentLoaded
        var title: String { self == .veryBeginning ? L("Very Beginning") : "DOMContentLoaded" }
    }

    var id = UUID()
    var name: String
    var author: String = ""
    var summary: String = ""
    var code: String
    /// Multiple values separated by "@@". "*" matches all, "/regex/" is a regular expression,
    /// anything else matches when the host ends with it or the URL contains it.
    var matches: String = "*"
    var runAt: RunAt = .domContentLoaded
    /// Active extensions run only when the user taps them in the menu; passive ones auto-inject.
    var isActive: Bool = false
    var enabled: Bool = true

    var matchList: [String] {
        matches.components(separatedBy: "@@").map { $0.trimmed }.filter { !$0.isEmpty }
    }

    func matches(url: URL?) -> Bool {
        guard let url else { return false }
        let href = url.absoluteString
        let host = url.host?.lowercased() ?? ""
        for m in matchList {
            if m == "*" { return true }
            if m.count > 2, m.hasPrefix("/"), m.hasSuffix("/") {
                let pattern = String(m.dropFirst().dropLast())
                if href.range(of: pattern, options: .regularExpression) != nil { return true }
            } else if host == m.lowercased() || host.hasSuffix("." + m.lowercased()) || href.contains(m) {
                return true
            }
        }
        return false
    }
}

final class JSExtensionStore {
    static let shared = JSExtensionStore()
    private let file = "js_extensions.json"
    private(set) var extensions: [JSExtension]

    private init() {
        extensions = JSONStore.load([JSExtension].self, from: file) ?? JSExtensionStore.samples
    }

    static let samples: [JSExtension] = [
        JSExtension(name: "Video 2x Speed", author: "FAbrowser", summary: "Play all videos on the page at 2x.",
                    code: "document.querySelectorAll('video').forEach(function(v){v.playbackRate=2.0});", matches: "*", runAt: .domContentLoaded, isActive: true),
        JSExtension(name: "Allow Copy & Select", author: "FAbrowser", summary: "Re-enable text selection and right click on restrictive sites.",
                    code: """
                    (function(){var s=document.createElement('style');s.textContent='*{-webkit-user-select:text!important;user-select:text!important}';document.documentElement.appendChild(s);
                    ['copy','cut','contextmenu','selectstart','mousedown','mouseup','keydown'].forEach(function(e){document.addEventListener(e,function(ev){ev.stopPropagation()},true)});})();
                    """, matches: "*", runAt: .domContentLoaded, isActive: true),
    ]

    var passive: [JSExtension] { extensions.filter { $0.enabled && !$0.isActive } }
    func active(for url: URL?) -> [JSExtension] { extensions.filter { $0.enabled && $0.isActive && $0.matches(url: url) } }

    func upsert(_ e: JSExtension) {
        if let i = extensions.firstIndex(where: { $0.id == e.id }) { extensions[i] = e } else { extensions.append(e) }
        save()
    }

    func remove(id: UUID) { extensions.removeAll { $0.id == id }; save() }

    func move(from: Int, to: Int) {
        let e = extensions.remove(at: from)
        extensions.insert(e, at: to)
        save()
    }

    private func save() {
        JSONStore.save(extensions, to: file)
        NotificationCenter.default.post(name: .extensionsChanged, object: nil)
    }

    /// Parses a userscript-style header (// @name, // @match, // @run-at) from an imported .js file.
    static func parse(fileContent: String, fallbackName: String) -> JSExtension {
        var ext = JSExtension(name: fallbackName, code: fileContent)
        var matches: [String] = []
        for line in fileContent.components(separatedBy: .newlines) {
            let t = line.trimmed
            guard t.hasPrefix("// @") else { continue }
            let parts = t.dropFirst(4).split(separator: " ", maxSplits: 1).map { String($0).trimmed }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "name": ext.name = parts[1]
            case "author": ext.author = parts[1]
            case "description": ext.summary = parts[1]
            case "match", "include":
                let v = parts[1]
                if v == "*" || v.contains("<all_urls>") || v == "*://*/*" { matches.append("*") }
                else if let host = v.replacingOccurrences(of: "*://", with: "https://").replacingOccurrences(of: "*.", with: "").components(separatedBy: "/").dropFirst(2).first {
                    matches.append(host)
                }
            case "run-at": ext.runAt = parts[1].contains("start") ? .veryBeginning : .domContentLoaded
            default: break
            }
        }
        if !matches.isEmpty { ext.matches = matches.joined(separator: "@@") }
        return ext
    }
}
