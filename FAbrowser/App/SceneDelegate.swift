import UIKit
import LocalAuthentication

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: BrowserViewController!
    private var coverView: UIView?
    private var lockView: UIView?
    private var pendingShortcut: UIApplicationShortcutItem?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        browser = BrowserViewController()
        window.rootViewController = browser
        window.tintColor = Theme.accent
        window.overrideUserInterfaceStyle = Prefs.themeMode.style
        window.makeKeyAndVisible()
        self.window = window

        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged(_:)), name: .prefsChanged, object: nil)

        if Prefs.requireUnlock || Prefs.caroLockPattern != nil { showLock() }
        if let url = connectionOptions.urlContexts.first?.url {
            browser.whenTabsReady { self.handle(url: url) }
        }
        if let item = connectionOptions.shortcutItem { pendingShortcut = item }
        #if DEBUG
        browser.whenTabsReady { [browser] in DebugLaunch.run(browser!) }
        #endif
    }

    @objc private func prefsChanged(_ n: Notification) {
        if (n.object as? String) == "themeMode" {
            window?.overrideUserInterfaceStyle = Prefs.themeMode.style
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let cover = coverView {
            coverView = nil
            UIView.animate(withDuration: 0.15, animations: { cover.alpha = 0 }) { _ in cover.removeFromSuperview() }
        }
        applyDisguiseIconOnce()
        if let item = pendingShortcut {
            pendingShortcut = nil
            browser.whenTabsReady { [browser] in browser?.handleShortcut(item.type) }
        }
        browser.whenTabsReady { [browser] in browser?.checkClipboardForURL() }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        if Prefs.coverInBackground || browser.tabManager.isPrivate { showCover() }
    }

    /// Blurs the whole window so the App Switcher shows the tabs' colors but no readable content.
    /// A caro lock screen is left visible: it gives nothing away.
    func showCover() {
        guard coverView == nil, !(lockView is CaroLockView), let window else { return }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        blur.frame = window.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(blur)
        coverView = blur
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browser.tabManager.saveNow()
        HistoryStore.shared.flush()
        if Prefs.requireUnlock || Prefs.caroLockPattern != nil { showLock() }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        (lockView as? LockView)?.authenticate()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if Prefs.clearHistoryOnExit { HistoryStore.shared.clear(since: nil); HistoryStore.shared.flush() }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        browser.whenTabsReady { self.handle(url: url) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        browser.whenTabsReady { [browser] in browser?.handleShortcut(shortcutItem.type) }
        completionHandler(true)
    }

    private func handle(url: URL) {
        if url.isFileURL {
            browser.importFile(url)
            return
        }
        if url.scheme == "fabrowser" {
            // fabrowser://open?url=https://... or fabrowser://https://...
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let target = comps.queryItems?.first(where: { $0.name == "url" })?.value, let u = URL(string: target) {
                browser.openInNewTab(u)
            } else {
                let rest = url.absoluteString.replacingOccurrences(of: "fabrowser://", with: "")
                if let u = URL.fromUserInput(rest) { browser.openInNewTab(u) }
            }
            return
        }
        browser.openInNewTab(url)
    }

    func showLock() {
        guard lockView == nil, let window else { return }
        window.endEditing(true)
        let unlock = { [weak self] in
            UIView.animate(withDuration: 0.2, animations: { self?.lockView?.alpha = 0 }) { _ in
                self?.lockView?.removeFromSuperview()
                self?.lockView = nil
            }
        }
        if let pattern = Prefs.caroLockPattern {
            let lv = CaroLockView(frame: window.bounds, pattern: pattern)
            lv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            lv.onUnlock = unlock
            window.addSubview(lv)
            lockView = lv
            coverView?.removeFromSuperview()
            coverView = nil
            return
        }
        let lv = LockView(frame: window.bounds)
        lv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lv.onUnlock = unlock
        window.addSubview(lv)
        lockView = lv
        if UIApplication.shared.applicationState == .active { lv.authenticate() }
    }

    /// The "Caro" build (FADisguise in Info.plist) switches to the caro icon on its first launch.
    private func applyDisguiseIconOnce() {
        let key = "disguiseIconApplied"
        guard Bundle.main.object(forInfoDictionaryKey: "FADisguise") as? Bool == true,
              !UserDefaults.standard.bool(forKey: key), UIApplication.shared.supportsAlternateIcons else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            UIApplication.shared.setAlternateIconName(AppIcon.caro.iconName) { _ in }
        }
    }
}

/// Full-screen lock requiring Face ID / Touch ID / passcode.
final class LockView: UIView {
    var onUnlock: (() -> Void)?
    private var authenticating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.homeBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        let icon = UIImageView(image: Theme.symbol("lock.fill", size: 44))
        icon.tintColor = Theme.accent
        let button = UIButton(type: .system)
        button.setTitle(L("Unlock"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.addTarget(self, action: #selector(authenticate), for: .touchUpInside)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(button)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func authenticate() {
        guard !authenticating else { return }
        authenticating = true
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            authenticating = false
            onUnlock?()
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Authentication")) { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                if ok { self.onUnlock?() }
            }
        }
    }
}
