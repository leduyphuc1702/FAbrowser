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
    function info(v){ var r=v.getBoundingClientRect();
      return {time:v.currentTime||0, duration:isFinite(v.duration)?v.duration:0, playing:!v.paused&&!v.ended,
              w:v.videoWidth||r.width, h:v.videoHeight||r.height, poster:v.poster||'',
              muted:!!v.muted, loop:!!v.loop, vw:r.width, gesture:(Date.now()-lastTouch)<1500}; }
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
      if(window.__faV.takeover){ try{ v.pause(); }catch(x){} report(srcOf(v), v, 'replace'); return; }
      report(srcOf(v), v, 'play'); }, true);
    document.addEventListener('loadedmetadata', function(e){ var v=e.target; if(v&&v.tagName==='VIDEO') report(srcOf(v), v, 'meta'); }, true);

    var isM3U8=function(u){ return /\.m3u8(\?|#|$)/i.test(u); };
    try { var oo=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(m,u){ try{ if(u && isM3U8(String(u))) report(String(u), null, 'net'); }catch(e){} return oo.apply(this, arguments); }; } catch(e){}
    try { var of=window.fetch; if(of) window.fetch=function(i){ try{ var u=typeof i==='string'?i:(i&&i.url); if(u && isM3U8(u)) report(u, null, 'net'); }catch(e){} return of.apply(this, arguments); }; } catch(e){}

    function all(){ return Array.prototype.slice.call(document.querySelectorAll('video')); }
    function best(){ var vs=all(), p=vs.filter(function(v){ return !v.paused; }); if(p.length) return p[0];
      vs.sort(function(a,b){ return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight; }); return vs[0]; }
    window.__faV={ takeover:false,
      list:function(){ return all().map(function(v){ var d=info(v); var s=abs(srcOf(v)); d.blob=!s||s.indexOf('blob:')===0; d.src=d.blob?'':s; d.page=location.href; d.title=document.title; return d; }); },
      pause:function(){ all().forEach(function(v){ try{ v.pause(); }catch(e){} }); },
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
