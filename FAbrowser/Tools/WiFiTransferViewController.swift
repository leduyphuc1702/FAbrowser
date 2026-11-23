import UIKit
import Network

/// Minimal HTTP/1.1 file server on the local network: browse, download and upload into Documents/Downloads.
final class WiFiTransferServer {
    private var listener: NWListener?
    private(set) var port: UInt16 = 8080
    var onLog: ((String) -> Void)?
    var root: URL { FileManager.default.downloadsURL }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let length = Self.header("Content-Length", in: head).flatMap(Int.init) ?? 0
                let bodyStart = headerEnd.upperBound
                if buf.count - bodyStart >= length {
                    self.respond(c, head: head, body: buf.subdata(in: bodyStart..<(bodyStart + length)))
                    return
                }
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c, buffer: buf)
        }
    }

    private static func header(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { send(c, status: "400 Bad Request", body: Data()); return }
        let method = String(parts[0])
        let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])

        if method == "POST", path == "/upload" {
            let ct = Self.header("Content-Type", in: head) ?? ""
            let saved = saveMultipart(body, contentType: ct)
            DispatchQueue.main.async { saved.forEach { self.onLog?(L("Received") + ": " + $0) } }
            send(c, status: "303 See Other", headers: ["Location": "/"], body: Data())
            return
        }
        if method == "GET", path.hasPrefix("/files/") {
            let name = String(path.dropFirst("/files/".count))
            let url = root.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: url) else {
                send(c, status: "404 Not Found", body: Data("Not found".utf8)); return
            }
            DispatchQueue.main.async { self.onLog?(L("Sent") + ": " + name) }
            send(c, status: "200 OK", headers: ["Content-Type": "application/octet-stream",
                                                  "Content-Disposition": "attachment; filename=\"\(url.lastPathComponent)\""], body: data)
            return
        }
        if method == "GET", path.hasPrefix("/delete/") {
            let name = String(path.dropFirst("/delete/".count))
            let url = root.appendingPathComponent(name).standardizedFileURL
            if url.path.hasPrefix(root.standardizedFileURL.path) { try? FileManager.default.removeItem(at: url) }
            send(c, status: "303 See Other", headers: ["Location": "/"], body: Data())
            return
        }
        send(c, status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(indexPage().utf8))
    }

    private func send(_ c: NWConnection, status: String, headers: [String: String] = [:], body: Data) {
        var h = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        headers.forEach { h += "\($0.key): \($0.value)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func saveMultipart(_ body: Data, contentType: String) -> [String] {
        guard let b = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else { return [] }
        let delimiter = Data("--\(b)".utf8)
        var saved: [String] = []
        var cursor = body.startIndex
        while let r = body.range(of: delimiter, in: cursor..<body.endIndex) {
            let partStart = r.upperBound
            guard let next = body.range(of: delimiter, in: partStart..<body.endIndex) else { break }
            let part = body.subdata(in: partStart..<next.lowerBound)
            cursor = next.lowerBound
            guard let hEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headers = String(decoding: part[..<hEnd.lowerBound], as: UTF8.self)
            guard let fnRange = headers.range(of: "filename=\"") else { continue }
            let rest = headers[fnRange.upperBound...]
            let filename = String(rest.prefix { $0 != "\"" })
            guard !filename.isEmpty else { continue }
            var content = part.subdata(in: hEnd.upperBound..<part.endIndex)
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            let dest = FileManager.default.uniqueURL(for: root.appendingPathComponent((filename as NSString).lastPathComponent))
            if (try? content.write(to: dest)) != nil { saved.append(dest.lastPathComponent) }
        }
        return saved
    }

    private func indexPage() -> String {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let rows = files.map { f -> String in
            let esc = f.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let link = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
            let size = FileManager.default.sizeOfItem(at: root.appendingPathComponent(f)).byteString
            return "<tr><td><a href=\"/files/\(link)\">\(esc)</a></td><td>\(size)</td><td><a class=d href=\"/delete/\(link)\" onclick=\"return confirm('Delete?')\">✕</a></td></tr>"
        }.joined()
        return """
        <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>FAbrowser Wi-Fi Transfer</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;max-width:760px;margin:30px auto;padding:0 16px;color:#222}
        h1{font-size:22px}form{padding:18px;border:2px dashed #2E7CF6;border-radius:12px;margin:18px 0}
        table{width:100%;border-collapse:collapse}td{padding:9px 6px;border-bottom:1px solid #eee}a{color:#2E7CF6;text-decoration:none}a.d{color:#E5484D}
        button{background:#2E7CF6;color:#fff;border:0;border-radius:8px;padding:8px 16px;font-size:15px}</style></head><body>
        <h1>FAbrowser · Wi-Fi Transfer</h1>
        <form method=post action="/upload" enctype="multipart/form-data"><input type=file name=file multiple> <button>Upload</button></form>
        <table>\(rows.isEmpty ? "<tr><td>No files</td></tr>" : rows)</table></body></html>
        """
    }

    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name == "en1" || (address == nil && name.hasPrefix("bridge")) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            if name == "en0" { break }
        }
        return address
    }
}

final class WiFiTransferViewController: UIViewController {
    private let server = WiFiTransferServer()
    private let addressLabel = UILabel()
    private let statusLabel = UILabel()
    private let logView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Wi-Fi Transfer")
        view.backgroundColor = .systemGroupedBackground
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        }

        let icon = UIImageView(image: Theme.symbol("wifi", size: 54, weight: .medium))
        icon.tintColor = Theme.accent
        icon.contentMode = .center

        statusLabel.text = L("Make sure your computer and this device are on the same Wi-Fi, then open the address below in a browser:")
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 15)

        addressLabel.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        addressLabel.textAlignment = .center
        addressLabel.textColor = Theme.accent
        addressLabel.isUserInteractionEnabled = true
        addressLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(copyAddress)))

        let hint = UILabel()
        hint.text = L("Keep this page open during transfer. Files are saved to Files › Downloads.")
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.textColor = .tertiaryLabel
        hint.font = .systemFont(ofSize: 13)

        logView.isEditable = false
        logView.font = .systemFont(ofSize: 13)
        logView.backgroundColor = .secondarySystemGroupedBackground
        logView.layer.cornerRadius = 10

        let stack = UIStackView(arrangedSubviews: [icon, statusLabel, addressLabel, hint, logView])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            icon.heightAnchor.constraint(equalToConstant: 70),
        ])

        server.onLog = { [weak self] s in
            guard let self else { return }
            self.logView.text = s + "\n" + self.logView.text
            NotificationCenter.default.post(name: .downloadsChanged, object: nil)
        }
        do {
            try server.start()
            let ip = WiFiTransferServer.localIPAddress() ?? "localhost"
            addressLabel.text = "http://\(ip):\(server.port)"
        } catch {
            addressLabel.text = L("Failed")
            statusLabel.text = error.localizedDescription
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            server.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @objc private func copyAddress() {
        UIPasteboard.general.string = addressLabel.text
        Toast.show(L("Copied"))
    }

    @objc private func close() { dismiss(animated: true) }
}
