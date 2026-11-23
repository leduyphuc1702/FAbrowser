import UIKit

struct SearchEngine: Codable, Equatable {
    var id: String
    var name: String
    /// Template where `%@` is replaced by the percent-encoded query.
    var template: String
    var isCustom: Bool = false
    var colorHex: String = "2E7CF6"
    var isQuick: Bool = true

    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%@", with: q))
    }

    var color: UIColor { UIColor(hexString: colorHex) ?? Theme.accent }
    var host: String? { URL(string: template.replacingOccurrences(of: "%@", with: ""))?.host }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

final class SearchEngineStore {
    static let shared = SearchEngineStore()
    private let file = "search_engines.json"

    private(set) var engines: [SearchEngine]

    static let defaults: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%@", colorHex: "4285F4"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%@", colorHex: "008373"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%@", colorHex: "DE5833"),
        SearchEngine(id: "yahoo", name: "Yahoo", template: "https://search.yahoo.com/search?p=%@", colorHex: "6001D2"),
        SearchEngine(id: "coccoc", name: "Cốc Cốc", template: "https://coccoc.com/search?query=%@", colorHex: "1A9E4B"),
        SearchEngine(id: "baidu", name: "Baidu", template: "https://www.baidu.com/s?wd=%@", colorHex: "2932E1"),
        SearchEngine(id: "yandex", name: "Yandex", template: "https://yandex.com/search/?text=%@", colorHex: "FC3F1D"),
        SearchEngine(id: "wikipedia", name: "Wikipedia", template: "https://en.m.wikipedia.org/w/index.php?search=%@", colorHex: "636466"),
        SearchEngine(id: "youtube", name: "YouTube", template: "https://m.youtube.com/results?search_query=%@", colorHex: "FF0000"),
        SearchEngine(id: "github", name: "GitHub", template: "https://github.com/search?q=%@", colorHex: "24292F"),
    ]

    private init() {
        engines = JSONStore.load([SearchEngine].self, from: file) ?? SearchEngineStore.defaults
        if engines.isEmpty { engines = SearchEngineStore.defaults }
    }

    var current: SearchEngine {
        engines.first { $0.id == Prefs.searchEngineID } ?? engines[0]
    }

    var quickEngines: [SearchEngine] { engines.filter { $0.isQuick } }

    func searchURL(for query: String) -> URL? { current.url(for: query) }

    func setEngines(_ list: [SearchEngine]) {
        engines = list.isEmpty ? SearchEngineStore.defaults : list
        save()
    }

    func add(_ e: SearchEngine) { engines.append(e); save() }

    func update(_ e: SearchEngine) {
        if let i = engines.firstIndex(where: { $0.id == e.id }) { engines[i] = e; save() }
    }

    func remove(id: String) {
        engines.removeAll { $0.id == id }
        if Prefs.searchEngineID == id { Prefs.searchEngineID = engines.first?.id ?? "google" }
        save()
    }

    func move(from: Int, to: Int) {
        let e = engines.remove(at: from)
        engines.insert(e, at: to)
        save()
    }

    func restoreDefaults() { engines = SearchEngineStore.defaults; save() }

    private func save() {
        JSONStore.save(engines, to: file)
        NotificationCenter.default.post(name: .searchEnginesChanged, object: nil)
    }

    /// Google suggest endpoint returning `[query, [suggestions]]`.
    func suggestions(for query: String, completion: @escaping ([String]) -> Void) -> URLSessionDataTask? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
              let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)") else { return nil }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            var result: [String] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               json.count > 1, let list = json[1] as? [String] {
                result = list
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }
}
