import WebKit

/// Weak proxy so WKUserContentController doesn't retain the browser.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

struct PageConfig {
    var night: Bool
    var eyeCare: Bool
    var touchPage: Bool
    var rate: Double

    static func current(darkUI: Bool) -> PageConfig {
        PageConfig(night: Prefs.nightMode || (Prefs.applyDarkToWebpage && darkUI),
                   eyeCare: Prefs.eyeCare,
                   touchPage: Prefs.touchToTurnPage,
                   rate: Prefs.playbackRate)
    }

    var json: String {
        "{\"night\":\(night),\"eyeCare\":\(eyeCare),\"touchPage\":\(touchPage),\"rate\":\(rate)}"
    }
}

enum ScriptManager {
    static let handlerName = "fa"

    /// Rebuilds all user scripts for a controller. Call when preferences, extensions or hide rules change.
    static func install(into controller: WKUserContentController, config: PageConfig) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: "window.__faConfig=\(config.json);" + helperJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: hideRulesJS(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: VideoSniffer.script(compat: Prefs.videoCompatMode), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: PageTranslator.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if Prefs.adBlock {
            controller.addUserScript(WKUserScript(source: AdBlocker.shared.pageScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        for ext in JSExtensionStore.shared.passive {
            let source = wrap(ext)
            let time: WKUserScriptInjectionTime = ext.runAt == .veryBeginning ? .atDocumentStart : .atDocumentEnd
            controller.addUserScript(WKUserScript(source: source, injectionTime: time, forMainFrameOnly: true))
        }
        AdBlocker.shared.apply(to: controller)
    }

    static func wrap(_ ext: JSExtension) -> String {
        let patterns = (try? JSONSerialization.data(withJSONObject: ext.matchList)).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"*\"]"
        return """
        (function(){ if(!window.__fa || !window.__fa.match(\(patterns))) return;
        try { \(ext.code)
        } catch(e) { console.error('[FAbrowser extension \(ext.name.replacingOccurrences(of: "'", with: ""))]', e); } })();
        """
    }

    private static func hideRulesJS() -> String {
        var map = AdBlocker.shared.userRules
        if Prefs.adBlock && Prefs.blockIntrusiveAds {
            map["*"] = AdBlocker.intrusiveSelectors
        }
        let json = (try? JSONSerialization.data(withJSONObject: map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function(){ var rules=\(json); var host=location.hostname.toLowerCase(); var sel=[];
        for (var h in rules) { if (h==='*' || host===h || host.endsWith('.'+h)) sel=sel.concat(rules[h]); }
        if(!sel.length) return; var css=sel.map(function(s){return s+'{display:none!important}'}).join('\\n');
        var st=document.createElement('style'); st.id='__fa_hide'; st.textContent=css;
        (document.head||document.documentElement).appendChild(st); })();
        """
    }

    static let nightCSS = """
    html,body{background-color:#1c1c1e!important}
    *:not(img):not(video):not(canvas):not(svg):not(path):not(picture){background-color:transparent!important;color:#b4b4b9!important;border-color:#3a3a3c!important;box-shadow:none!important}
    html,body,header,nav,main,section,article,aside,footer,div,form,table,ul,li,td,th{background-color:#1c1c1e!important}
    a,a *{color:#6aa1e8!important}
    input,textarea,select,button{background-color:#2c2c2e!important;color:#d1d1d6!important}
    img,video,picture,canvas{opacity:.82}
    ::selection{background:#4a4a8a!important}
    """

    static let helperJS = #"""
    (function(){
    if (window.__fa) return;
    var post=function(m){ try{ window.webkit.messageHandlers.fa.postMessage(m);}catch(e){} };
    var cfg=window.__faConfig||{};
    var fa=window.__fa={};
    var lastTouch=null;

    function style(id,css){ var s=document.getElementById(id); if(!css){ if(s) s.remove(); return; }
      if(!s){ s=document.createElement('style'); s.id=id; (document.head||document.documentElement).appendChild(s);} s.textContent=css; }

    fa.match=function(list){ var href=location.href, host=location.hostname.toLowerCase();
      for (var i=0;i<list.length;i++){ var m=list[i];
        if(m==='*') return true;
        if(m.length>2 && m[0]==='/' && m[m.length-1]==='/'){ try{ if(new RegExp(m.slice(1,-1)).test(href)) return true;}catch(e){} }
        else { var l=m.toLowerCase(); if(host===l || host.endsWith('.'+l) || href.indexOf(m)>=0) return true; } }
      return false; };

    fa.apply=function(c){ cfg=c||cfg;
      style('__fa_night', cfg.night ? __NIGHT__ : null);
      style('__fa_eye', cfg.eyeCare ? 'html,body{background-color:#C7EDCC!important}' : null);
      fa.setRate(cfg.rate); };

    fa.setRate=function(r){ if(!r||r===1){ return; } document.querySelectorAll('video,audio').forEach(function(v){ v.playbackRate=r; v.defaultPlaybackRate=r; }); };
    document.addEventListener('play', function(e){ if(cfg.rate && cfg.rate!==1 && e.target){ e.target.playbackRate=cfg.rate; } }, true);

    style('__fa_callout','a,img{-webkit-touch-callout:none!important}');

    // Long press support: native gesture asks for the last touched element.
    document.addEventListener('touchstart', function(e){ var t=e.touches[0]; lastTouch={el:e.target,x:t.clientX,y:t.clientY}; }, {capture:true,passive:true});
    fa.touchInfo=function(){ if(!lastTouch) return null; var el=lastTouch.el, link=null, img=null, title=null;
      while(el && el!==document){ if(!link && el.tagName==='A' && el.href){ link=el.href; title=(el.innerText||'').trim().slice(0,200); }
        if(!img && el.tagName==='IMG'){ img=el.currentSrc||el.src; }
        if(!img && el.tagName==='VIDEO' && el.poster){ img=el.poster; }
        el=el.parentNode; }
      if(!img && lastTouch.el && lastTouch.el.querySelector){ var i=lastTouch.el.querySelector('img'); if(i && lastTouch.el.offsetWidth<600) img=i.currentSrc||i.src; }
      if(!link && !img) return null; return {link:link, image:img, title:title}; };

    // Touch screen to turn page.
    document.addEventListener('click', function(e){ if(!cfg.touchPage) return; var el=e.target;
      while(el && el!==document){ var tn=el.tagName; if(tn==='A'||tn==='BUTTON'||tn==='INPUT'||tn==='TEXTAREA'||tn==='SELECT'||tn==='VIDEO'||tn==='LABEL'||el.onclick||el.getAttribute&&el.getAttribute('role')==='button') return; el=el.parentNode; }
      var h=window.innerHeight; if(e.clientY<h/3) window.scrollBy({top:-h*0.85,behavior:'smooth'}); else if(e.clientY>h*2/3) window.scrollBy({top:h*0.85,behavior:'smooth'}); }, true);

    fa.page=function(dir){ var h=window.innerHeight; window.scrollBy({top:dir*h*0.85,behavior:'smooth'}); };

    // Next page detection.
    fa.findNext=function(){ var rel=document.querySelector('link[rel=next],a[rel=next]'); if(rel&&rel.href) return rel.href;
      var words=['next','next page','下一页','下一章','下页','trang sau','trang tiếp','tiếp','chương sau','sau ›','›','»','next ›','next »','older posts','siguiente','suivant','weiter','次へ','다음'];
      var as=document.querySelectorAll('a[href]');
      for(var i=as.length-1;i>=0;i--){ var a=as[i]; var t=(a.innerText||a.getAttribute('aria-label')||'').trim().toLowerCase(); if(!t||t.length>20) continue;
        if(words.indexOf(t)>=0 && a.href.indexOf('javascript:')!==0 && a.href!==location.href) return a.href; }
      return null; };

    fa.icon=function(){ var l=document.querySelector('link[rel="apple-touch-icon"],link[rel="apple-touch-icon-precomposed"],link[rel="icon"][sizes="192x192"],link[rel="icon"][sizes="180x180"]'); return l?l.href:null; };

    function onReady(){ fa.apply(cfg); post({type:'ready', next:fa.findNext(), icon:fa.icon()}); }
    if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', onReady); else onReady();
    window.addEventListener('load', function(){ post({type:'loaded', next:fa.findNext(), icon:fa.icon()}); });

    // Media helpers.
    fa.images=function(){ var seen={}, out=[]; document.querySelectorAll('img').forEach(function(i){ var s=i.currentSrc||i.src; if(!s||seen[s]||s.indexOf('data:')===0&&s.length<200) return; if(i.naturalWidth&&i.naturalWidth<48) return; seen[s]=1; out.push(s); }); return out; };
    fa.videos=function(){ var out=[]; document.querySelectorAll('video').forEach(function(v){ var s=v.currentSrc||v.src; if(!s){ var so=v.querySelector('source'); if(so) s=so.src; } if(s && s.indexOf('blob:')!==0) out.push({src:s, poster:v.poster||'', time:v.currentTime||0}); }); return out; };
    fa.pauseVideos=function(){ document.querySelectorAll('video').forEach(function(v){ v.pause(); }); };
    fa.text=function(){ return document.body ? document.body.innerText : ''; };

    // Find in page.
    var marks=[], cur=-1;
    fa.findClear=function(){ marks.forEach(function(m){ var p=m.parentNode; if(!p) return; p.replaceChild(document.createTextNode(m.textContent), m); p.normalize(); }); marks=[]; cur=-1; };
    fa.find=function(q){ fa.findClear(); if(!q) return {i:0,n:0}; var lq=q.toLowerCase();
      var walker=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {acceptNode:function(n){ var p=n.parentNode; if(!p||/^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA)$/.test(p.tagName)) return NodeFilter.FILTER_REJECT; return n.nodeValue.toLowerCase().indexOf(lq)>=0?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_SKIP; }});
      var nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode);
      nodes.forEach(function(n){ var text=n.nodeValue, lt=text.toLowerCase(), idx=0, pos, frag=document.createDocumentFragment();
        while((pos=lt.indexOf(lq,idx))>=0){ frag.appendChild(document.createTextNode(text.slice(idx,pos))); var m=document.createElement('mark'); m.className='__fa_mark'; m.style.cssText='background:#FFE14D;color:#000;border-radius:2px'; m.textContent=text.substr(pos,q.length); frag.appendChild(m); marks.push(m); idx=pos+q.length; }
        frag.appendChild(document.createTextNode(text.slice(idx))); n.parentNode.replaceChild(frag,n); });
      if(marks.length){ cur=0; fa.findFocus(); } return {i:marks.length?1:0, n:marks.length}; };
    fa.findFocus=function(){ marks.forEach(function(m,i){ m.style.background = i===cur ? '#FF9632' : '#FFE14D'; }); if(marks[cur]) marks[cur].scrollIntoView({block:'center'}); return {i:cur+1,n:marks.length}; };
    fa.findStep=function(d){ if(!marks.length) return {i:0,n:0}; cur=(cur+d+marks.length)%marks.length; return fa.findFocus(); };

    // Element picker for "Hide Element".
    var pick=null;
    function outline(el){ document.querySelectorAll('.__fa_pick').forEach(function(e){ e.classList.remove('__fa_pick'); }); if(el) el.classList.add('__fa_pick'); }
    function selectorFor(el){ if(el.id && !/\d{4,}/.test(el.id)) return '#'+CSS.escape(el.id); var parts=[];
      while(el && el.nodeType===1 && el!==document.body && parts.length<5){ var s=el.tagName.toLowerCase();
        if(el.id && !/\d{4,}/.test(el.id)){ parts.unshift('#'+CSS.escape(el.id)); break; }
        var cls=Array.prototype.filter.call(el.classList,function(c){ return c.indexOf('__fa')!==0 && !/\d{3,}/.test(c); }).slice(0,2);
        if(cls.length) s+='.'+cls.map(function(c){return CSS.escape(c)}).join('.');
        var p=el.parentNode; if(p){ var same=Array.prototype.filter.call(p.children,function(c){ return c.tagName===el.tagName; }); if(same.length>1) s+=':nth-of-type('+(same.indexOf(el)+1)+')'; }
        parts.unshift(s); el=el.parentNode; }
      return parts.join(' > '); }
    function pickClick(e){ e.preventDefault(); e.stopPropagation(); pick=e.target; outline(pick); post({type:'picked', selector:selectorFor(pick)}); }
    fa.pickStart=function(){ style('__fa_pickcss','.__fa_pick{outline:3px solid #E5484D!important;outline-offset:-2px;background-color:rgba(229,72,77,.18)!important}'); document.addEventListener('click',pickClick,true); };
    fa.pickParent=function(){ if(pick && pick.parentNode && pick.parentNode!==document.body){ pick=pick.parentNode; outline(pick); } return pick?selectorFor(pick):null; };
    fa.pickHide=function(){ if(!pick) return null; var s=selectorFor(pick); pick.style.setProperty('display','none','important'); outline(null); pick=null; return s; };
    fa.pickStop=function(){ document.removeEventListener('click',pickClick,true); outline(null); pick=null; style('__fa_pickcss',null); };

    // Reader mode extraction.
    fa.reader=function(){
      var scores=new Map();
      function add(el,v){ if(!el||el===document.documentElement) return; scores.set(el,(scores.get(el)||0)+v); }
      var paras=document.querySelectorAll('p, pre, blockquote'); if(paras.length<3) paras=document.querySelectorAll('p, pre, blockquote, li, td');
      paras.forEach(function(p){
        var t=(p.textContent||'').trim(); if(t.length<25) return;
        var v=1+t.split(/[,，、。]/).length+Math.min(Math.floor(t.length/100),3);
        add(p.parentElement,v); if(p.parentElement) add(p.parentElement.parentElement,v/2);
      });
      var best=null, bestScore=0;
      scores.forEach(function(v,el){
        var text=(el.textContent||'').length||1, links=0;
        el.querySelectorAll('a').forEach(function(a){ links+=(a.textContent||'').length; });
        var cls=(el.className||'')+' '+(el.id||'');
        if(/comment|footer|sidebar|related|share|nav|menu|banner|promo/i.test(cls)) v*=0.3;
        if(/article|content|post|entry|main|body|text|chapter|parser-output/i.test(cls)) v*=1.25;
        var s=v*(1-Math.min(links/text,0.9));
        if(s>bestScore){ bestScore=s; best=el; }
      });
      while(best && best.parentElement && best.parentElement!==document.body){
        var par=best.parentElement, strong=0;
        for(var i=0;i<par.children.length;i++){ var c=par.children[i]; var cs=scores.get(c)||0; if(c!==best && cs>=bestScore*0.2) strong++; }
        var wrapper=(best.textContent||'').length >= 0.85*((par.textContent||'').length||1);
        if(strong>=1 || wrapper || (scores.get(par)||0)>bestScore*0.8) best=par; else break;
      }
      if(!best||bestScore<8) return null;
      var clone=best.cloneNode(true);
      clone.querySelectorAll('script,style,iframe,form,nav,aside,header,footer,[role=navigation],[role=banner],button,input,select,noscript,svg,.navbox,.mw-editsection,.reference,.infobox,[class*=share],[class*=comment],[class*=related],[id*=comment],[aria-hidden=true]').forEach(function(e){ e.remove(); });
      clone.querySelectorAll('[style]').forEach(function(e){ e.removeAttribute('style'); });
      clone.querySelectorAll('[hidden]').forEach(function(e){ e.removeAttribute('hidden'); });
      clone.querySelectorAll('img').forEach(function(i){ var s=i.getAttribute('data-src')||i.getAttribute('data-original')||i.currentSrc||i.src; if(s) i.setAttribute('src',s); i.removeAttribute('srcset'); i.removeAttribute('width'); i.removeAttribute('height'); i.removeAttribute('loading'); });
      clone.querySelectorAll('a[href]').forEach(function(a){ a.setAttribute('href',a.href); });
      var h=document.querySelector('h1'), title=(h&&h.innerText.trim())||document.title;
      clone.querySelectorAll('h1').forEach(function(e){ if((e.textContent||'').trim()===title) e.remove(); });
      return {title:title, html:clone.innerHTML, next:fa.findNext(), url:location.href}; };
    })();
    """#.replacingOccurrences(of: "__NIGHT__", with: nightCSS.jsEscaped)
}
