import UIKit

/// Fetches and caches site icons by host. Falls back to a letter avatar.
final class FaviconManager {
    static let shared = FaviconManager()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: [(UIImage?) -> Void]] = [:]
    private let dir: URL

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(for host: String) -> URL { dir.appendingPathComponent(host + ".png") }

    func cachedIcon(for host: String) -> UIImage? {
        if let img = memory.object(forKey: host as NSString) { return img }
        if let data = try? Data(contentsOf: file(for: host)), let img = UIImage(data: data) {
            memory.setObject(img, forKey: host as NSString)
            return img
        }
        return nil
    }

    func icon(for url: URL?, completion: @escaping (UIImage?) -> Void) {
        guard let host = url?.normalizedHost else { completion(nil); return }
        if let img = cachedIcon(for: host) { completion(img); return }
        if inflight[host] != nil { inflight[host]?.append(completion); return }
        inflight[host] = [completion]
        let src = URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(host)")!
        URLSession.shared.dataTask(with: src) { [weak self] data, resp, _ in
            var image: UIImage?
            if let data, let img = UIImage(data: data), img.size.width >= 32, (resp as? HTTPURLResponse)?.statusCode == 200 {
                image = img
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.store(image, host: host) }
                self.inflight[host]?.forEach { $0(image) }
                self.inflight[host] = nil
            }
        }.resume()
    }

    /// Saves an icon discovered by the page itself (apple-touch-icon), which is usually sharper.
    func setIcon(from iconURL: URL, for pageURL: URL) {
        guard let host = pageURL.normalizedHost else { return }
        URLSession.shared.dataTask(with: iconURL) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data), img.size.width >= 48 else { return }
            DispatchQueue.main.async { self?.store(img, host: host) }
        }.resume()
    }

    private func store(_ image: UIImage, host: String) {
        memory.setObject(image, forKey: host as NSString)
        if let data = image.pngData() { try? data.write(to: file(for: host)) }
    }

    static func letterAvatar(for title: String, size: CGFloat = 60) -> UIImage {
        let letter = String(title.trimmed.first ?? "?").uppercased()
        let color = Theme.avatarColor(for: title)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            color.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.45, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let s = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), withAttributes: attrs)
        }
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
