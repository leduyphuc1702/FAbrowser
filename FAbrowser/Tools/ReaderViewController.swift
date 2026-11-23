import UIKit
import WebKit

/// Reader mode: clean article rendering with font size, themes and continuous "next page" loading.
final class ReaderViewController: UIViewController, WKNavigationDelegate {
    enum ReaderTheme: Int, CaseIterable {
        case white, sepia, parchment, kraft, green, night
        var title: String { [L("Default"), L("Sepia"), L("Parchment"), L("Kraft Paper"), L("Eye Care"), L("Night")][rawValue] }
        var background: String { ["#FFFFFF", "#F4ECD8", "#EFE4C8", "#D8C3A0", "#CCE8CF", "#1C1C1E"][rawValue] }
        var text: String { ["#1C1C1E", "#5B4636", "#4A3B28", "#3B2A17", "#253A27", "#C7C7CC"][rawValue] }
    }

    private let articleTitle: String
    private let html: String
    private let baseURL: URL?
    private var nextURL: URL?
    private let isPrivate: Bool

    private let webView: WKWebView
    private var loader: WKWebView?
    private var loadingNext = false
    private let topBar = UIView()
    private let bottomBar = UIStackView()

    private var fontSize: Int {
        get { UserDefaults.standard.object(forKey: "readerFontSize") as? Int ?? 19 }
        set { UserDefaults.standard.set(newValue, forKey: "readerFontSize") }
    }
    private var theme: ReaderTheme {
        get { ReaderTheme(rawValue: UserDefaults.standard.integer(forKey: "readerTheme")) ?? .white }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "readerTheme") }
    }
    private var serif: Bool {
        get { UserDefaults.standard.bool(forKey: "readerSerif") }
        set { UserDefaults.standard.set(newValue, forKey: "readerSerif") }
    }

    init(title: String, html: String, baseURL: URL?, next: URL?, isPrivate: Bool) {
        articleTitle = title
        self.html = html
        self.baseURL = baseURL
        nextURL = next
        self.isPrivate = isPrivate
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { theme == .night ? .lightContent : .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        view.addSubview(webView)
        webView.pinEdges(to: view)

        let close = makeButton("xmark") { [weak self] in self?.dismiss(animated: true) }
        let font = makeButton("textformat.size") { [weak self] in self?.showStyleMenu() }
        font.showsMenuAsPrimaryAction = true
        font.menu = styleMenu()
        let share = makeButton("square.and.arrow.up") { [weak self] in
            if let u = self?.baseURL { self?.share([u]) }
        }
        let next = makeButton("chevron.down.2") { [weak self] in self?.loadNext() }
        next.isEnabled = nextURL != nil
        next.tag = 99

        for v in [close, UIView(), font, share, next] { bottomBar.addArrangedSubview(v) }
        bottomBar.axis = .horizontal
        bottomBar.distribution = .equalSpacing
        bottomBar.isLayoutMarginsRelativeArrangement = true
        bottomBar.layoutMargins = UIEdgeInsets(top: 6, left: 24, bottom: 6, right: 24)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        blur.contentView.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),
        ])
        webView.scrollView.contentInset.bottom = Theme.toolbarHeight
        render()
    }

    private func makeButton(_ symbol: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(Theme.symbol(symbol, size: 19), for: .normal)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    private func styleMenu() -> UIMenu {
        let sizes = UIMenu(title: L("Font Size") + " · \(fontSize)", options: .displayInline, children: [
            UIAction(title: "A−", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.changeFont(-1) },
            UIAction(title: "A+", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.changeFont(1) },
        ])
        let themes = UIMenu(title: L("Theme"), options: .displayInline, children: ReaderTheme.allCases.map { t in
            UIAction(title: t.title, state: t == theme ? .on : .off) { [weak self] _ in self?.theme = t; self?.applyStyle() }
        })
        let family = UIMenu(title: L("Font"), options: .displayInline, children: [
            UIAction(title: L("System"), state: serif ? .off : .on) { [weak self] _ in self?.serif = false; self?.applyStyle() },
            UIAction(title: L("Serif"), state: serif ? .on : .off) { [weak self] _ in self?.serif = true; self?.applyStyle() },
        ])
        return UIMenu(children: [sizes, family, themes])
    }

    private func showStyleMenu() {}

    private func changeFont(_ d: Int) {
        fontSize = max(12, min(36, fontSize + d))
        applyStyle()
    }

    private func css() -> String {
        let fam = serif ? "Georgia, 'Times New Roman', serif" : "-apple-system, system-ui, sans-serif"
        return """
        html{background:\(theme.background);} body{background:\(theme.background);color:\(theme.text);font:\(fontSize)px/1.7 \(fam);
        margin:0;padding:20px 20px 60px;max-width:760px;margin:0 auto;-webkit-text-size-adjust:100%;word-wrap:break-word;}
        h1.__t{font-size:1.45em;line-height:1.3;margin:8px 0 6px;} .__h{color:\(theme.text);opacity:.55;font-size:.72em;margin-bottom:18px;}
        img,video,figure{max-width:100%!important;height:auto!important;border-radius:6px;} a{color:#2E7CF6;}
        pre,code{white-space:pre-wrap;font-size:.85em;} table{max-width:100%;display:block;overflow-x:auto;}
        hr.__sep{border:none;border-top:1px dashed \(theme.text);opacity:.3;margin:36px 0;}
        """
    }

    private func applyStyle() {
        view.backgroundColor = UIColor(hexString: theme.background)
        webView.evaluateJavaScript("document.getElementById('__rs').textContent=\(css().jsEscaped);")
        (bottomBar.arrangedSubviews[2] as? UIButton)?.menu = styleMenu()
        overrideUserInterfaceStyle = theme == .night ? .dark : .light
        setNeedsStatusBarAppearanceUpdate()
    }

    private func render() {
        view.backgroundColor = UIColor(hexString: theme.background)
        overrideUserInterfaceStyle = theme == .night ? .dark : .light
        let esc = articleTitle.replacingOccurrences(of: "<", with: "&lt;")
        let page = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style id="__rs">\(css())</style></head><body>
        <h1 class="__t">\(esc)</h1><div class="__h">\(baseURL?.host ?? "")</div>
        <div id="__c">\(html)</div></body></html>
        """
        webView.loadHTMLString(page, baseURL: baseURL)
    }

    private func loadNext() {
        guard let next = nextURL, !loadingNext else { return }
        loadingNext = true
        Toast.show(L("Loading next page..."))
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        ScriptManager.install(into: cfg.userContentController, config: PageConfig(night: false, eyeCare: false, touchPage: false, rate: 1))
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        wv.customUserAgent = UserAgent.mobile
        wv.navigationDelegate = self
        loader = wv
        wv.load(URLRequest(url: next))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === loader else { return }
        webView.evaluateJavaScript("window.__fa ? __fa.reader() : null") { [weak self] r, _ in
            guard let self else { return }
            self.loadingNext = false
            self.loader = nil
            guard let d = r as? [String: Any], let html = d["html"] as? String else {
                Toast.show(L("No next page"))
                return
            }
            let title = (d["title"] as? String ?? "").replacingOccurrences(of: "<", with: "&lt;")
            let chunk = "<hr class=\"__sep\"><h1 class=\"__t\">\(title)</h1>" + html
            self.webView.evaluateJavaScript("document.getElementById('__c').insertAdjacentHTML('beforeend', \(chunk.jsEscaped));")
            self.nextURL = (d["next"] as? String).flatMap(URL.init(string:))
            (self.bottomBar.viewWithTag(99) as? UIButton)?.isEnabled = self.nextURL != nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === loader { loadingNext = false; loader = nil; Toast.show(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === self.webView, action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
