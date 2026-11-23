import Foundation

struct HistoryItem: Codable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    var date: Date
}

final class HistoryStore {
    static let shared = HistoryStore()

    private let file = "history.json"
    private let searchFile = "search_history.json"
    private let maxItems = 5000
    private var saveWork: DispatchWorkItem?

    /// Newest first.
    private(set) var items: [HistoryItem]
    private(set) var searches: [String]

    private init() {
        items = JSONStore.load([HistoryItem].self, from: file) ?? []
        searches = JSONStore.load([String].self, from: searchFile) ?? []
    }

    func record(url: URL, title: String?) {
        guard url.isWebURL else { return }
        let s = url.absoluteString
        let t = (title?.isEmpty == false ? title! : url.displayString)
        if let first = items.first, first.url == s {
            items[0].title = t
            items[0].date = Date()
        } else {
            items.removeAll { $0.url == s && Date().timeIntervalSince($0.date) < 3600 }
            items.insert(HistoryItem(url: s, title: t, date: Date()), at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
        }
        scheduleSave()
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let i = items.firstIndex(where: { $0.url == url.absoluteString }) else { return }
        items[i].title = title
        scheduleSave()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Clears history newer than `since`; nil clears everything.
    func clear(since: Date?) {
        if let since { items.removeAll { $0.date >= since } } else { items.removeAll() }
        scheduleSave()
    }

    func search(_ query: String, limit: Int = 8) -> [HistoryItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(uniqueByURL().prefix(limit)) }
        return Array(uniqueByURL().filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }.prefix(limit))
    }

    func uniqueByURL() -> [HistoryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.url).inserted }
    }

    /// Best domain completion for the URL bar, e.g. "goo" -> "google.com".
    func domainCompletion(for prefix: String) -> String? {
        let p = prefix.lowercased()
        guard p.count >= 1, !p.contains(" "), !p.contains("/") else { return nil }
        let builtins = ["google.com", "youtube.com", "facebook.com", "wikipedia.org", "github.com", "reddit.com", "twitter.com", "x.com", "amazon.com", "instagram.com", "vnexpress.net", "tiktok.com", "netflix.com", "zalo.me", "shopee.vn"]
        for item in items {
            if let host = URL(string: item.url)?.normalizedHost, host.hasPrefix(p) { return host }
        }
        return builtins.first { $0.hasPrefix(p) }
    }

    // MARK: Search history

    func recordSearch(_ q: String) {
        guard Prefs.recordSearchHistory else { return }
        let t = q.trimmed
        guard !t.isEmpty else { return }
        searches.removeAll { $0 == t }
        searches.insert(t, at: 0)
        if searches.count > 50 { searches.removeLast() }
        JSONStore.save(searches, to: searchFile)
    }

    func removeSearch(_ q: String) {
        searches.removeAll { $0 == q }
        JSONStore.save(searches, to: searchFile)
    }

    func clearSearches() {
        searches.removeAll()
        JSONStore.save(searches, to: searchFile)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { [file] in JSONStore.save(snapshot, to: file) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    func flush() {
        saveWork?.cancel()
        JSONStore.save(items, to: file)
    }
}
