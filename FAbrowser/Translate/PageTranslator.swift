import UIKit
import WebKit

/// In-page translation: JS collects text units (visible first), native translates them offline
/// with Apple's Translation framework and writes the results back. Links and layout are kept.
final class PageTranslator {
    weak var browser: BrowserViewController?
    private var running: Set<ObjectIdentifier> = []
    private var pendingMore: Set<ObjectIdentifier> = []

    init(browser: BrowserViewController) { self.browser = browser }

    static let script = #"""
    (function(){
    if (window.__faTr) return;
    var post=function(m){ try{ window.webkit.messageHandlers.fa.postMessage(m);}catch(e){} };
    var SKIP=/^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|CODE|PRE|KBD|SAMP|VAR|SVG|MATH|IFRAME|CANVAS|INPUT|SELECT|OPTION|TEMPLATE|OBJECT|VIDEO|AUDIO)$/;
    var INLINE=/^(A|ABBR|B|BDI|BDO|BR|CITE|DFN|EM|FONT|I|LABEL|MARK|Q|S|SMALL|SPAN|STRONG|SUB|SUP|TIME|U|WBR|IMG)$/;
    var units=[], seen=new WeakSet(), active=false, observer=null, timer=null, applying=false;
    function letters(s){ return /[A-Za-z\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF\u0590-\u06FF\u0E00-\u0E7F\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]/.test(s); }
    function blockOf(n){ var e=n.parentElement; while(e && e!==document.body && INLINE.test(e.tagName)) e=e.parentElement; return e||document.body; }
    function linkOf(n){ var e=n.parentElement; while(e && e!==document.body){ if(e.tagName==='A') return e; e=e.parentElement; } return null; }
    function scan(){
      if(!document.body) return;
      var w=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {acceptNode:function(n){
        if(seen.has(n)) return NodeFilter.FILTER_REJECT;
        var p=n.parentElement; if(!p) return NodeFilter.FILTER_REJECT;
        for(var e=p;e&&e!==document.body;e=e.parentElement){ if(SKIP.test(e.tagName)||e.isContentEditable||e.getAttribute('translate')==='no'||e.classList.contains('notranslate')) return NodeFilter.FILTER_REJECT; }
        var t=n.nodeValue; if(!t||t.trim().length<2||!letters(t)) return NodeFilter.FILTER_SKIP;
        return NodeFilter.FILTER_ACCEPT; }});
      var groups=new Map(), order=[];
      while(w.nextNode()){ var n=w.currentNode; seen.add(n); var b=blockOf(n); if(!groups.has(b)){ groups.set(b,[]); order.push(b); } groups.get(b).push(n); }
      order.forEach(function(b){ var nodes=groups.get(b);
        var sameLink=nodes.every(function(n){ return linkOf(n)===linkOf(nodes[0]); });
        if(nodes.length>1 && sameLink){ units.push({el:b, nodes:nodes, orig:nodes.map(function(n){return n.nodeValue;}), done:false}); }
        else nodes.forEach(function(n){ units.push({el:n.parentElement, nodes:[n], orig:[n.nodeValue], done:false}); }); });
    }
    function textOf(u){ return u.orig.join('').replace(/\s+/g,' ').trim(); }
    function dist(u){ var r=u.el.getBoundingClientRect(); if(!r.width&&!r.height) return 1e9; var h=window.innerHeight;
      if(r.bottom>=0 && r.top<=h) return 0; return r.top>h ? r.top-h : -r.bottom+h*0.5; }
    window.__faTr={
      start:function(){ active=true; scan();
        if(!observer){ observer=new MutationObserver(function(){ if(applying||!active) return; clearTimeout(timer); timer=setTimeout(function(){ var before=units.length; scan(); if(units.length>before) post({type:'trMore'}); }, 700); });
          observer.observe(document.body,{childList:true,subtree:true,characterData:false}); }
        return units.length; },
      sample:function(){ var t;
        // Already translated (e.g. restored by Back): detect from the original text, not our output.
        if(units.some(function(u){ return u.done; })){ var o=[]; for(var i=0;i<units.length&&o.length<400;i++) o.push(units[i].orig.join('')); t=o.join('\n'); }
        else t=(document.body&&document.body.innerText)||'';
        return {lang:(document.documentElement.lang||''), text:(document.title+'\n'+t).slice(0,3000), pid:pid}; },
      collect:function(max){ var list=[]; for(var i=0;i<units.length;i++){ if(!units[i].done && !units[i].sent) list.push(i); }
        list.sort(function(a,b){ return dist(units[a])-dist(units[b]); });
        return list.slice(0,max).map(function(i){ units[i].sent=true; return {i:i, t:textOf(units[i])}; }); },
      apply:function(items){ applying=true;
        items.forEach(function(it){ var u=units[it.i]; if(!u) return; var first=u.orig[0], lead=(first.match(/^\s*/)||[''])[0], last=u.orig[u.orig.length-1], trail=(last.match(/\s*$/)||[''])[0];
          if(u.nodes.length===1) u.nodes[0].nodeValue=lead+it.t+trail;
          else { u.nodes[0].nodeValue=lead+it.t+trail; for(var k=1;k<u.nodes.length;k++) u.nodes[k].nodeValue=''; }
          u.done=true; });
        if(observer) observer.takeRecords(); applying=false; },
      unsend:function(ids){ ids.forEach(function(i){ if(units[i]) units[i].sent=false; }); },
      restore:function(){ active=false; applying=true; units.forEach(function(u){ if(u.done) u.nodes.forEach(function(n,k){ n.nodeValue=u.orig[k]; }); u.done=false; u.sent=false; });
        if(observer){ observer.takeRecords(); observer.disconnect(); observer=null; } applying=false; },
      pending:function(){ var n=0; units.forEach(function(u){ if(!u.done) n++; }); return n; },
      isActive:function(){ return active; }
    };
    var st=null; window.addEventListener('scroll', function(){ if(!active) return; clearTimeout(st); st=setTimeout(function(){ post({type:'trMore'}); }, 250); }, {passive:true});
    var pid=Math.random().toString(36).slice(2);
    // Start as soon as the DOM is parsed instead of waiting for images and ads (didFinish).
    function ready(){ post({type:'trReady'}); }
    if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', ready); else ready();
    window.addEventListener('pageshow', function(e){ if(e.persisted) post({type:'trReady'}); });
    })();
    """#

    // MARK: Control

    private var target: String { TranslateLanguages.normalize(Prefs.translateTarget) }

    private func isCurrent(_ tab: Tab) -> Bool { tab === browser?.currentTab }

    /// Reads a text sample of the page and detects its language.
    private func detect(tab: Tab, completion: @escaping (_ source: String?, _ confident: Bool, _ pid: String, _ text: String) -> Void) {
        tab.webView?.evaluateJavaScript("window.__faTr ? __faTr.sample() : null") { result, _ in
            guard let d = result as? [String: Any] else { completion(nil, false, "", ""); return }
            let text = d["text"] as? String ?? ""
            let htmlLang = (d["lang"] as? String).map(TranslateLanguages.normalize) ?? ""
            let detected = TranslateLanguages.detect(text)
            let source = detected ?? (htmlLang.isEmpty ? nil : htmlLang)
            let confident = source != nil && (text.count >= 60 && TranslateLanguages.detect(text, confidenceFor: source!) >= 0.6 || (!htmlLang.isEmpty && htmlLang == source))
            completion(source, confident, d["pid"] as? String ?? "", text)
        }
    }

    /// Translates the current page of `tab` (menu, suggestion bar, or automatically).
    @MainActor
    func translate(tab: Tab, userInitiated: Bool) {
        guard let wv = tab.webView, wv.url?.isWebURL == true else { return }
        guard TranslationService.isAvailable else {
            if userInitiated { browser?.showAlert(L("Translate"), message: TranslationError.unavailableOS.localizedDescription) }
            return
        }
        detect(tab: tab) { [weak self, weak tab] source, _, _, _ in
            guard let self, let tab else { return }
            guard let source else {
                if userInitiated { Toast.show(L("Can't detect page language")) }
                return
            }
            if source == self.target {
                if userInitiated { Toast.show(TranslationError.sameLanguage.localizedDescription) } else if self.isCurrent(tab) { self.browser?.translateBar.hide() }
                return
            }
            if userInitiated { Prefs.autoTranslateLangs.insert(source) }
            self.start(tab: tab, source: source, userInitiated: userInitiated)
        }
    }

    @MainActor
    private func start(tab: Tab, source: String, userInitiated: Bool) {
        guard let wv = tab.webView else { return }
        let target = self.target
        tab.translateActive = true
        tab.translatedFrom = source
        tab.translateSuggested = nil
        if isCurrent(tab) { browser?.translateBar.show(from: source, to: target, progress: 0) }
        Task { @MainActor in
            let status = await TranslationService.shared.status(from: source, to: target)
            // Automatic runs never prompt or alert: without an installed pack, offer it instead.
            if !userInitiated && status != .installed {
                tab.translateActive = false
                tab.translateSuggested = source
                if self.isCurrent(tab) { self.browser?.translateBar.showSuggestion(from: source, to: target, original: false) }
                return
            }
            if status == .unsupported {
                self.fail(tab: tab, TranslationError.unsupportedPair)
                return
            }
            if status == .downloadable, let presenter = self.browser {
                do { try await TranslationService.shared.prepare(from: source, to: target, presenter: presenter) } catch {
                    self.fail(tab: tab, error)
                    return
                }
            }
            wv.evaluateJavaScript("__faTr.start()") { _, _ in self.pump(tab: tab, first: true) }
        }
    }

    @MainActor
    private func fail(tab: Tab, _ error: Error) {
        tab.translateActive = false
        browser?.translateBar.hide()
        browser?.showAlert(L("Translate"), message: error.localizedDescription)
    }

    /// Translates batches until the page has nothing left (visible text first). The first batch
    /// is small so the visible part of the page changes quickly.
    @MainActor
    func pump(tab: Tab, first: Bool = false) {
        guard let wv = tab.webView, tab.translateActive, let source = tab.translatedFrom else { return }
        let id = ObjectIdentifier(tab)
        if running.contains(id) { pendingMore.insert(id); return }
        running.insert(id)
        let target = self.target
        wv.evaluateJavaScript("__faTr.collect(\(first ? 16 : 60))") { [weak self, weak tab] result, _ in
            guard let self, let tab else { return }
            let items = result as? [[String: Any]] ?? []
            guard !items.isEmpty else {
                self.running.remove(id)
                self.updateProgress(tab: tab, done: true)
                if self.pendingMore.remove(id) != nil { self.pump(tab: tab) }
                return
            }
            let ids = items.compactMap { $0["i"] as? Int }
            let texts = items.map { $0["t"] as? String ?? "" }
            Task { @MainActor in
                do {
                    let skip = texts.map { t in t.count >= 24 && TranslateLanguages.detect(t) == target }
                    let toTranslate = zip(texts, skip).filter { !$0.1 }.map(\.0)
                    let translated = try await TranslationService.shared.translate(toTranslate, from: source, to: target)
                    var out: [[String: Any]] = []
                    var j = 0
                    for (k, id) in ids.enumerated() {
                        if skip[k] { out.append(["i": id, "t": texts[k]]) } else { out.append(["i": id, "t": j < translated.count ? translated[j] : texts[k]]); j += 1 }
                    }
                    let json = (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    guard tab.translateActive else { self.running.remove(id); return }
                    wv.evaluateJavaScript("__faTr.apply(\(json))") { _, _ in
                        self.running.remove(id)
                        self.updateProgress(tab: tab, done: false)
                        self.pump(tab: tab)
                    }
                } catch {
                    self.running.remove(id)
                    let json = (try? JSONSerialization.data(withJSONObject: ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    wv.evaluateJavaScript("__faTr.unsend(\(json))", completionHandler: nil)
                    self.fail(tab: tab, error)
                }
            }
        }
    }

    private func updateProgress(tab: Tab, done: Bool) {
        guard let browser, tab === browser.currentTab, tab.translateActive, let source = tab.translatedFrom else { return }
        tab.webView?.evaluateJavaScript("__faTr.pending()") { r, _ in
            let pending = r as? Int ?? 0
            browser.translateBar.show(from: source, to: Prefs.translateTarget, progress: done || pending == 0 ? 1 : 0.5)
        }
    }

    /// Stops translating this tab and puts the original text back.
    func restore(tab: Tab) {
        tab.translateActive = false
        tab.translatedFrom = nil
        tab.webView?.evaluateJavaScript("window.__faTr && __faTr.restore()")
        if isCurrent(tab) { browser?.translateBar.hide() }
    }

    /// "Show Original": this page only; the bar stays so the user can switch back.
    func showOriginal(tab: Tab) {
        let source = tab.translatedFrom
        restore(tab: tab)
        tab.translateSuggested = source
        tab.translateHandled = nil
        if isCurrent(tab), let source { browser?.translateBar.showSuggestion(from: source, to: target, original: true) }
    }

    /// Closing the bar: stop translating this language automatically.
    func dismiss(tab: Tab) {
        if let source = tab.translatedFrom ?? tab.translateSuggested {
            tab.translateDeclined.insert(source)
            Prefs.autoTranslateLangs.remove(source)
        }
        tab.translateSuggested = nil
        restore(tab: tab)
    }

    /// Accepting the suggestion: translate now, and every later page in that language.
    @MainActor
    func accept(tab: Tab) {
        guard let source = tab.translateSuggested ?? tab.translatedFrom else { translate(tab: tab, userInitiated: true); return }
        Prefs.autoTranslateLangs.insert(source)
        tab.translateDeclined.remove(source)
        start(tab: tab, source: source, userInitiated: true)
    }

    /// Called when a page's DOM is ready, when it is restored from the back/forward cache,
    /// and after it finishes loading. Continues translation or offers it.
    @MainActor
    func pageLoaded(tab: Tab) {
        guard TranslationService.isAvailable, let wv = tab.webView, wv.url?.isWebURL == true else { return }
        if tab.translateActive && !Prefs.translateAutoContinue {
            restore(tab: tab)
            return
        }
        detect(tab: tab) { [weak self, weak tab] source, confident, pid, text in
            guard let self, let tab else { return }
            let key = pid + "|" + (tab.translateActive ? "1" : "0")
            if !pid.isEmpty && tab.translateHandled == key { return }
            tab.translateHandled = key
            tab.translateSuggested = nil
            let target = self.target
            guard let source, source != target else {
                if self.isCurrent(tab) { self.browser?.translateBar.hide() }
                return
            }
            if tab.translateActive || Prefs.autoTranslateLangs.contains(source) {
                self.start(tab: tab, source: source, userInitiated: false)
                tab.translateHandled = pid + "|1"
                return
            }
            guard Prefs.translateSuggest, confident, !tab.translateDeclined.contains(source) else {
                if self.isCurrent(tab) { self.browser?.translateBar.hide() }
                return
            }
            tab.translateSuggested = source
            if self.isCurrent(tab) { self.browser?.translateBar.showSuggestion(from: source, to: target, original: false) }
            TranslationService.shared.warmUp(from: source, to: target, sample: text)
        }
    }
}

/// Banner shown at the top of the web content while a page is translated.
final class TranslateBar: UIView {
    enum Mode { case translating, suggest, original }
    private(set) var mode = Mode.translating
    var onShowOriginal: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onClose: (() -> Void)?
    var onChangeTarget: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    private let icon = UIImageView(image: Theme.symbol("translate", size: 15, weight: .semibold))
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let originalButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.barBackground.withAlphaComponent(0.97)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        icon.tintColor = Theme.accent
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.text
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(changeTarget)))
        originalButton.setTitle(L("Show Original"), for: .normal)
        originalButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        originalButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.mode == .translating { self.onShowOriginal?() } else { self.onTranslate?() }
        }, for: .touchUpInside)
        closeButton.setImage(Theme.symbol("xmark", size: 12, weight: .bold), for: .normal)
        closeButton.tintColor = Theme.secondaryText
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        spinner.hidesWhenStopped = true
        let stack = UIStackView(arrangedSubviews: [icon, label, spinner, UIView(), originalButton, closeButton])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changeTarget() { onChangeTarget?() }

    func show(from: String, to: String, progress: Double) {
        mode = .translating
        label.text = "\(TranslateLanguages.name(from)) → \(TranslateLanguages.name(to))"
        originalButton.setTitle(L("Show Original"), for: .normal)
        if progress < 1 { spinner.startAnimating() } else { spinner.stopAnimating() }
        appear()
    }

    /// "This page is in X. Translate to Y?" — or, after Show Original, a way back.
    func showSuggestion(from: String, to: String, original: Bool) {
        mode = original ? .original : .suggest
        label.text = original ? TranslateLanguages.name(from) : LF("Page is in %@", TranslateLanguages.localizedName(from))
        originalButton.setTitle(original ? L("Translate") : LF("Translate to %@", TranslateLanguages.localizedName(to)), for: .normal)
        spinner.stopAnimating()
        appear()
    }

    private func appear() {
        guard isHidden else { return }
        isHidden = false
        alpha = 0
        onVisibilityChange?()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
    }

    func hide() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            self.isHidden = true
            self.onVisibilityChange?()
        }
    }
}
