import Foundation
import Network

/// Local HTTP proxy in front of the native player so videos start and seek faster on the same
/// bandwidth:
/// - progressive files (mp4, mov, webm…) are downloaded as parallel 1 MB range requests kept a few
///   chunks ahead of what the player reads, instead of one TCP stream;
/// - HLS playlists are rewritten to go through the proxy, and the next segments are prefetched in
///   parallel while the current one plays;
/// - everything downloaded stays in a memory cache, so seeking back is instant.
/// When the server doesn't support ranges, or the proxy can't start, the original URL is used.
final class VideoProxy {
    static let shared = VideoProxy()

    static let chunkSize = 1 << 20
    /// Range requests kept in flight ahead of the read position.
    static let parallelChunks = 4
    static let segmentPrefetch = 4

    private let queue = DispatchQueue(label: "fa.videoproxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var waiters: [(Bool) -> Void] = []
    private var sources: [String: Source] = [:]
    private let cache = ByteCache(limit: 160 << 20)
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForRequest = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    private final class Source {
        let token: String
        let url: URL
        let headers: [String: String]
        let cookies: [HTTPCookie]
        var length: Int64 = -1
        var contentType = "video/mp4"
        var isHLS = false
        /// Segments of the last media playlist served, in play order.
        var segments: [URL] = []
        var chunkWaiters: [Int: [(Data?) -> Void]] = [:]
        var segmentWaiters: [String: [(Data?, String?) -> Void]] = [:]

        init(token: String, url: URL, headers: [String: String], cookies: [HTTPCookie]) {
            self.token = token
            self.url = url
            self.headers = headers
            self.cookies = cookies
        }
    }

    // MARK: Public

    /// Calls back on the main queue with the URL the player should open.
    func playableURL(for url: URL, headers: [String: String], cookies: [HTTPCookie], completion: @escaping (URL) -> Void) {
        let done: (URL) -> Void = { u in DispatchQueue.main.async { completion(u) } }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { done(url); return }
        queue.async {
            self.start { ok in
                guard ok else { done(url); return }
                let token = String(UUID().uuidString.prefix(8)).lowercased()
                let src = Source(token: token, url: url, headers: headers, cookies: cookies)
                self.probe(src) { useProxy in
                    guard useProxy else { done(url); return }
                    if self.sources.count > 20, let old = self.sources.keys.first(where: { $0 != token }) { self.sources[old] = nil }
                    self.sources[token] = src
                    done(self.proxyURL(for: url, source: src))
                }
            }
        }
    }

    static func isProxied(_ url: URL?) -> Bool { url?.host == "127.0.0.1" && url?.path.hasPrefix("/s/") == true }

    // MARK: Listener

    private func start(_ completion: @escaping (Bool) -> Void) {
        if listener != nil, port != 0 { completion(true); return }
        waiters.append(completion)
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else { finishStart(false); return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                self.finishStart(self.port != 0)
            case .failed, .cancelled:
                self.listener = nil
                self.port = 0
                self.finishStart(false)
            default: break
            }
        }
        l.start(queue: queue)
    }

    private func finishStart(_ ok: Bool) {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0(ok) }
    }

    private func proxyURL(for target: URL, source: Source) -> URL {
        let b64 = Data(target.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var name = target.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        if name.isEmpty || name == "/" { name = source.isHLS ? "index.m3u8" : "video" }
        return URL(string: "http://127.0.0.1:\(port)/s/\(source.token)/\(b64)/\(name)")!
    }

    private func decodeTarget(_ b64: String) -> URL? {
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
    }

    // MARK: Origin requests

    private func request(_ url: URL, source: Source, range: String?) -> URLRequest {
        var r = URLRequest(url: url)
        source.headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        let host = url.host?.lowercased() ?? ""
        let cookies = source.cookies.filter { c in
            let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == d || host.hasSuffix("." + d)
        }
        HTTPCookie.requestHeaderFields(with: cookies).forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        return r
    }

    /// First request: reads the first chunk, learns the size and type, and decides whether to proxy.
    private func probe(_ src: Source, completion: @escaping (Bool) -> Void) {
        let path = src.url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") { src.isHLS = true; completion(true); return }
        let req = request(src.url, source: src, range: "bytes=0-\(VideoProxy.chunkSize - 1)")
        session.dataTask(with: req) { data, resp, _ in
            self.queue.async {
                guard let http = resp as? HTTPURLResponse, let data else { completion(false); return }
                let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if type.contains("mpegurl") || data.prefix(7) == Data("#EXTM3U".utf8) { src.isHLS = true; completion(true); return }
                guard http.statusCode == 206, let total = VideoProxy.totalLength(http), total > 0 else { completion(false); return }
                src.length = total
                if !type.isEmpty, !type.contains("octet-stream") { src.contentType = type }
                if data.count == min(VideoProxy.chunkSize, Int(total)) { self.cache.set(data, for: "\(src.token)#0") }
                completion(true)
            }
        }.resume()
    }

    private static func totalLength(_ http: HTTPURLResponse) -> Int64? {
        guard let cr = http.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") else { return nil }
        return Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    private func chunk(_ i: Int, of src: Source, completion: @escaping (Data?) -> Void) {
        let key = "\(src.token)#\(i)"
        if let d = cache.get(key) { completion(d); return }
        if src.chunkWaiters[i] != nil { src.chunkWaiters[i]!.append(completion); return }
        src.chunkWaiters[i] = [completion]
        let start = Int64(i) * Int64(VideoProxy.chunkSize)
        let end = min(src.length, start + Int64(VideoProxy.chunkSize)) - 1
        fetchRange(src, start: start, end: end, attempt: 0) { data in
            if let data { self.cache.set(data, for: key) }
            let w = src.chunkWaiters.removeValue(forKey: i) ?? []
            w.forEach { $0(data) }
        }
    }

    private func fetchRange(_ src: Source, start: Int64, end: Int64, attempt: Int, completion: @escaping (Data?) -> Void) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FAProxyLog") { print("VideoProxy -> origin bytes=\(start)-\(end)") }
        #endif
        session.dataTask(with: request(src.url, source: src, range: "bytes=\(start)-\(end)")) { data, resp, _ in
            self.queue.async {
                let ok = (resp as? HTTPURLResponse)?.statusCode == 206 && data?.count == Int(end - start + 1)
                if ok { completion(data) } else if attempt < 2 { self.fetchRange(src, start: start, end: end, attempt: attempt + 1, completion: completion) } else { completion(nil) }
            }
        }.resume()
    }

    private func prefetchChunks(from i: Int, of src: Source) {
        let last = Int((src.length - 1) / Int64(VideoProxy.chunkSize))
        for c in i..<min(i + VideoProxy.parallelChunks, last + 1) { chunk(c, of: src) { _ in } }
    }

    private func segment(_ url: URL, of src: Source, completion: @escaping (Data?, String?) -> Void) {
        let key = "\(src.token)|\(url.absoluteString)"
        if let d = cache.get(key) { completion(d, nil); return }
        if src.segmentWaiters[key] != nil { src.segmentWaiters[key]!.append(completion); return }
        src.segmentWaiters[key] = [completion]
        session.dataTask(with: request(url, source: src, range: nil)) { data, resp, _ in
            self.queue.async {
                let http = resp as? HTTPURLResponse
                let ok = data != nil && (200..<300).contains(http?.statusCode ?? 0)
                if ok, let data { self.cache.set(data, for: key) }
                let w = src.segmentWaiters.removeValue(forKey: key) ?? []
                w.forEach { $0(ok ? data : nil, http?.value(forHTTPHeaderField: "Content-Type")) }
            }
        }.resume()
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, head: String(decoding: buf[..<r.lowerBound], as: UTF8.self))
            } else if error != nil || done || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private func handle(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FAProxyLog") { print("VideoProxy <-", lines.first ?? "", lines.first { $0.lowercased().hasPrefix("range:") } ?? "") }
        #endif
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { c.cancel(); return }
        let isHead = parts[0] == "HEAD"
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = parts[1].split(separator: "/").map(String.init)
        guard comps.count >= 3, comps[0] == "s", let src = sources[comps[1]], let target = decodeTarget(comps[2]) else {
            respond(c, status: "404 Not Found", headers: [:], body: Data())
            return
        }
        if !src.isHLS && target == src.url {
            serveFile(c, src: src, range: headers["range"], headOnly: isHead)
        } else {
            serveHLS(c, src: src, target: target, range: headers["range"], headOnly: isHead)
        }
    }

    private func respond(_ c: NWConnection, status: String, headers: [String: String], body: Data, headOnly: Bool = false) {
        var h = "HTTP/1.1 \(status)\r\n"
        var all = headers
        all["Content-Length"] = all["Content-Length"] ?? String(body.count)
        all["Connection"] = "close"
        all.forEach { h += "\($0.key): \($0.value)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        if !headOnly { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Progressive files

    private func serveFile(_ c: NWConnection, src: Source, range: String?, headOnly: Bool) {
        let total = src.length
        var start: Int64 = 0, end: Int64 = total - 1
        var partial = false
        if let range, range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let ab = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            if ab.count == 2 {
                if ab[0].isEmpty, let n = Int64(ab[1]) { start = max(0, total - n) }
                else { start = Int64(ab[0]) ?? 0; if let e = Int64(ab[1]) { end = min(e, total - 1) } }
                partial = true
            }
        }
        guard start <= end, start < total else {
            respond(c, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(total)"], body: Data())
            return
        }
        var h = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        h += "Content-Type: \(src.contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\nConnection: close\r\n"
        if partial { h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        h += "\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !headOnly else { c.cancel(); return }
            self.stream(c, src: src, from: start, to: end)
        })
    }

    /// Sends [pos, end] chunk by chunk. Waiting on the socket before asking for the next chunk
    /// keeps the download only a few chunks ahead of what the player has read.
    private func stream(_ c: NWConnection, src: Source, from pos: Int64, to end: Int64) {
        guard pos <= end else { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let cs = Int64(VideoProxy.chunkSize)
        let i = Int(pos / cs)
        prefetchChunks(from: i, of: src)
        chunk(i, of: src) { [weak self] data in
            guard let self, let data else { c.cancel(); return }
            let chunkStart = Int64(i) * cs
            let lo = Int(pos - chunkStart)
            let hi = min(data.count, Int(end - chunkStart) + 1)
            guard lo < hi else { c.cancel(); return }
            c.send(content: data.subdata(in: lo..<hi), completion: .contentProcessed { error in
                guard error == nil else { c.cancel(); return }
                self.stream(c, src: src, from: chunkStart + Int64(hi), to: end)
            })
        }
    }

    // MARK: HLS

    private func serveHLS(_ c: NWConnection, src: Source, target: URL, range: String?, headOnly: Bool) {
        if let range {
            // Byte-range segments (EXT-X-BYTERANGE): pass through without caching.
            session.dataTask(with: request(target, source: src, range: range)) { data, resp, _ in
                self.queue.async {
                    let http = resp as? HTTPURLResponse
                    var h: [String: String] = ["Content-Type": http?.value(forHTTPHeaderField: "Content-Type") ?? "video/mp2t"]
                    if let cr = http?.value(forHTTPHeaderField: "Content-Range") { h["Content-Range"] = cr }
                    let status = http?.statusCode == 206 ? "206 Partial Content" : (http?.statusCode == 200 ? "200 OK" : "502 Bad Gateway")
                    self.respond(c, status: status, headers: h, body: data ?? Data(), headOnly: headOnly)
                }
            }.resume()
            return
        }
        if let idx = src.segments.firstIndex(of: target) {
            for next in src.segments[(idx + 1)...].prefix(VideoProxy.segmentPrefetch) { segment(next, of: src) { _, _ in } }
            segment(target, of: src) { data, type in
                guard let data else { self.respond(c, status: "502 Bad Gateway", headers: [:], body: Data()); return }
                self.respond(c, status: "200 OK", headers: ["Content-Type": type ?? VideoProxy.mime(for: target)], body: data, headOnly: headOnly)
            }
            return
        }
        // Playlists (never cached: live playlists change) and anything not listed as a segment.
        session.dataTask(with: request(target, source: src, range: nil)) { data, resp, _ in
            self.queue.async {
                let http = resp as? HTTPURLResponse
                guard let data, (200..<300).contains(http?.statusCode ?? 0) else {
                    self.respond(c, status: "502 Bad Gateway", headers: [:], body: Data())
                    return
                }
                let base = http?.url ?? target
                if data.prefix(7) == Data("#EXTM3U".utf8), let text = String(data: data, encoding: .utf8) {
                    let body = Data(self.rewrite(text, base: base, src: src).utf8)
                    self.respond(c, status: "200 OK", headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-cache"], body: body, headOnly: headOnly)
                } else {
                    self.respond(c, status: "200 OK", headers: ["Content-Type": http?.value(forHTTPHeaderField: "Content-Type") ?? VideoProxy.mime(for: target)], body: data, headOnly: headOnly)
                }
            }
        }.resume()
    }

    private func rewrite(_ text: String, base: URL, src: Source) -> String {
        let isMedia = text.contains("#EXTINF")
        var segments: [URL] = []
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return line }
            if t.hasPrefix("#") {
                guard let r = t.range(of: "URI=\"") else { return line }
                let rest = t[r.upperBound...]
                guard let q = rest.firstIndex(of: "\""), let abs = URL(string: String(rest[..<q]), relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(abs.scheme?.lowercased() ?? "") else { return line }
                return String(t[..<r.upperBound]) + proxyURL(for: abs, source: src).absoluteString + String(rest[q...])
            }
            guard let abs = URL(string: t, relativeTo: base)?.absoluteURL else { return line }
            if isMedia { segments.append(abs) }
            return proxyURL(for: abs, source: src).absoluteString
        }
        if isMedia { src.segments = segments }
        return lines.joined(separator: "\n")
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "aac": return "audio/aac"
        case "m4s", "mp4", "m4v", "cmfv": return "video/mp4"
        case "m4a", "cmfa": return "audio/mp4"
        case "vtt", "webvtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}

/// Size-bounded LRU of downloaded bytes. Used only on the proxy queue.
private final class ByteCache {
    private let limit: Int
    private var items: [String: Data] = [:]
    private var order: [String] = []
    private var size = 0

    init(limit: Int) { self.limit = limit }

    func get(_ key: String) -> Data? {
        guard let d = items[key] else { return nil }
        if let i = order.lastIndex(of: key) { order.remove(at: i); order.append(key) }
        return d
    }

    func set(_ data: Data, for key: String) {
        if let old = items[key] { size -= old.count; order.removeAll { $0 == key } }
        items[key] = data
        order.append(key)
        size += data.count
        while size > limit, !order.isEmpty {
            let k = order.removeFirst()
            size -= items.removeValue(forKey: k)?.count ?? 0
        }
    }
}
