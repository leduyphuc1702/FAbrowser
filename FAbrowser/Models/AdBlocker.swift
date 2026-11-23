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

    private(set) var adLists: [WKContentRuleList] = []
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
        // Lists recommended by github.com/yokoffing/filterlists
        FilterSubscription(title: "HaGeZi Pro mini", url: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.mini.txt", enabled: true),
        FilterSubscription(title: "Actually Legitimate URL Shortener Tool", url: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/LegitimateURLShortener.txt", enabled: true),
        FilterSubscription(title: "yokoffing's Annoyance List", url: "https://raw.githubusercontent.com/yokoffing/filterlists/main/annoyance_list.txt", enabled: true),
        FilterSubscription(title: "yokoffing's Privacy Essentials", url: "https://raw.githubusercontent.com/yokoffing/filterlists/main/privacy_essentials.txt", enabled: false),
        FilterSubscription(title: "yokoffing's click2load", url: "https://raw.githubusercontent.com/yokoffing/filterlists/main/click2load.txt", enabled: false),
        FilterSubscription(title: "ClearURLs for uBO", url: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/ClearURLs%20for%20uBo/clear_urls_uboified.txt", enabled: false),
        FilterSubscription(title: "Block third-party fonts", url: "https://raw.githubusercontent.com/yokoffing/filterlists/main/block_third_party_fonts.txt", enabled: false),
        FilterSubscription(title: "Fanboy's Agegate List", url: "https://secure.fanboy.co.nz/fanboy-agegate.txt", enabled: false),
        FilterSubscription(title: "Browse websites without logging in", url: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/BrowseWebsitesWithoutLoggingIn.txt", enabled: false),
        FilterSubscription(title: "YouTube Clear View", url: "https://raw.githubusercontent.com/yokoffing/filterlists/main/youtube_clear_view.txt", enabled: false),
        FilterSubscription(title: "Anti-paywall filters", url: "https://raw.githubusercontent.com/liamengland1/miscfilters/master/antipaywall.txt", enabled: false),
        FilterSubscription(title: "Dandelion Sprout's Anti-Malware List", url: "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Dandelion%20Sprout's%20Anti-Malware%20List.txt", enabled: false),
        FilterSubscription(title: "The malicious website blocklist", url: "https://raw.githubusercontent.com/iam-py-test/my_filters_001/main/antimalware.txt", enabled: false),
        FilterSubscription(title: "uBlock combo list", url: "https://raw.githubusercontent.com/iam-py-test/uBlock-combo/main/list.txt", enabled: false),
        FilterSubscription(title: "HaGeZi combo alt-suggested mini", url: "https://raw.githubusercontent.com/cbuijs/hagezi/refs/heads/main/combo/alt-suggested-mini/domains.top-n.adblock", enabled: false),
    ]

    private static let presetVersion = 3

    private init() {
        var subs = JSONStore.load([FilterSubscription].self, from: subsFile) ?? AdBlocker.presetSubscriptions
        let oldPreset = UserDefaults.standard.integer(forKey: "filterPresetVersion")
        if oldPreset < AdBlocker.presetVersion {
            let presetURLs = Set(AdBlocker.presetSubscriptions.map(\.url))
            let custom = subs.filter { !presetURLs.contains($0.url) && !$0.url.contains("abpvn.com/android") && $0.url != "https://abpvn.com/android/abpvn.txt" }
            subs = AdBlocker.presetSubscriptions.map { p in
                subs.first { $0.url == p.url }.map { var e = $0; if oldPreset < 2 { e.enabled = p.enabled }; e.title = p.title; return e } ?? p
            } + custom
            UserDefaults.standard.set(AdBlocker.presetVersion, forKey: "filterPresetVersion")
            JSONStore.save(subs, to: subsFile)
        }
        subscriptions = subs
        userRules = JSONStore.load([String: [String]].self, from: userRulesFile) ?? [:]
        whitelist = JSONStore.load([String].self, from: whitelistFile) ?? []
        loadParamRules()
    }

    // MARK: Compile

    /// Bump when ABPConverter output or built-in rules change so cached lists are rebuilt.
    private static let converterVersion = 4
    private static let fingerprintKey = "adBlockListFingerprint"
    private static let listIDsKey = "adBlockListIDs"
    /// WebKit rejects lists above 150k rules; stay well below it and split into several lists.
    private static let rulesPerList = 90_000

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
        let ids = UserDefaults.standard.stringArray(forKey: AdBlocker.listIDsKey) ?? []
        if UserDefaults.standard.string(forKey: AdBlocker.fingerprintKey) == fingerprint, !ids.isEmpty {
            lookUp(ids) { [weak self] lists in
                guard let self else { group.leave(); return }
                if let lists { self.adLists = lists; group.leave() } else { self.compileAdList { group.leave() } }
            }
        } else {
            compileAdList { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    private func lookUp(_ ids: [String], completion: @escaping ([WKContentRuleList]?) -> Void) {
        var found: [String: WKContentRuleList] = [:]
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                DispatchQueue.main.async { if let list { found[id] = list }; group.leave() }
            }
        }
        group.notify(queue: .main) {
            completion(found.count == ids.count ? ids.compactMap { found[$0] } : nil)
        }
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
            var blocks: [[String: Any]] = AdBlocker.builtinNetworkRules
            var exceptions: [[String: Any]] = []
            var cosmetic: [[String: Any]] = []
            var seen = Set<String>()
            for s in subs {
                guard let data = try? Data(contentsOf: self.convertedFile(for: s)),
                      let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                for r in rules {
                    switch (r["action"] as? [String: Any])?["type"] as? String {
                    case "css-display-none": cosmetic.append(r)
                    case "ignore-previous-rules": exceptions.append(r)
                    default:
                        // Domain lists overlap heavily (EasyList, HaGeZi, malware lists); keep one copy.
                        if let t = r["trigger"] as? [String: Any], let key = AdBlocker.triggerKey(t), !seen.insert(key).inserted { continue }
                        blocks.append(r)
                    }
                }
            }
            exceptions = Array(exceptions.prefix(20_000))
            cosmetic = Array(cosmetic.prefix(40_000))
            var tail: [[String: Any]] = []
            if !whitelist.isEmpty {
                tail.append(["trigger": ["url-filter": ".*", "if-domain": whitelist.map { "*" + $0 }], "action": ["type": "ignore-previous-rules"]])
            }
            // Exceptions only cancel rules of their own list, so every network chunk carries them.
            let size = AdBlocker.rulesPerList - exceptions.count
            var chunks: [[[String: Any]]] = stride(from: 0, to: blocks.count, by: size).map { i in
                Array(blocks[i..<min(i + size, blocks.count)]) + exceptions + tail
            }
            if !cosmetic.isEmpty { chunks.append(cosmetic + tail) }
            self.compileChunks(chunks, index: 0, lists: [], ids: [], allOK: true) { lists, ids, allOK in
                // A chunk that fails once fails every time, so the partial result is cached too.
                if !ids.isEmpty {
                    if !allOK { print("AdBlock: some rule lists failed to compile") }
                    UserDefaults.standard.set(fp, forKey: AdBlocker.fingerprintKey)
                    UserDefaults.standard.set(ids, forKey: AdBlocker.listIDsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: AdBlocker.fingerprintKey)
                }
                self.removeStaleLists(keeping: Set(ids))
                self.finishCompile(lists, completion)
            }
        }
    }

    private func compileChunks(_ chunks: [[[String: Any]]], index: Int, lists: [WKContentRuleList], ids: [String], allOK: Bool,
                               completion: @escaping ([WKContentRuleList], [String], Bool) -> Void) {
        guard index < chunks.count else { completion(lists, ids, allOK); return }
        let id = "fa.adblock.\(index)"
        compile(rules: chunks[index], identifier: id) { [weak self] list in
            DispatchQueue.global(qos: .userInitiated).async {
                if let list {
                    self?.compileChunks(chunks, index: index + 1, lists: lists + [list], ids: ids + [id], allOK: allOK, completion: completion)
                } else {
                    self?.compileChunks(chunks, index: index + 1, lists: lists, ids: ids, allOK: false, completion: completion)
                }
            }
        }
    }

    private func removeStaleLists(keeping ids: Set<String>) {
        DispatchQueue.main.async {
            self.store.getAvailableContentRuleListIdentifiers { all in
                for id in all ?? [] where id.hasPrefix("fa.adblock") && !ids.contains(id) {
                    self.store.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    private static func triggerKey(_ t: [String: Any]) -> String? {
        guard let f = t["url-filter"] as? String else { return nil }
        func j(_ k: String) -> String { (t[k] as? [String])?.joined(separator: ",") ?? "" }
        return [f, j("load-type"), j("resource-type"), j("if-domain"), j("unless-domain")].joined(separator: "|")
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
            saveParamRules(ABPConverter.removeParams(text), for: s)
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

    private func finishCompile(_ lists: [WKContentRuleList], _ completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            if !lists.isEmpty { self.adLists = lists }
            self.loadParamRules()
            self.compiling = false
            completion()
            if self.pendingRecompile {
                self.pendingRecompile = false
                self.recompile()
            }
        }
    }

    private func compile(rules: [[String: Any]], identifier: String, completion: @escaping (WKContentRuleList?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else {
            completion(nil); return
        }
        DispatchQueue.main.async {
            self.store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { print("AdBlock compile error (\(identifier), \(rules.count) rules):", error) }
                completion(list)
            }
        }
    }

    /// Re-applies the rule lists according to current preferences and the page host.
    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if Prefs.adBlock { adLists.forEach { controller.add($0) } }
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
            self.saveParamRules(ABPConverter.removeParams(text), for: self.subscriptions[idx])
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
        if let s = subscriptions.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: convertedFile(for: s))
            try? FileManager.default.removeItem(at: paramsFile(for: s))
        }
        subscriptions.removeAll { $0.id == id }
        setSubscriptions(subscriptions)
        recompile()
    }

    // MARK: URL tracking parameters ($removeparam)

    /// Parameter names stripped everywhere, and per site (host -> names).
    private var globalParams = Set<String>()
    private var hostParams: [String: Set<String>] = [:]
    private let paramLock = NSLock()

    private func paramsFile(for s: FilterSubscription) -> URL {
        FileManager.default.appSupportURL.appendingPathComponent("params_\(s.id.uuidString).json")
    }

    private func saveParamRules(_ p: [String: [String]], for s: FilterSubscription) {
        if p.isEmpty { try? FileManager.default.removeItem(at: paramsFile(for: s)); return }
        if let data = try? JSONSerialization.data(withJSONObject: p) { try? data.write(to: paramsFile(for: s), options: .atomic) }
    }

    private func loadParamRules() {
        var global = Set<String>(), byHost: [String: Set<String>] = [:]
        for s in subscriptions where s.enabled {
            guard let data = try? Data(contentsOf: paramsFile(for: s)),
                  let p = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { continue }
            for (host, names) in p {
                if host.isEmpty { global.formUnion(names) } else { byHost[host, default: []].formUnion(names) }
            }
        }
        paramLock.lock(); globalParams = global; hostParams = byHost; paramLock.unlock()
    }

    /// Returns `url` without known tracking parameters, or nil when nothing was removed.
    func cleanedURL(_ url: URL) -> URL? {
        guard Prefs.adBlock, url.query != nil, !isWhitelisted(url.host),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems, !items.isEmpty else { return nil }
        paramLock.lock()
        var names = globalParams
        if let host = url.host?.lowercased() {
            var parts = host.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                if let extra = hostParams[parts.joined(separator: ".")] { names.formUnion(extra) }
                parts.removeFirst()
            }
        }
        paramLock.unlock()
        let kept = items.filter { !names.contains($0.name) && !AdBlocker.isBuiltinTrackingParam($0.name) }
        guard kept.count < items.count else { return nil }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    private static let builtinParams: Set<String> = ["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "igshid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok"]

    private static func isBuiltinTrackingParam(_ name: String) -> Bool {
        name.hasPrefix("utm_") || builtinParams.contains(name)
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
    private static let unsupportedSelectorTokens = [":-abp", ":has(", ":has-text", ":contains", ":xpath", ":style", "[-ext-", ":matches-", ":upward", ":remove", ":watch-attr", ":min-text", ":nth-ancestor", "+js(", ":not(:", ":others", ":if(", ":if-not"]

    /// WebKit only accepts plain lowercase host names in if-domain/unless-domain; entries like
    /// `google.*` would make the whole list fail to compile.
    private static func validDomain(_ d: String) -> Bool {
        !d.isEmpty && d.contains(".") && !d.hasSuffix(".") && d.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    /// `$removeparam=` rules as host -> parameter names ("" = every site). Regex and negated forms are skipped.
    static func removeParams(_ text: String) -> [String: [String]] {
        var out: [String: Set<String>] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmed
            guard line.contains("removeparam="), !line.hasPrefix("!"), !line.hasPrefix("@@"), let dollar = line.lastIndex(of: "$") else { continue }
            let pattern = String(line[..<dollar])
            var name = "", hosts: [String] = []
            for o in line[line.index(after: dollar)...].split(separator: ",").map(String.init) {
                if o.hasPrefix("removeparam=") { name = String(o.dropFirst(12)) }
                else if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                    hosts += o.split(separator: "=", maxSplits: 1).last.map { $0.split(separator: "|").map { String($0).lowercased() } } ?? []
                }
            }
            guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("|") else { continue }
            if pattern.hasPrefix("||") {
                let h = pattern.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "^/")).lowercased()
                guard validDomain(h) else { continue }
                hosts.append(h)
            } else if !pattern.isEmpty && pattern != "*" {
                continue
            }
            hosts = hosts.filter { !$0.hasPrefix("~") && validDomain($0) }
            if hosts.isEmpty { out["", default: []].insert(name) } else { hosts.forEach { out[$0, default: []].insert(name) } }
        }
        return out.mapValues { Array($0) }
    }

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
                guard !selector.isEmpty, !selector.hasPrefix("^"), !unsupportedSelectorTokens.contains(where: { selector.contains($0) }) else { continue }
                if domains.isEmpty {
                    generic.append(selector)
                } else {
                    let all = domains.lowercased().split(separator: ",").map(String.init)
                    let ds = all.filter { !$0.hasPrefix("~") && validDomain($0) }
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
                case "third-party", "3p": trigger["load-type"] = ["third-party"]
                case "~third-party", "first-party", "1p", "~3p": trigger["load-type"] = ["first-party"]
                case "script": resourceTypes.append("script")
                case "image": resourceTypes.append("image")
                case "stylesheet", "css": resourceTypes.append("style-sheet")
                case "font": resourceTypes.append("font")
                case "media": resourceTypes.append("media")
                case "popup": resourceTypes.append("popup")
                case "xmlhttprequest", "xhr": resourceTypes.append("raw")
                case "subdocument", "frame": resourceTypes.append("document")
                case "ping", "beacon": resourceTypes.append("ping")
                case "websocket": resourceTypes.append("websocket")
                case "other": resourceTypes.append("other")
                case "document", "doc": if isException { resourceTypes.append("document") } else { skip = true }
                case "match-case", "important", "all": break
                default:
                    if o.hasPrefix("redirect=") {
                        break
                    } else if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                        let ds = o.split(separator: "=", maxSplits: 1).last.map { $0.lowercased().split(separator: "|").map(String.init) } ?? []
                        let inc = ds.filter { !$0.hasPrefix("~") && validDomain($0) }.map { "*" + $0 }
                        let exc = ds.filter { $0.hasPrefix("~") && validDomain(String($0.dropFirst())) }.map { "*" + $0.dropFirst() }
                        if !inc.isEmpty { trigger["if-domain"] = inc } else if !exc.isEmpty { trigger["unless-domain"] = exc }
                        else { skip = true }
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
