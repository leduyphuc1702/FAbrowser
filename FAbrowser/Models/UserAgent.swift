import UIKit

enum UserAgent {
    private static var osVersion: String {
        UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
    }

    private static var safariVersion: String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"
        return "\(major).0"
    }

    static var safariMobile: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad; CPU OS" : "iPhone; CPU iPhone OS"
        return "Mozilla/5.0 (\(device) \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    static var chromeMobile: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1"
    }

    static let android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    static let macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let windowsChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static let mobileOptions = ["Safari", "Chrome", "Android", L("Custom")]
    static let desktopOptions = ["Mac Safari", "Windows Chrome", L("Custom")]

    static var mobile: String {
        switch Prefs.mobileUA {
        case 1: return chromeMobile
        case 2: return android
        case 3: return Prefs.customMobileUA.trimmed.isEmpty ? safariMobile : Prefs.customMobileUA
        default: return safariMobile
        }
    }

    static var desktop: String {
        switch Prefs.desktopUA {
        case 1: return windowsChrome
        case 2: return Prefs.customDesktopUA.trimmed.isEmpty ? macSafari : Prefs.customDesktopUA
        default: return macSafari
        }
    }
}
