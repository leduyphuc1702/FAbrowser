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
    var AD_PATH=/[\/_.-](preroll|pre-roll|midroll|vast|vmap|vpaid|adserver|adserve|ads?)[\/_.-]/i;
    var AD_TEXT=/(^|\s)(ad|ads|quảng cáo|advertisement|sponsored|广告|広告|광고)(\s|$|·|:)|skip ad|bỏ qua (quảng cáo|sau|trong|\(?\d)|跳过广告|skip in|\bad\s*\d+\s*(of|\/)\s*\d+/i;
    // Media URLs listed in VAST/VMAP responses the page fetched: whatever plays them is an ad.
    var adMedia={};
    // A whole frame served by an ad network (overlay, outstream or sticky player iframes).
    var adFrame=false; try{ adFrame=window.top!==window && (AD_HOST.test(location.hostname)||AD_PATH.test(location.pathname)); }catch(e){}
    function adURL(u){ if(!u||u.indexOf('blob:')===0) return false; u=abs(u); return !!adMedia[u]||AD_HOST.test(u)||AD_PATH.test(u); }
    function site(h){ var p=(h||'').toLowerCase().split('.'); return p.slice(p.length>2&&p[p.length-2].length<=3?-3:-2).join('.'); }
    function offSite(h){ h=(h||'').trim(); if(!h||h.charAt(0)==='#'||/^javascript:/i.test(h)) return false;
      try{ var u=new URL(h, location.href); return /^https?:$/.test(u.protocol) && site(u.hostname)!==site(location.hostname); }catch(e){ return false; } }
    function up(e){ return e.parentElement||(e.parentNode&&e.parentNode.host)||null; }
    function isAd(v){
      try{
        if(adFrame || adURL(srcOf(v))) return true;
        for(var e=v,i=0;e&&e!==document.body&&i<10;e=up(e),i++){
          var c=(typeof e.className==='string'?e.className:'')+' '+(e.id||''); if(AD_CLASS.test(c)) return true;
          // Outstream ads and promo clips open another site when tapped (feeds link videos to their own pages).
          if(e.tagName==='A' && offSite(e.getAttribute('href'))) return true; }
        // "Ad · 0:05", "Skip ad in 5", "Quảng cáo" overlays drawn around a short video.
        var d=isFinite(v.duration)?v.duration:0;
        if(d>0 && d<=90){ var box=up(v); for(var k=0;k<3&&box&&up(box)&&box!==document.body;k++) box=up(box);
          if(box && AD_TEXT.test((box.innerText||box.textContent||'').slice(0,400))) return true; }
      }catch(e){}
      return false; }
    function scanAdList(text){
      if(!text || !/<(VAST|VMAP)[\s>]/.test(text)) return;
      var re=/<MediaFile[^>]*>\s*(?:<!\[CDATA\[)?\s*([^<\]\s]+)/gi, m;
      while((m=re.exec(text))){ var u=abs(m[1].replace(/&amp;/g,'&')); if(adMedia[u]) continue; adMedia[u]=1;
        post({type:'video', src:u, blob:false, reason:'admedia', ad:true, page:location.href}); } }
    function info(v){ var r=v.getBoundingClientRect();
      return {time:v.currentTime||0, duration:isFinite(v.duration)?v.duration:0, playing:!v.paused&&!v.ended,
              w:v.videoWidth||r.width, h:v.videoHeight||r.height, poster:v.poster||'',
              muted:!!v.muted, loop:!!v.loop, vw:r.width, gesture:(Date.now()-lastTouch)<1500, ad:isAd(v)}; }
    var lastTouch=0; ['touchend','click','keydown'].forEach(function(t){ document.addEventListener(t,function(){ lastTouch=Date.now(); },{capture:true,passive:true}); });
    function report(src, v, reason){
      src=abs(src); var blob=!src || src.indexOf('blob:')===0 || src.indexOf('mediasource:')===0;
      var d={type:'video', src:blob?'':src, blob:blob, reason:reason, title:(window.top===window?document.title:'')||'', page:location.href};
      if(v){ var i=info(v); for(var k in i) d[k]=i[k]; } else { d.ad=adFrame||adURL(src); }
      var key=(blob?'blob':src)+'|'+reason;
      if(reason!=='play' && reason!=='replace' && sent[key]) return; sent[key]=1;
      post(d);
    }
    function onPlay(e){ var v=e.target; if(!v||v.tagName!=='VIDEO') return;
      v.__faMuted=v.muted;
      if(window.__faV.takeover){
        // Ads keep running (muted) so their countdown and "skip" button still work.
        if(isAd(v)){ try{ v.muted=true; }catch(x){} report(srcOf(v), v, 'play'); return; }
        try{ v.pause(); }catch(x){} report(srcOf(v), v, 'replace'); return; }
      report(srcOf(v), v, 'play'); }
    function onMeta(e){ var v=e.target; if(v&&v.tagName==='VIDEO') report(srcOf(v), v, 'meta'); }
    // Muted autoplay that the user turns the sound on for: they're watching this one.
    function onVolume(e){ var v=e.target; if(!v||v.tagName!=='VIDEO') return;
      var was=v.__faMuted; v.__faMuted=v.muted;
      if(was && !v.muted && !v.paused && (Date.now()-lastTouch)<1500) onPlay(e); }
    function listen(t){ t.addEventListener('play', onPlay, true); t.addEventListener('loadedmetadata', onMeta, true); t.addEventListener('volumechange', onVolume, true); }
    listen(document);
    // Media events don't leave a shadow tree, and closed shadow roots can't be queried later: keep each one as it's made.
    var roots=[];
    try { var oas=Element.prototype.attachShadow; if(oas) Element.prototype.attachShadow=function(){ var r=oas.apply(this, arguments); try{ roots.push(r); listen(r); }catch(e){} return r; }; } catch(e){}

    var isM3U8=function(u){ return /\.m3u8(\?|#|$)/i.test(u); };
    var adList=function(u){ return /vast|vmap|vpaid|[\/_.?&-]ads?[\/_.?=&-]|adserv|adtag|ad_tag|preroll/i.test(u)||AD_HOST.test(u); };
    try { var oo=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(m,u){
      try{ var s=String(u||'');
        if(isM3U8(s)) report(s, null, 'net');
        this.addEventListener('load', function(){ try{ var t=this.responseType; if(t===''||t==='text') scanAdList(this.responseText);
          else if(t==='document' && this.responseXML) scanAdList(new XMLSerializer().serializeToString(this.responseXML)); }catch(e){} });
      }catch(e){} return oo.apply(this, arguments); }; } catch(e){}
    try { var of=window.fetch; if(of) window.fetch=function(i){
      var p=of.apply(this, arguments);
      try{ var u=typeof i==='string'?i:(i&&i.url)||String(i||'');
        if(u && isM3U8(u)) report(u, null, 'net');
        if(p && p.then) p.then(function(r){ try{ var ct=(r.headers.get('content-type')||'').toLowerCase();
          if(ct.indexOf('xml')>=0 || (adList(u) && ct.indexOf('video')<0 && ct.indexOf('image')<0)) r.clone().text().then(scanAdList, function(){}); }catch(e){} }, function(){});
      }catch(e){} return p; }; } catch(e){}

    function all(){ var out=Array.prototype.slice.call(document.querySelectorAll('video'));
      roots.forEach(function(r){ try{ if(r.host && r.host.isConnected) out=out.concat(Array.prototype.slice.call(r.querySelectorAll('video'))); }catch(e){} });
      return out; }
    // Content players are big, long and not looping; previews and corner ads are the opposite.
    function weight(v){ var r=v.getBoundingClientRect(), d=isFinite(v.duration)?v.duration:0;
      return r.width*r.height/1000 + (d>=120?80:d>60?40:d>0&&d<=30?-80:0) - (v.loop?150:0) - (!v.paused&&v.muted?40:0) + (!v.paused&&!v.muted?120:0); }
    function best(){ var vs=all().filter(function(v){ return !isAd(v); }); if(!vs.length) vs=all();
      vs.sort(function(a,b){ return weight(b)-weight(a); }); return vs[0]; }
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
