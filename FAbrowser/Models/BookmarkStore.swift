import Foundation

final class BookmarkNode: Codable {
    var id: UUID
    var title: String
    var url: String?
    var children: [BookmarkNode]?
    var created: Date

    var isFolder: Bool { children != nil }

    init(title: String, url: String?, isFolder: Bool = false) {
        id = UUID()
        self.title = title
        self.url = url
        children = isFolder ? [] : nil
        created = Date()
    }

    var bookmarkCount: Int { children?.filter { !$0.isFolder }.count ?? 0 }
    var folderCount: Int { children?.filter { $0.isFolder }.count ?? 0 }
}

/// A shortcut on the navigation homepage.
struct HomeSite: Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var customIconFile: String?
}

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let bookmarksFile = "bookmarks.json"
    private let homeFile = "home_sites.json"

    private(set) var root: BookmarkNode
    private(set) var homeSites: [HomeSite]

    static let defaultHomeSites: [HomeSite] = [
        HomeSite(title: "Google", url: "https://www.google.com"),
        HomeSite(title: "YouTube", url: "https://m.youtube.com"),
        HomeSite(title: "Facebook", url: "https://m.facebook.com"),
        HomeSite(title: "Wikipedia", url: "https://www.wikipedia.org"),
        HomeSite(title: "X", url: "https://x.com"),
        HomeSite(title: "Reddit", url: "https://www.reddit.com"),
        HomeSite(title: "GitHub", url: "https://github.com"),
        HomeSite(title: "VnExpress", url: "https://vnexpress.net"),
        HomeSite(title: "Amazon", url: "https://www.amazon.com"),
        HomeSite(title: "Instagram", url: "https://www.instagram.com"),
    ]

    private init() {
        root = JSONStore.load(BookmarkNode.self, from: bookmarksFile) ?? BookmarkNode(title: L("Bookmarks"), url: nil, isFolder: true)
        homeSites = JSONStore.load([HomeSite].self, from: homeFile) ?? BookmarkStore.defaultHomeSites
    }

    // MARK: Bookmarks

    func folder(id: UUID?) -> BookmarkNode {
        guard let id else { return root }
        return find(id: id, in: root) ?? root
    }

    func find(id: UUID, in node: BookmarkNode) -> BookmarkNode? {
        if node.id == id { return node }
        for c in node.children ?? [] {
            if let f = find(id: id, in: c) { return f }
        }
        return nil
    }

    func parent(of id: UUID, in node: BookmarkNode? = nil) -> BookmarkNode? {
        let n = node ?? root
        for c in n.children ?? [] {
            if c.id == id { return n }
            if let p = parent(of: id, in: c) { return p }
        }
        return nil
    }

    func allFolders() -> [(node: BookmarkNode, depth: Int)] {
        var out: [(BookmarkNode, Int)] = []
        func walk(_ n: BookmarkNode, _ d: Int) {
            out.append((n, d))
            for c in n.children ?? [] where c.isFolder { walk(c, d + 1) }
        }
        walk(root, 0)
        return out
    }

    var allBookmarkCount: Int {
        func count(_ n: BookmarkNode) -> Int { (n.children ?? []).reduce(0) { $0 + ($1.isFolder ? count($1) : 1) } }
        return count(root)
    }

    func isBookmarked(_ url: URL?) -> Bool { bookmark(for: url) != nil }

    func bookmark(for url: URL?) -> BookmarkNode? {
        guard let s = url?.absoluteString else { return nil }
        func walk(_ n: BookmarkNode) -> BookmarkNode? {
            if n.url == s { return n }
            for c in n.children ?? [] { if let f = walk(c) { return f } }
            return nil
        }
        return walk(root)
    }

    func add(title: String, url: String, to folderID: UUID? = nil) {
        folder(id: folderID).children?.insert(BookmarkNode(title: title, url: url), at: 0)
        save()
    }

    func addFolder(title: String, to folderID: UUID? = nil) {
        folder(id: folderID).children?.insert(BookmarkNode(title: title, url: nil, isFolder: true), at: 0)
        save()
    }

    func update(id: UUID, title: String, url: String?, moveTo folderID: UUID?) {
        guard let node = find(id: id, in: root) else { return }
        node.title = title
        if !node.isFolder { node.url = url }
        if let current = parent(of: id) {
            let target = folder(id: folderID)
            if target.id != current.id, target.id != node.id, find(id: target.id, in: node) == nil {
                current.children?.removeAll { $0.id == id }
                target.children?.insert(node, at: 0)
            }
        }
        save()
    }

    func remove(id: UUID) {
        parent(of: id)?.children?.removeAll { $0.id == id }
        save()
    }

    func move(in folderID: UUID?, from: Int, to: Int) {
        let f = folder(id: folderID)
        guard var c = f.children, from < c.count, to < c.count else { return }
        let n = c.remove(at: from)
        c.insert(n, at: to)
        f.children = c
        save()
    }

    func save() {
        JSONStore.save(root, to: bookmarksFile)
        NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
    }

    // MARK: Home sites

    func addHomeSite(_ site: HomeSite) {
        homeSites.append(site)
        saveHome()
    }

    func updateHomeSite(_ site: HomeSite) {
        if let i = homeSites.firstIndex(where: { $0.id == site.id }) { homeSites[i] = site; saveHome() }
    }

    func removeHomeSite(id: UUID) {
        homeSites.removeAll { $0.id == id }
        saveHome()
    }

    func moveHomeSite(from: Int, to: Int) {
        let s = homeSites.remove(at: from)
        homeSites.insert(s, at: min(to, homeSites.count))
        saveHome()
    }

    func resetHomeSites() {
        homeSites = BookmarkStore.defaultHomeSites
        saveHome()
    }

    private func saveHome() {
        JSONStore.save(homeSites, to: homeFile)
        NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
    }

    // MARK: Import / export (Netscape bookmark HTML)

    func exportHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func walk(_ n: BookmarkNode, _ indent: String) -> String {
            var s = ""
            for c in n.children ?? [] {
                if c.isFolder {
                    s += "\(indent)<DT><H3>\(esc(c.title))</H3>\n\(indent)<DL><p>\n" + walk(c, indent + "    ") + "\(indent)</DL><p>\n"
                } else {
                    s += "\(indent)<DT><A HREF=\"\(esc(c.url ?? ""))\">\(esc(c.title))</A>\n"
                }
            }
            return s
        }
        return """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
        \(walk(root, "    "))</DL><p>
        """
    }

    /// Minimal Netscape bookmark parser, good enough for Safari/Chrome/Firefox exports.
    @discardableResult
    func importHTML(_ html: String) -> Int {
        let imported = BookmarkNode(title: L("Imported"), url: nil, isFolder: true)
        var stack: [BookmarkNode] = [imported]
        var pendingFolder: BookmarkNode?
        var count = 0
        let tokenRegex = try! NSRegularExpression(pattern: "<DT><H3[^>]*>(.*?)</H3>|<DT><A[^>]*HREF=\"([^\"]*)\"[^>]*>(.*?)</A>|<DL>|</DL>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        func unesc(_ s: String) -> String {
            s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        }
        for m in tokenRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range).uppercased()
            if m.range(at: 1).location != NSNotFound {
                let f = BookmarkNode(title: unesc(ns.substring(with: m.range(at: 1))), url: nil, isFolder: true)
                stack.last?.children?.append(f)
                pendingFolder = f
            } else if m.range(at: 2).location != NSNotFound {
                let url = unesc(ns.substring(with: m.range(at: 2)))
                let title = unesc(ns.substring(with: m.range(at: 3)))
                stack.last?.children?.append(BookmarkNode(title: title.isEmpty ? url : title, url: url))
                count += 1
            } else if token == "<DL>" {
                if let f = pendingFolder { stack.append(f); pendingFolder = nil }
            } else if token == "</DL>" {
                if stack.count > 1 { stack.removeLast() }
            }
        }
        if count > 0 {
            root.children?.insert(imported, at: 0)
            save()
        }
        return count
    }
}
