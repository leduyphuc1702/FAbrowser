import WebKit

/// A media element or stream URL reported by the page.
struct DetectedVideo {
    var src: URL?
    var isBlob: Bool
    var title: String
    var page: URL?
    var time: Double
    var duration: Double
    var playing: Bool
    var frame: WKFrameInfo?
    var reportedAt = Date()
    var reason: String
    var muted: Bool
    var loop: Bool
    var viewWidth: Double
    /// The play event followed a user tap within 1.5 s.
    var userGesture: Bool
    /// Looks like a pre-roll/mid-roll ad (ad player classes, ad server, "Skip ad" overlay).
    var isAd: Bool

    init?(message body: [String: Any], frame: WKFrameInfo?) {
        let s = body["src"] as? String ?? ""
        isBlob = body["blob"] as? Bool ?? false
        src = s.isEmpty ? nil : URL(string: s)
        guard src != nil || isBlob else { return nil }
        title = body["title"] as? String ?? ""
        page = (body["page"] as? String).flatMap(URL.init(string:))
        time = body["time"] as? Double ?? 0
        duration = body["duration"] as? Double ?? 0
        playing = body["playing"] as? Bool ?? false
        reason = body["reason"] as? String ?? ""
        muted = body["muted"] as? Bool ?? false
        loop = body["loop"] as? Bool ?? false
        viewWidth = body["vw"] as? Double ?? 0
        userGesture = body["gesture"] as? Bool ?? false
        isAd = body["ad"] as? Bool ?? false
        self.frame = frame
    }

    var key: String { src?.absoluteString ?? "blob:\(page?.absoluteString ?? "")" }
}

enum VideoSniffer {
    /// Injected into every frame at document start.
    static func script(compat: Bool) -> String {
        "window.__faVCfg={compat:\(compat)};" + js
    }

    private static let js = #"""
    (function(){
    if (window.__faV) return;
    var cfg=window.__faVCfg||{};
    var post=function(m){ try{ window.webkit.messageHandlers.fa.postMessage(m);}catch(e){} };
    if (cfg.compat) {
      // Without MSE, players fall back to plain mp4/HLS URLs the native player can open.
      ['MediaSource','ManagedMediaSource','WebKitMediaSource'].forEach(function(k){
        try{ Object.defineProperty(window,k,{value:undefined,configurable:true,writable:true}); }catch(e){} });
    }
    var sent={};
    function abs(u){ try{ return new URL(u, location.href).href; }catch(e){ return u||''; } }
    function srcOf(v){ var s=v.currentSrc||v.src; if(!s){ var so=v.querySelector('source[src]'); if(so) s=so.src; } return s||''; }
    var AD_CLASS=/(^|[\s_-])(ad|ads|advert|advertisement|preroll|pre-roll|midroll|vast|vpaid|ima|sponsor|sponsored)([\s_-]|$)|ad-showing|ad-playing|ad-interrupting|adplaying|jw-flag-ads|vjs-ad-playing|ima-ad|videoAdUi|adContainer|ad_container|adsbygoogle/i;
    var AD_HOST=/(doubleclick\.net|googlesyndication\.com|imasdk\.googleapis\.com|2mdn\.net|adnxs\.com|springserve|spotx|innovid|teads\.tv|adform|smartadserver|serving-sys|vidoomy|aniview|adtelligent|pubmatic|rubiconproject|criteo|exoclick|trafficjunky|juicyads|adsterra|admicro|adtima|eclick\.vn|ambientplatform|vliplatform|adsota)/i;
    var AD_PATH=/[\/_.-](preroll|pre-roll|vast|adserver|ads?)[\/_.-]/i;
    var AD_TEXT=/(^|\s)(ad|ads|quảng cáo|advertisement|sponsored|广告|広告|광고)(\s|$|·|:)|skip ad|bỏ qua|跳过|skip in|\bad\s*\d+\s*(of|\/)\s*\d+/i;
    function isAd(v){
      try{
        var s=srcOf(v); if(s && s.indexOf('blob:')!==0 && (AD_HOST.test(s)||AD_PATH.test(s))) return true;
        for(var e=v,i=0;e&&e!==document.body&&i<8;e=e.parentElement,i++){
          var c=(typeof e.className==='string'?e.className:'')+' '+(e.id||''); if(AD_CLASS.test(c)) return true; }
        // "Ad · 0:05", "Skip ad in 5", "Quảng cáo" overlays drawn around a short video.
        var d=isFinite(v.duration)?v.duration:0;
        if(d>0 && d<=90){ var box=v.parentElement; for(var k=0;k<3&&box&&box.parentElement&&box!==document.body;k++) box=box.parentElement;
          if(box && AD_TEXT.test((box.innerText||'').slice(0,400))) return true; }
      }catch(e){}
      return false; }
    function info(v){ var r=v.getBoundingClientRect();
      return {time:v.currentTime||0, duration:isFinite(v.duration)?v.duration:0, playing:!v.paused&&!v.ended,
              w:v.videoWidth||r.width, h:v.videoHeight||r.height, poster:v.poster||'',
              muted:!!v.muted, loop:!!v.loop, vw:r.width, gesture:(Date.now()-lastTouch)<1500, ad:isAd(v)}; }
    var lastTouch=0; ['touchend','click','keydown'].forEach(function(t){ document.addEventListener(t,function(){ lastTouch=Date.now(); },{capture:true,passive:true}); });
    function report(src, v, reason){
      src=abs(src); var blob=!src || src.indexOf('blob:')===0 || src.indexOf('mediasource:')===0;
      var d={type:'video', src:blob?'':src, blob:blob, reason:reason, title:(window.top===window?document.title:'')||'', page:location.href};
      if(v){ var i=info(v); for(var k in i) d[k]=i[k]; }
      var key=(blob?'blob':src)+'|'+reason;
      if(reason!=='play' && reason!=='replace' && sent[key]) return; sent[key]=1;
      post(d);
    }
    document.addEventListener('play', function(e){ var v=e.target; if(!v||v.tagName!=='VIDEO') return;
      if(window.__faV.takeover){
        // Ads keep running (muted) so their countdown and "skip" button still work.
        if(isAd(v)){ try{ v.muted=true; }catch(x){} report(srcOf(v), v, 'play'); return; }
        try{ v.pause(); }catch(x){} report(srcOf(v), v, 'replace'); return; }
      report(srcOf(v), v, 'play'); }, true);
    document.addEventListener('loadedmetadata', function(e){ var v=e.target; if(v&&v.tagName==='VIDEO') report(srcOf(v), v, 'meta'); }, true);

    var isM3U8=function(u){ return /\.m3u8(\?|#|$)/i.test(u); };
    try { var oo=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(m,u){ try{ if(u && isM3U8(String(u))) report(String(u), null, 'net'); }catch(e){} return oo.apply(this, arguments); }; } catch(e){}
    try { var of=window.fetch; if(of) window.fetch=function(i){ try{ var u=typeof i==='string'?i:(i&&i.url); if(u && isM3U8(u)) report(u, null, 'net'); }catch(e){} return of.apply(this, arguments); }; } catch(e){}

    function all(){ return Array.prototype.slice.call(document.querySelectorAll('video')); }
    function best(){ var vs=all().filter(function(v){ return !isAd(v); }); if(!vs.length) vs=all(); var p=vs.filter(function(v){ return !v.paused; }); if(p.length) return p[0];
      vs.sort(function(a,b){ return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight; }); return vs[0]; }
    window.__faV={ takeover:false,
      list:function(){ return all().map(function(v){ var d=info(v); var s=abs(srcOf(v)); d.blob=!s||s.indexOf('blob:')===0; d.src=d.blob?'':s; d.page=location.href; d.title=document.title; return d; }); },
      pause:function(){ all().forEach(function(v){ try{ if(isAd(v)) v.muted=true; else v.pause(); }catch(e){} }); },
      setTakeover:function(on){ this.takeover=!!on; if(on) this.pause(); return true; },
      resumeAt:function(t){ this.takeover=false; var v=best(); if(!v) return false; try{ if(t>0) v.currentTime=t; v.play(); }catch(e){} return true; },
      playing:function(){ return all().some(function(v){ return !v.paused && !v.ended; }); },
      pip:function(){ var v=best(); if(!v) return false;
        try{ if(v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')){
               if(v.paused) v.play(); v.webkitSetPresentationMode(v.webkitPresentationMode==='picture-in-picture'?'inline':'picture-in-picture'); return true; }
             if(document.pictureInPictureEnabled){ v.requestPictureInPicture(); return true; } }catch(e){}
        return false; },
      fullscreen:function(){ var v=best(); if(!v) return false; try{ if(v.webkitEnterFullscreen){ v.webkitEnterFullscreen(); return true; } }catch(e){} return false; },
      lang:function(){ return (document.documentElement.lang||'').toLowerCase(); }
    };
    function scan(){ all().forEach(function(v){ var s=srcOf(v); if(s||v.readyState>0) report(s, v, 'meta'); }); }
    if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', scan); else scan();
    window.addEventListener('load', scan);
    })();
    """#
}
