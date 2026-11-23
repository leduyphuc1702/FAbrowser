import WebKit

struct FilterSubscription: Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var enabled: Bool = true
    var lastUpdate: Date?
    var ruleCount: Int = 0
}

/// Ad blocking built on WKContentRuleList (network + cosmetic) plus user element-hiding rules
/// injected as CSS by ScriptManager.
final class AdBlocker {
    static let shared = AdBlocker()

    private let subsFile = "filter_subscriptions.json"
    private let userRulesFile = "user_hide_rules.json"
    private let whitelistFile = "adblock_whitelist.json"
    private let store = WKContentRuleListStore.default()!

    private(set) var subscriptions: [FilterSubscription]
    /// host -> CSS selectors hidden by the user ("Hide Element" / "Mark Ad").
    private(set) var userRules: [String: [String]]
    private(set) var whitelist: [String]

    private(set) var adList: WKContentRuleList?
    private(set) var noImageList: WKContentRuleList?
    private var compiling = false
    private var pendingRecompile = false

    /// Lists shipped in the app bundle (Resources/Filters) so blocking works offline from the first launch.
    static let bundledFilters: [String: String] = [
        "https://easylist.to/easylist/easylist.txt": "easylist",
        "https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn.txt": "abpvn",
    ]

    static let presetSubscriptions: [FilterSubscription] = [
        FilterSubscription(title: "EasyList", url: "https://easylist.to/easylist/easylist.txt", enabled: true),
        FilterSubscription(title: "ABPVN (Tiếng Việt)", url: "https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn.txt", enabled: true),
        FilterSubscription(title: "EasyList China (中文)", url: "https://easylist-downloads.adblockplus.org/easylistchina.txt", enabled: false),
        FilterSubscription(title: "Japanese Filters (日本語)", url: "https://raw.githubusercontent.com/k2jp/abp-japanese-filters/master/abpjf.txt", enabled: false),
        FilterSubscription(title: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: false),
    ]

    private static let presetVersion = 2

    private init() {
        var subs = JSONStore.load([FilterSubscription].self, from: subsFile) ?? AdBlocker.presetSubscriptions
        if UserDefaults.standard.integer(forKey: "filterPresetVersion") < AdBlocker.presetVersion {
            let presetURLs = Set(AdBlocker.presetSubscriptions.map(\.url))
            let custom = subs.filter { !presetURLs.contains($0.url) && !$0.url.contains("abpvn.com/android") && $0.url != "https://abpvn.com/android/abpvn.txt" }
            subs = AdBlocker.presetSubscriptions.map { p in subs.first { $0.url == p.url }.map { var e = $0; e.enabled = p.enabled; return e } ?? p } + custom
            UserDefaults.standard.set(AdBlocker.presetVersion, forKey: "filterPresetVersion")
            JSONStore.save(subs, to: subsFile)
        }
        subscriptions = subs
        userRules = JSONStore.load([String: [String]].self, from: userRulesFile) ?? [:]
        whitelist = JSONStore.load([String].self, from: whitelistFile) ?? []
    }

    // MARK: Compile

    /// Bump when ABPConverter output or built-in rules change so cached lists are rebuilt.
    private static let converterVersion = 3
    private static let fingerprintKey = "adBlockListFingerprint"

    private var fingerprint: String {
        let subs = subscriptions.filter { $0.enabled }.map { "\($0.id)@\($0.lastUpdate?.timeIntervalSince1970 ?? 0)" }
        return (["v\(AdBlocker.converterVersion)"] + subs + whitelist.sorted()).joined(separator: "|")
    }

    /// Loads the previously compiled lists from the store when they still match the current
    /// subscriptions, so the first page after launch is filtered; compiles only when needed.
    func prepare(completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        store.compileContentRuleList(forIdentifier: "fa.noimage", encodedContentRuleList: AdBlocker.noImageJSON) { [weak self] list, _ in
            self?.noImageList = list
            group.leave()
        }
        group.enter()
        let current = fingerprint
        store.lookUpContentRuleList(forIdentifier: "fa.adblock") { [weak self] list, _ in
            guard let self else { group.leave(); return }
            if let list, UserDefaults.standard.string(forKey: AdBlocker.fingerprintKey) == current {
                self.adList = list
                group.leave()
            } else {
                self.compileAdList { group.leave() }
            }
        }
        group.notify(queue: .main) { completion?() }
    }

    func recompile() {
        compileAdList {
            NotificationCenter.default.post(name: .adBlockRulesChanged, object: nil)
        }
    }

    private func compileAdList(completion: @escaping () -> Void) {
        if compiling { pendingRecompile = true; completion(); return }
        compiling = true
        let subs = subscriptions.filter { $0.enabled }
        let whitelist = self.whitelist
        let fp = fingerprint
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.seedBundledFilters(subs)
            var network: [[String: Any]] = AdBlocker.builtinNetworkRules
            var cosmetic: [[String: Any]] = []
            for s in subs {
                if let data = try? Data(contentsOf: self.convertedFile(for: s)),
                   let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for r in rules {
                        if (r["action"] as? [String: Any])?["type"] as? String == "css-display-none" { cosmetic.append(r) } else { network.append(r) }
                    }
                }
            }
            network = Array(network.prefix(100_000))
            cosmetic = Array(cosmetic.prefix(40_000))
            var tail: [[String: Any]] = []
            if !whitelist.isEmpty {
                tail.append(["trigger": ["url-filter": ".*", "if-domain": whitelist.map { "*" + $0 }], "action": ["type": "ignore-previous-rules"]])
            }
            let full = network + cosmetic + tail
            let networkOnly = network + tail
            self.compile(rules: full) { list in
                if let list {
                    UserDefaults.standard.set(fp, forKey: AdBlocker.fingerprintKey)
                    self.finishCompile(list, completion)
                } else {
                    UserDefaults.standard.removeObject(forKey: AdBlocker.fingerprintKey)
                    self.compile(rules: networkOnly) { list2 in self.finishCompile(list2, completion) }
                }
            }
        }
    }

    /// Converts bundled copies of enabled lists that have never been downloaded.
    private func seedBundledFilters(_ subs: [FilterSubscription]) {
        for s in subs where !FileManager.default.fileExists(atPath: convertedFile(for: s).path) {
            guard let name = AdBlocker.bundledFilters[s.url],
                  let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Filters") ?? Bundle.main.url(forResource: name, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rules = ABPConverter.convert(text)
            guard let out = try? JSONSerialization.data(withJSONObject: rules) else { continue }
            try? out.write(to: convertedFile(for: s), options: .atomic)
            let id = s.id
            DispatchQueue.main.async {
                guard let i = self.subscriptions.firstIndex(where: { $0.id == id }) else { return }
                self.subscriptions[i].ruleCount = rules.count
                self.setSubscriptions(self.subscriptions)
            }
        }
    }

    /// Refreshes enabled subscriptions older than four days ("Auto Update Filters").
    func autoUpdateIfNeeded() {
        guard Prefs.adBlock, Prefs.filterAutoUpdate else { return }
        let stale = Date().addingTimeInterval(-4 * 86400)
        for s in subscriptions where s.enabled && (s.lastUpdate ?? .distantPast) < stale {
            update(subscription: s.id) { _ in }
        }
    }

    private func finishCompile(_ list: WKContentRuleList?, _ completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            if let list { self.adList = list }
            self.compiling = false
            completion()
            if self.pendingRecompile {
                self.pendingRecompile = false
                self.recompile()
            }
        }
    }

    private func compile(rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else {
            completion(nil); return
        }
        DispatchQueue.main.async {
            self.store.compileContentRuleList(forIdentifier: "fa.adblock", encodedContentRuleList: json) { list, error in
                if let error { print("AdBlock compile error:", error) }
                completion(list)
            }
        }
    }

    /// Re-applies the rule lists according to current preferences and the page host.
    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if Prefs.adBlock, let adList { controller.add(adList) }
        if Prefs.noImage, let noImageList { controller.add(noImageList) }
    }

    // MARK: Whitelist

    func isWhitelisted(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return whitelist.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setWhitelisted(_ host: String, _ on: Bool) {
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        whitelist.removeAll { $0 == h }
        if on { whitelist.append(h) }
        JSONStore.save(whitelist, to: whitelistFile)
        recompile()
    }

    // MARK: User element hiding rules

    func addUserRule(host: String, selector: String) {
        let h = host.lowercased()
        var list = userRules[h] ?? []
        if !list.contains(selector) { list.append(selector) }
        userRules[h] = list
        saveUserRules()
    }

    func removeUserRule(host: String, selector: String) {
        userRules[host]?.removeAll { $0 == selector }
        if userRules[host]?.isEmpty == true { userRules[host] = nil }
        saveUserRules()
    }

    func clearUserRules(host: String? = nil) {
        if let host { userRules[host] = nil } else { userRules.removeAll() }
        saveUserRules()
    }

    var userRuleCount: Int { userRules.values.reduce(0) { $0 + $1.count } }

    private func saveUserRules() {
        JSONStore.save(userRules, to: userRulesFile)
        NotificationCenter.default.post(name: .adBlockRulesChanged, object: nil)
    }

    // MARK: Subscriptions

    func setSubscriptions(_ subs: [FilterSubscription]) {
        subscriptions = subs
        JSONStore.save(subscriptions, to: subsFile)
    }

    private func convertedFile(for s: FilterSubscription) -> URL {
        FileManager.default.appSupportURL.appendingPathComponent("filter_\(s.id.uuidString).json")
    }

    func update(subscription id: UUID, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }), let url = URL(string: subscriptions[idx].url) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(.failure(error ?? URLError(.cannotDecodeContentData))) }
                return
            }
            let rules = ABPConverter.convert(text)
            if let out = try? JSONSerialization.data(withJSONObject: rules) {
                try? out.write(to: self.convertedFile(for: self.subscriptions[idx]), options: .atomic)
            }
            DispatchQueue.main.async {
                self.subscriptions[idx].lastUpdate = Date()
                self.subscriptions[idx].ruleCount = rules.count
                self.setSubscriptions(self.subscriptions)
                self.recompile()
                completion(.success(rules.count))
            }
        }.resume()
    }

    func removeSubscription(id: UUID) {
        if let s = subscriptions.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: convertedFile(for: s)) }
        subscriptions.removeAll { $0.id == id }
        setSubscriptions(subscriptions)
        recompile()
    }

    // MARK: Built-in rules

    static let adDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "adservice.google.com",
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "taboola.com", "outbrain.com", "criteo.com",
        "criteo.net", "pubmatic.com", "rubiconproject.com", "openx.net", "scorecardresearch.com", "moatads.com",
        "zedo.com", "popads.net", "popcash.net", "propellerads.com", "adsterra.com", "exoclick.com", "juicyads.com",
        "mgid.com", "revcontent.com", "yieldmo.com", "smartadserver.com", "admicro.vn", "adtima.vn", "eclick.vn",
        "ambientplatform.vn", "adsota.com", "admaster.cc", "hotjar.com", "quantserve.com", "2mdn.net", "adform.net",
        "teads.tv", "media.net", "bidswitch.net", "casalemedia.com", "33across.com", "sharethrough.com", "inmobi.com",
        "unityads.unity3d.com", "applovin.com", "adcolony.com", "vungle.com", "chartboost.com", "onclickads.net",
        "trafficjunky.net", "hilltopads.net", "a-ads.com", "coinhive.com",
    ]

    static var builtinNetworkRules: [[String: Any]] {
        adDomains.map { d in
            let escaped = d.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[/:]", "load-type": ["third-party"]],
                    "action": ["type": "block"]]
        }
    }

    /// Generic selectors for intrusive ads, injected as CSS when "Block Intrusive Ads" is on.
    static let intrusiveSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^=\"google_ads_\"]", "[id^=\"div-gpt-ad\"]", "iframe[src*=\"doubleclick.net\"]",
        "iframe[src*=\"googlesyndication\"]", "[class*=\"ad-banner\"]", "[class^=\"ads-\"]", "[id^=\"ads-\"]", ".ad-container",
        ".advertisement", "[data-ad-slot]", "[data-ad-unit]", "a[href*=\"/aclk?\"]", ".taboola", "[id^=\"taboola-\"]",
        ".OUTBRAIN", "[class*=\"sticky-ad\"]", "[class*=\"popup-ad\"]", "[id*=\"_ad_container\"]",
    ]

    // MARK: Page script

    /// Runs in every frame: intrusive/floating ad removal, pop-up and pop-under blocking,
    /// and skipping of in-stream video ads. Reports blocked pop-ups so the user can still open them.
    func pageScript() -> String {
        let cfg: [String: Any] = [
            "intrusive": Prefs.blockIntrusiveAds,
            "popups": Prefs.blockPopups,
            "videoAds": Prefs.skipVideoAds,
            "whitelist": whitelist,
            "adHosts": AdBlocker.adDomains,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__faABCfg=\(json);" + AdBlocker.pageJS
    }

    private static let pageJS = #"""
    (function(){
    if (window.__faAB) return; window.__faAB=1;
    var cfg=window.__faABCfg||{}; var host=location.hostname.toLowerCase();
    if ((cfg.whitelist||[]).some(function(h){ return host===h || host.endsWith('.'+h); })) return;
    var post=function(m){ try{ window.webkit.messageHandlers.fa.postMessage(m);}catch(e){} };
    var lastGesture=0, gestureEl=null;
    ['touchend','click','keydown'].forEach(function(t){ document.addEventListener(t,function(e){ lastGesture=Date.now(); gestureEl=e.target; },{capture:true,passive:true}); });
    function sameSite(u){ try{ var h=new URL(u,location.href).hostname.toLowerCase(); var a=h.split('.').slice(-2).join('.'), b=host.split('.').slice(-2).join('.'); return a===b; }catch(e){ return true; } }
    function isAdHost(u){ try{ var h=new URL(u,location.href).hostname.toLowerCase(); return (cfg.adHosts||[]).some(function(d){ return h===d||h.endsWith('.'+d); }); }catch(e){ return false; } }
    function interactive(el){ while(el && el!==document && el.tagName){ var t=el.tagName; if(t==='A'||t==='BUTTON'||t==='INPUT'||t==='SELECT'||t==='LABEL'||(el.getAttribute&&el.getAttribute('role')==='button')) return true; el=el.parentNode; } return false; }

    // Pop-up windows: block window.open without a tap, and pop-unders fired from taps on plain page areas.
    if (cfg.popups && window.top===window) {
      var origOpen=window.open;
      window.open=function(u){
        var url=u?String(u):'';
        var recent=Date.now()-lastGesture<1000;
        var popunder=recent && !interactive(gestureEl) && url && !sameSite(url);
        if(!recent || popunder || isAdHost(url)){ post({type:'popupBlocked', url:url?new URL(url,location.href).href:''}); return null; }
        return origOpen.apply(window, arguments);
      };
      // Invisible full-page links that open ads in a new tab.
      document.addEventListener('click', function(e){ var a=e.target&&e.target.closest?e.target.closest('a[target=_blank]'):null; if(!a||!a.href||sameSite(a.href)) return;
        var r=a.getBoundingClientRect(), cs=getComputedStyle(a);
        var cover=r.width>=innerWidth*0.9 && r.height>=innerHeight*0.6;
        var hidden=parseFloat(cs.opacity)<0.05 || (cs.backgroundColor==='rgba(0, 0, 0, 0)' && !(a.innerText||'').trim() && !a.querySelector('img,video,picture'));
        if((cover && hidden) || isAdHost(a.href)){ e.preventDefault(); e.stopImmediatePropagation(); post({type:'popupBlocked', url:a.href}); } }, true);
    }

    // Intrusive ads: fixed/sticky overlays and floating banners that carry ad content.
    if (cfg.intrusive) {
      var removed=false;
      function adLike(el){
        if(el.querySelector('iframe[src*="ads"],iframe[id*="google_ads"],ins.adsbygoogle,[id^="div-gpt-ad"],[data-ad-slot],[class*="adsbygoogle"]')) return true;
        var ifr=el.querySelectorAll('iframe'); for(var i=0;i<ifr.length;i++){ var s=ifr[i].src||''; if(s && (!sameSite(s) && !/youtube|vimeo|player|video|captcha|recaptcha|hcaptcha|turnstile/i.test(s))) return true; }
        var links=el.querySelectorAll('a[href]'); var ext=0, imgs=0;
        for(var j=0;j<links.length;j++){ if(!sameSite(links[j].href)||isAdHost(links[j].href)){ ext++; if(links[j].querySelector('img,video,picture,canvas')|| /background-image/.test(links[j].getAttribute('style')||'')) imgs++; } }
        var txt=(el.innerText||'').trim();
        if(imgs>0 && txt.length<300) return true;
        if(/(^|\s)(quảng cáo|advertisement|sponsored|广告|広告)(\s|$)/i.test(txt) && txt.length<200 && (ext>0||ifr.length)) return true;
        return false;
      }
      function sweep(){
        var vw=innerWidth, vh=innerHeight, all=document.body?document.body.getElementsByTagName('*'):[];
        for(var i=0;i<all.length;i++){ var el=all[i]; if(el.__faChecked) continue;
          var cs=getComputedStyle(el); if(cs.position!=='fixed' && cs.position!=='sticky') continue; el.__faChecked=1;
          if(el.tagName==='VIDEO'||el.querySelector('video')||el.querySelector('input[type=password],form')) continue;
          var r=el.getBoundingClientRect(); if(r.width<40||r.height<30) continue;
          var big=r.width*r.height>vw*vh*0.35, banner=(r.height<=180 && r.width>=vw*0.6) || (r.width<=360 && r.height<=360 && (r.right>=vw-4||r.left<=4));
          if((big||banner) && adLike(el)){ el.style.setProperty('display','none','important'); removed=true; post({type:'adBlocked', kind:'intrusive'}); }
        }
        if(removed){ [document.documentElement,document.body].forEach(function(n){ if(n && getComputedStyle(n).overflow==='hidden'){ n.style.setProperty('overflow','auto','important'); } }); }
      }
      var t=null; function later(){ clearTimeout(t); t=setTimeout(sweep,500); }
      if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', later); else later();
      window.addEventListener('load', later);
      new MutationObserver(later).observe(document.documentElement,{childList:true,subtree:true});
    }

    // In-stream video ads: press skip buttons and fast-forward ad segments.
    if (cfg.videoAds) {
      var SKIP='.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button,.videoAdUiSkipButton,[class*="skip-ad"],[class*="skipAd"],[class*="ad-skip"],[class*="btn-skip"],.jw-skip,.vjs-ad-skip,.fp-skip,[id*="skip-ad"],[id*="skipAd"]';
      var SKIPTEXT=/^(skip( ad| ads)?|bỏ qua( quảng cáo)?|跳过(广告)?|关闭广告|広告をスキップ|スキップ|광고 건너뛰기)\s*[›»▶>]*$/i;
      setInterval(function(){
        if(document.hidden) return;
        document.querySelectorAll(SKIP).forEach(function(b){ if(b.offsetParent!==null) try{ b.click(); }catch(e){} });
        var btns=document.querySelectorAll('button,div[role=button],span[role=button],a.skip,div[class*="skip"]');
        for(var i=0;i<btns.length && i<400;i++){ var b=btns[i], tx=(b.innerText||'').trim(); if(tx.length<24 && SKIPTEXT.test(tx) && b.offsetParent!==null){ try{ b.click(); }catch(e){} } }
        var adShowing=document.querySelector('.ad-showing video,.ad-interrupting video,.jw-flag-ads video,.vjs-ad-playing video,[class*="ima-ad"] video');
        if(adShowing && isFinite(adShowing.duration) && adShowing.duration>0 && adShowing.duration<180){ try{ adShowing.muted=true; adShowing.currentTime=adShowing.duration-0.1; }catch(e){} }
      }, 600);
    }
    })();
    """#

    static let noImageJSON = """
    [{"trigger":{"url-filter":".*","resource-type":["image"]},"action":{"type":"block"}},
     {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"img,picture,svg image"}}]
    """
}

/// Converts a subset of Adblock Plus filter syntax to WebKit content blocker JSON.
enum ABPConverter {
    private static let unsupportedSelectorTokens = [":-abp", ":has(", ":contains", ":xpath", ":style", "[-ext-", ":matches-", ":upward", ":remove", ":watch-attr", ":min-text", ":nth-ancestor", "+js(", ":not(:"]

    static func convert(_ text: String) -> [[String: Any]] {
        var network: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var generic: [String] = []
        var specific: [[String: Any]] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if line.hasPrefix("#") && !line.hasPrefix("##") { continue }
            guard line.canBeConverted(to: .ascii) else { continue }
            // Hosts-file entries: "0.0.0.0 ads.example.com"
            if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
                let host = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if host.contains("."), host != "localhost" {
                    network.append(["trigger": ["url-filter": regex(from: "||\(host)^")], "action": ["type": "block"]])
                }
                continue
            }

            if let r = line.range(of: "##") {
                let domains = String(line[..<r.lowerBound])
                let selector = String(line[r.upperBound...])
                guard !selector.isEmpty, !unsupportedSelectorTokens.contains(where: { selector.contains($0) }) else { continue }
                if domains.isEmpty {
                    generic.append(selector)
                } else {
                    let ds = domains.split(separator: ",").map(String.init).filter { !$0.hasPrefix("~") }
                    guard !ds.isEmpty else { continue }
                    specific.append(["trigger": ["url-filter": ".*", "if-domain": ds.map { "*" + $0 }],
                                     "action": ["type": "css-display-none", "selector": selector]])
                }
                continue
            }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#") { continue }

            var rule = line
            var isException = false
            if rule.hasPrefix("@@") { isException = true; rule.removeFirst(2) }
            var options: [String] = []
            if let dollar = rule.lastIndex(of: "$"), !rule.hasPrefix("/") {
                options = rule[rule.index(after: dollar)...].split(separator: ",").map(String.init)
                rule = String(rule[..<dollar])
            }
            if rule.hasPrefix("/") && rule.hasSuffix("/") { continue }
            guard rule.count >= 4 else { continue }

            var trigger: [String: Any] = ["url-filter": regex(from: rule)]
            var resourceTypes: [String] = []
            var skip = false
            for o in options {
                switch o {
                case "third-party": trigger["load-type"] = ["third-party"]
                case "~third-party", "first-party": trigger["load-type"] = ["first-party"]
                case "script": resourceTypes.append("script")
                case "image": resourceTypes.append("image")
                case "stylesheet": resourceTypes.append("style-sheet")
                case "font": resourceTypes.append("font")
                case "media": resourceTypes.append("media")
                case "popup": resourceTypes.append("popup")
                case "xmlhttprequest": resourceTypes.append("raw")
                case "subdocument": resourceTypes.append("document")
                case "document": if isException { resourceTypes.append("document") } else { skip = true }
                case "match-case", "important": break
                default:
                    if o.hasPrefix("domain=") {
                        let ds = o.dropFirst(7).split(separator: "|").map(String.init)
                        let inc = ds.filter { !$0.hasPrefix("~") }.map { "*" + $0 }
                        let exc = ds.filter { $0.hasPrefix("~") }.map { "*" + $0.dropFirst() }
                        if !inc.isEmpty { trigger["if-domain"] = inc } else if !exc.isEmpty { trigger["unless-domain"] = exc }
                    } else if o.hasPrefix("~") {
                        break
                    } else {
                        skip = true
                    }
                }
            }
            if skip { continue }
            if !resourceTypes.isEmpty { trigger["resource-type"] = resourceTypes }
            let entry: [String: Any] = ["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]]
            if isException { exceptions.append(entry) } else { network.append(entry) }
        }

        var out = network
        stride(from: 0, to: generic.count, by: 400).forEach { i in
            let chunk = generic[i..<min(i + 400, generic.count)]
            out.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": chunk.joined(separator: ",")]])
        }
        out += specific
        out += exceptions
        return out
    }

    static func regex(from rule: String) -> String {
        var r = rule
        var prefix = ""
        var suffix = ""
        if r.hasPrefix("||") { r.removeFirst(2); prefix = "^[^:]+:(//)?([^/]+\\.)?" }
        else if r.hasPrefix("|") { r.removeFirst(); prefix = "^" }
        if r.hasSuffix("|") { r.removeLast(); suffix = "$" }
        var out = ""
        for c in r {
            switch c {
            case "*": out += ".*"
            case "^": out += "[/:?&=]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "|", "$": out += "\\\(c)"
            default: out.append(c)
            }
        }
        if out.hasPrefix(".*") { out.removeFirst(2) }
        return prefix + out + suffix
    }
}
