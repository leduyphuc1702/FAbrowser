import UIKit

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

extension Notification.Name {
    static let prefsChanged = Notification.Name("FAPrefsChanged")
    static let bookmarksChanged = Notification.Name("FABookmarksChanged")
    static let historyChanged = Notification.Name("FAHistoryChanged")
    static let downloadsChanged = Notification.Name("FADownloadsChanged")
    static let searchEnginesChanged = Notification.Name("FASearchEnginesChanged")
    static let extensionsChanged = Notification.Name("FAExtensionsChanged")
    static let adBlockRulesChanged = Notification.Name("FAAdBlockRulesChanged")
}

// MARK: - URL

extension URL {
    var isWebURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    var normalizedHost: String? {
        guard var h = host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Text shown in the URL bar when not editing.
    var displayString: String {
        if isFileURL { return lastPathComponent }
        return normalizedHost ?? absoluteString
    }

    /// Builds a URL from what the user typed, or nil when it should be treated as a search query.
    static func fromUserInput(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let lower = trimmed.lowercased()
        for prefix in ["http://", "https://", "file://", "about:", "data:", "javascript:"] where lower.hasPrefix(prefix) {
            return URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        }
        if lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") {
            return URL(string: "http://" + trimmed)
        }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isIP = hostOnly.split(separator: ".").count == 4 && hostOnly.allSatisfy { $0.isNumber || $0 == "." }
        let hasTLD: Bool = {
            let parts = hostOnly.split(separator: ".")
            guard parts.count >= 2, let tld = parts.last, tld.count >= 2 else { return false }
            return tld.allSatisfy { $0.isLetter } && parts.allSatisfy { !$0.isEmpty }
        }()
        guard isIP || hasTLD else { return nil }
        return URL(string: (isIP ? "http://" : "https://") + trimmed)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var jsEscaped: String {
        let data = (try? JSONSerialization.data(withJSONObject: [self])) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

// MARK: - FileManager

extension FileManager {
    var documentsURL: URL { urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var appSupportURL: URL {
        let url = urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FAbrowser", isDirectory: true)
        try? createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var downloadsURL: URL {
        let url = documentsURL.appendingPathComponent("Downloads", isDirectory: true)
        try? createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func uniqueURL(for url: URL) -> URL {
        guard fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    func sizeOfItem(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let e = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

// MARK: - JSON persistence

enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = FileManager.default.appSupportURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = FileManager.default.appSupportURL.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - UIView

extension UIView {
    func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func snapshotImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in drawHierarchy(in: bounds, afterScreenUpdates: false) }
    }
}

// MARK: - Toast

enum Toast {
    static func show(_ message: String, in view: UIView? = nil, duration: TimeInterval = 1.6) {
        guard let host = view ?? UIApplication.shared.keyWindowCompat else { return }
        let label = PaddingLabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.25, delay: duration, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }

    /// Toast with a single trailing button, e.g. "Pop-up blocked · Open".
    static func show(_ message: String, action: String, duration: TimeInterval = 3.5, handler: @escaping () -> Void) {
        guard let host = UIApplication.shared.keyWindowCompat else { return }
        let box = UIView()
        box.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        box.layer.cornerRadius = 12
        let label = UILabel()
        label.text = message
        label.numberOfLines = 2
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        let button = UIButton(type: .system)
        button.setTitle(action, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.tintColor = UIColor(hex: 0x6AB0FF)
        button.addAction(UIAction { _ in
            handler()
            UIView.animate(withDuration: 0.2, animations: { box.alpha = 0 }) { _ in box.removeFromSuperview() }
        }, for: .touchUpInside)
        [label, button].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; box.addSubview($0) }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.alpha = 0
        host.addSubview(box)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            box.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.9),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
            button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14),
            button.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        UIView.animate(withDuration: 0.2) { box.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            UIView.animate(withDuration: 0.25, animations: { box.alpha = 0 }) { _ in box.removeFromSuperview() }
        }
    }
}

final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

extension UIApplication {
    var keyWindowCompat: UIWindow? {
        connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
    }
}

// MARK: - Alerts

extension UIViewController {
    func showAlert(_ title: String?, message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("OK"), style: .default))
        present(a, animated: true)
    }

    func confirm(_ title: String?, message: String? = nil, action: String = L("OK"), destructive: Bool = false, handler: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in handler() })
        present(a, animated: true)
    }

    func promptText(_ title: String?, message: String? = nil, placeholders: [String], values: [String] = [], keyboard: UIKeyboardType = .default, handler: @escaping ([String]) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (i, p) in placeholders.enumerated() {
            a.addTextField { tf in
                tf.placeholder = p
                tf.text = i < values.count ? values[i] : nil
                tf.clearButtonMode = .whileEditing
                tf.keyboardType = keyboard
                tf.autocapitalizationType = .none
            }
        }
        a.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("OK"), style: .default) { _ in
            handler(a.textFields?.map { $0.text ?? "" } ?? [])
        })
        present(a, animated: true)
    }

    /// Presents an action sheet anchored correctly on iPad.
    func presentSheet(_ sheet: UIAlertController, from source: Any? = nil) {
        if let pop = sheet.popoverPresentationController {
            if let v = source as? UIView {
                pop.sourceView = v
                pop.sourceRect = v.bounds
            } else if let b = source as? UIBarButtonItem {
                pop.barButtonItem = b
            } else {
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
        }
        present(sheet, animated: true)
    }

    func share(_ items: [Any], from source: Any? = nil) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            if let v = source as? UIView { pop.sourceView = v; pop.sourceRect = v.bounds }
            else { pop.sourceView = view; pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1) }
        }
        present(vc, animated: true)
    }

    var topMost: UIViewController {
        var vc: UIViewController = self
        while let p = vc.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}
