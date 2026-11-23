import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

enum Theme {
    static let accent = UIColor.dynamic(light: UIColor(hex: 0x2E7CF6), dark: UIColor(hex: 0x4A90FF))
    static let shieldGreen = UIColor(hex: 0x2DBE60)
    static let nextPageGreen = UIColor(hex: 0x2DBE60)
    static let privatePurple = UIColor(hex: 0x8A5CF6)
    static let destructive = UIColor.systemRed

    static let barBackground = UIColor.dynamic(light: .white, dark: UIColor(hex: 0x1C1C1E))
    static let privateBarBackground = UIColor(hex: 0x2B2240)
    static let locationBackground = UIColor.dynamic(light: UIColor(hex: 0xF0F1F3), dark: UIColor(hex: 0x2C2C2E))
    static let privateLocationBackground = UIColor(hex: 0x3D3259)
    static let icon = UIColor.dynamic(light: UIColor(hex: 0x3A3A3C), dark: UIColor(hex: 0xE5E5EA))
    static let iconDisabled = UIColor.dynamic(light: UIColor(hex: 0xC7C7CC), dark: UIColor(hex: 0x545458))
    static let text = UIColor.label
    static let secondaryText = UIColor.secondaryLabel
    static let separator = UIColor.dynamic(light: UIColor(hex: 0xE3E3E6), dark: UIColor(hex: 0x38383A))
    static let homeBackground = UIColor.dynamic(light: UIColor(hex: 0xF7F8FA), dark: UIColor(hex: 0x111113))
    static let menuBackground = UIColor.dynamic(light: UIColor(hex: 0xFBFBFC), dark: UIColor(hex: 0x1F1F21))
    static let cardBackground = UIColor.dynamic(light: .white, dark: UIColor(hex: 0x2A2A2D))
    static let trayBackground = UIColor.dynamic(light: UIColor(hex: 0xE9EAED), dark: UIColor(hex: 0x0E0E10))
    static let privateTrayBackground = UIColor(hex: 0x1D1730)

    static let toolbarHeight: CGFloat = 49
    static let urlBarHeight: CGFloat = 44
    static let topTabsHeight: CGFloat = 34

    static func symbol(_ name: String, size: CGFloat = 20, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Deterministic background color used for letter avatars of sites without favicon.
    static func avatarColor(for string: String) -> UIColor {
        let palette: [UInt32] = [0x2E7CF6, 0x2DBE60, 0xF5A623, 0xE5484D, 0x8A5CF6, 0x14B8A6, 0xEC4899, 0x64748B, 0xF97316, 0x0EA5E9]
        let sum = string.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF }
        return UIColor(hex: palette[sum % palette.count])
    }
}
