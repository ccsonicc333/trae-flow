import Foundation
import WebKit

/// Spec: mineradio-bridge-compat-layer — WKUserScript 注入到 mineradio.art 页面。
/// 在 `atDocumentStart` 注入，模拟 Mineradio Bridge 浏览器扩展的 content script：
/// 1. 标记 `window.__mineradioBridgeInjected = true` 并主动发 `MINERADIO_BRIDGE_READY`
/// 2. 监听 `window.message`（`source === 'mineradio-web-page'`）：
///    - `MINERADIO_BRIDGE_PING` / `MINERADIO_BRIDGE_PROBE` → 回 `MINERADIO_BRIDGE_PONG`
///    - `MINERADIO_API` + path `/api/audio`|`/api/cover` → `webkit.messageHandlers.mineradioBinary`
///    - `MINERADIO_API` 其他 → `webkit.messageHandlers.mineradioApi`
/// 3. 暴露 `window.__mineradioDeliverJSON(jsonStr)` —— Swift 通过 `evaluateJavaScript` 回传结果，
///    二进制响应（`data.__binary === true` 且 `data.buffer` 为 base64 字符串）自动转 ArrayBuffer
///    并通过 `postMessage` 的 transfer 参数回传网页。
enum MineradioBridgeUserScript {
    /// 桌面 Chrome UA（与扩展 content-bridge.js 的 PROXY_UA 一致）
    static let desktopChromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// Bridge 版本标识
    static let bridgeVersion = "trae-flow-1.0"

    /// API 消息处理器名（普通 API 请求）
    static let apiMessageHandlerName = "mineradioApi"

    /// 二进制消息处理器名（/api/audio、/api/cover）
    static let binaryMessageHandlerName = "mineradioBinary"

    /// 播放状态消息处理器名（音频元素事件 + 歌曲 ID 变化）
    static let playbackMessageHandlerName = "mineradioPlayback"

    /// 构造注入脚本
    static func makeUserScript() -> WKUserScript {
        let script = scriptSource + "\n" + playbackHookSource
        return WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// 脚本源码
    static let scriptSource: String = #"""
(function () {
  var BRIDGE_VERSION = 'trae-flow-1.0';
  var EXT_ID = 'trae-flow';
  var BRIDGE_SOURCE = 'mineradio-extension-bridge';
  var PAGE_SOURCE = 'mineradio-web-page';

  function postToPage(payload, transfer) {
    var msg = Object.assign({ source: BRIDGE_SOURCE }, payload);
    window.postMessage(msg, '*', transfer || []);
  }

  if (window.__mineradioBridgeInjected) {
    postToPage({ type: 'MINERADIO_BRIDGE_READY', version: BRIDGE_VERSION, extId: EXT_ID });
    postToPage({ type: 'MINERADIO_BRIDGE_PONG', ready: true, version: BRIDGE_VERSION, extId: EXT_ID });
    return;
  }
  window.__mineradioBridgeInjected = true;
  window.__mineradioBridgeExtId = EXT_ID;

  function base64ToArrayBuffer(b64) {
    var binary = atob(b64);
    var len = binary.length;
    var bytes = new Uint8Array(len);
    for (var i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  window.addEventListener('message', function (event) {
    if (event.source !== window) return;
    var data = event.data;
    if (!data || data.source !== PAGE_SOURCE) return;

    if (data.type === 'MINERADIO_BRIDGE_PING' || data.type === 'MINERADIO_BRIDGE_PROBE') {
      postToPage({ type: 'MINERADIO_BRIDGE_PONG', ready: true, version: BRIDGE_VERSION, extId: EXT_ID });
      return;
    }

    if (data.type === 'MINERADIO_API') {
      var id = data.id;
      var payload = data.payload || {};
      var path = payload.path || '';

      if (path === '/api/audio' || path === '/api/cover') {
        try {
          webkit.messageHandlers.mineradioBinary.postMessage({ id: id, payload: payload });
        } catch (err) {
          postToPage({ type: 'MINERADIO_API_RESPONSE', id: id, ok: false, error: 'binary handler error: ' + (err && err.message || String(err)) });
        }
      } else {
        try {
          webkit.messageHandlers.mineradioApi.postMessage({ id: id, payload: payload });
        } catch (err) {
          postToPage({ type: 'MINERADIO_API_RESPONSE', id: id, ok: false, error: 'api handler error: ' + (err && err.message || String(err)) });
        }
      }
    }
  });

  // Swift 通过 evaluateJavaScript 调用此函数回传 API 结果。
  // jsonStr = JSON.stringify({ id, ok, data, error })
  // data 可能含 { __binary: true, status, contentType, buffer: "<base64>" } —— 二进制响应。
  window.__mineradioDeliverJSON = function (jsonStr) {
    var msg;
    try { msg = JSON.parse(jsonStr); }
    catch (err) { console.error('[MineradioBridge] deliver parse error', err); return; }

    var id = msg.id;
    var ok = !!msg.ok;
    var data = msg.data || null;
    var error = msg.error || null;

    if (data && data.__binary && typeof data.buffer === 'string') {
      // base64 → ArrayBuffer，通过 transfer 传回避免拷贝
      var ab = base64ToArrayBuffer(data.buffer);
      data.buffer = ab;
      postToPage({ type: 'MINERADIO_API_RESPONSE', id: id, ok: ok, data: data, error: error }, [ab]);
    } else {
      postToPage({ type: 'MINERADIO_API_RESPONSE', id: id, ok: ok, data: data, error: error });
    }
  };

  // 主动通知网页 Bridge 已就绪
  postToPage({ type: 'MINERADIO_BRIDGE_READY', version: BRIDGE_VERSION, extId: EXT_ID });
})();
"""#

    /// Spec: mineradio-bridge-compat-layer — 播放状态 hook 脚本。
    ///
    /// 在 Bridge 脚本之后注入，负责：
    /// 1. 监听 `MINERADIO_API` 消息：从 `/api/song/url?id=xxx`、`/api/lyric?id=xxx` 提取歌曲 ID
    /// 2. Patch `window.Audio` 构造器 —— mineradio.art 用 `new Audio()` 创建音频元素但从不
    ///    appendChild 到 DOM（detached），MutationObserver + DOM 扫描完全失效。Patch 构造器
    ///    直接 wrap 新建的 audio 元素并绑定事件监听器。
    /// 3. 兜底：MutationObserver + 定期扫描 DOM 中的 `<audio>` 元素（对其他网站有效）
    /// 4. best-effort 从 DOM 提取歌曲标题/艺术家（过滤页面标题 "Mineradio — 在线音乐可视化播放器"）
    ///
    /// 消息格式（post 到 `mineradioPlayback` handler）：
    /// - `{ type: 'playback', elapsed, duration, isPlaying, songId, provider }`
    /// - `{ type: 'song', songId, provider, title, artist }`
    static let playbackHookSource: String = #"""
(function () {
  var currentSongId = null;
  var currentProvider = 'netease';
  var lastPostedSongId = null;
  var lastPostedPlayback = 0;

  function postMsg(payload) {
    try {
      webkit.messageHandlers.mineradioPlayback.postMessage(payload);
    } catch (_) {}
  }

  function postPlayback(audio) {
    if (!audio) return;
    var now = Date.now();
    if (now - lastPostedPlayback < 200) return; // throttle 200ms
    lastPostedPlayback = now;
    postMsg({
      type: 'playback',
      elapsed: audio.currentTime || 0,
      duration: (isFinite(audio.duration) && audio.duration > 0) ? audio.duration : 0,
      isPlaying: !audio.paused && !audio.ended,
      songId: currentSongId,
      provider: currentProvider
    });
  }

  // 判断文本是否疑似歌曲标题（排除页面标题 "Mineradio — 在线音乐可视化播放器"、"本地歌曲" 等）
  function isLikelySongTitle(text) {
    if (!text) return false;
    var trimmed = text.trim();
    if (trimmed.length === 0 || trimmed.length > 200) return false;
    var lower = trimmed.toLowerCase();
    if (lower.indexOf('mineradio') >= 0) return false;
    if (trimmed.indexOf('播放器') >= 0) return false;
    if (trimmed.indexOf('在线音乐') >= 0) return false;
    if (trimmed === '本地歌曲' || trimmed.indexOf('本地歌曲') >= 0) return false;
    return true;
  }

  function postSong() {
    if (lastPostedSongId === currentSongId) return;
    lastPostedSongId = currentSongId;
    var title = null, artist = null, coverURL = null;
    try {
      // best-effort: 从播放器 DOM 提取标题/艺术家（过滤页面标题）
      var titleCandidates = [
        '[class*="now-playing"] [class*="title"]',
        '[class*="song-title"]', '[class*="track-title"]',
        '[class*="song-name"]', '[class*="track-name"]',
        '[data-song-title]', '[data-song-name]'
      ];
      for (var i = 0; i < titleCandidates.length; i++) {
        var el = document.querySelector(titleCandidates[i]);
        if (el) {
          var t = el.textContent.trim();
          if (t && isLikelySongTitle(t)) { title = t; break; }
        }
      }
      var artistCandidates = [
        '[class*="now-playing"] [class*="artist"]',
        '[class*="song-artist"]', '[class*="track-artist"]'
      ];
      for (var j = 0; j < artistCandidates.length; j++) {
        var aEl = document.querySelector(artistCandidates[j]);
        if (aEl && aEl.textContent.trim()) { artist = aEl.textContent.trim(); break; }
      }
      // best-effort: 提取专辑封面 URL
      // mineradio.art 的 DOM 结构：
      //   - <img id="thumb-cover"> 左下角缩略图（img.src）
      //   - <div id="control-cover"> 播放栏封面（div.style.backgroundImage: url("...")）
      //   - <div id="album-bg"> 全屏背景（同上）
      // 封面 URL 格式：data:image/...;base64,...（已加载）或 https://... 直链
      // 过滤掉网站根 URL（如 https://mineradio.art/）等明显非封面值
      function isValidCoverURL(url) {
        if (!url) return false;
        if (url.indexOf('data:image/') === 0) return true;
        if (url.indexOf('blob:') === 0) return false; // blob URL 无法在 Swift 端加载
        if (url.indexOf('http://') === 0 || url.indexOf('https://') === 0) {
          // 排除网站根 URL（如 https://mineradio.art/）
          var path = url.replace(/^https?:\/\/[^/]+/, '');
          if (path === '/' || path === '') return false;
          return true;
        }
        return false;
      }
      var thumbImg = document.getElementById('thumb-cover');
      if (thumbImg) {
        var src = thumbImg.src || thumbImg.getAttribute('data-src') || '';
        if (isValidCoverURL(src)) { coverURL = src; }
      }
      if (!coverURL) {
        // 从 #control-cover 的 background-image 提取 url(...)
        var coverDiv = document.getElementById('control-cover');
        if (coverDiv) {
          var bg = coverDiv.style.backgroundImage || '';
          // background-image: url("...") 或 url(...)
          var match = bg.match(/url\(["']?([^"')]+)["']?\)/);
          if (match && match[1] && isValidCoverURL(match[1])) { coverURL = match[1]; }
        }
      }
      if (!coverURL) {
        // 兜底：从 #album-bg 全屏背景提取
        var bgDiv = document.getElementById('album-bg');
        if (bgDiv) {
          var bg2 = bgDiv.style.backgroundImage || '';
          var match2 = bg2.match(/url\(["']?([^"')]+)["']?\)/);
          if (match2 && match2[1] && isValidCoverURL(match2[1])) { coverURL = match2[1]; }
        }
      }
    } catch (_) {}
    postMsg({ type: 'song', songId: currentSongId, provider: currentProvider, title: title, artist: artist, coverURL: coverURL });
  }

  function attachAudio(audio) {
    if (!audio || audio.__mineradioHooked) return;
    audio.__mineradioHooked = true;
    var events = ['timeupdate', 'play', 'pause', 'loadedmetadata', 'ended'];
    for (var i = 0; i < events.length; i++) {
      audio.addEventListener(events[i], function () { postPlayback(audio); });
    }
    postPlayback(audio);
  }

  function scanAudios() {
    try {
      var audios = document.querySelectorAll('audio');
      for (var i = 0; i < audios.length; i++) attachAudio(audios[i]);
    } catch (_) {}
  }

  // Spec: mineradio.art 用 `new Audio()` 创建音频元素但从不 appendChild 到 DOM（detached）。
  // 三重 hook 策略确保拦截所有 audio 创建/播放路径：
  // 1. Patch window.Audio 构造器 — 拦截 `new Audio()`
  // 2. Patch HTMLMediaElement.prototype.play — 拦截任何 audio/video 调用 play()
  // 3. Patch HTMLMediaElement.prototype.src setter — 拦截设置 src
  // 4. MutationObserver + 定期扫描 DOM 作为兜底
  try {
    if (!window.__mineradioAudioPatched) {
      window.__mineradioAudioPatched = true;

      // 1. Patch window.Audio 构造器
      var OriginalAudio = window.Audio;
      if (OriginalAudio) {
        var PatchedAudio = function () {
          var el = new (Function.prototype.bind.apply(OriginalAudio, [null].concat(Array.from(arguments))))();
          attachAudio(el);
          return el;
        };
        PatchedAudio.prototype = OriginalAudio.prototype;
        Object.defineProperty(window, 'Audio', {
          value: PatchedAudio,
          writable: true,
          configurable: true
        });
      }

      // 2. Patch HTMLMediaElement.prototype.play — 最可靠：任何 audio 元素调用 play 都会触发
      var OriginalPlay = HTMLMediaElement.prototype.play;
      if (OriginalPlay) {
        HTMLMediaElement.prototype.play = function () {
          attachAudio(this);
          return OriginalPlay.apply(this, arguments);
        };
      }

      // 3. Patch HTMLMediaElement.prototype.src setter — 设置 src 时即 attach（早于 play）
      var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (srcDesc && srcDesc.set) {
        var origSrcSet = srcDesc.set;
        var origSrcGet = srcDesc.get;
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          get: function () { return origSrcGet ? origSrcGet.call(this) : ''; },
          set: function (v) {
            attachAudio(this);
            if (origSrcSet) origSrcSet.call(this, v);
          },
          configurable: true,
          enumerable: true
        });
      }
    }
  } catch (e) {
    try { console.error('[MineradioPlayback] audio hook failed:', e && e.message || e); } catch (_) {}
  }

  // 拦截网页发出的 MINERADIO_API 消息，提取歌曲 ID
  window.addEventListener('message', function (event) {
    if (event.source !== window) return;
    var data = event.data;
    if (!data || data.source !== 'mineradio-web-page') return;
    if (data.type !== 'MINERADIO_API') return;
    var payload = data.payload || {};
    var path = payload.path || '';
    var query = payload.query || {};
    var idFields = ['id', 'songId', 'song_id'];
    function extractId(obj) {
      for (var k = 0; k < idFields.length; k++) {
        var v = obj[idFields[k]];
        if (v != null && String(v) !== '') return String(v);
      }
      return null;
    }
    // 这些路径携带当前播放歌曲 ID（三平台分别匹配）
    var neteaseSongPaths = ['/api/song/url', '/api/lyric', '/api/song/like/check', '/api/song/like', '/api/song/comments'];
    var qqSongPaths = ['/api/qq/song/url', '/api/qq/lyric', '/api/qq/song/like/check', '/api/qq/song/like'];
    var kgSongPaths = ['/api/kg/song/url', '/api/kg/lyric', '/api/kg/song/like'];
    var sid = null;
    if (neteaseSongPaths.indexOf(path) >= 0) {
      sid = extractId(query) || extractId(payload.body || {});
      currentProvider = 'netease';
    } else if (qqSongPaths.indexOf(path) >= 0) {
      // QQ 用 mid 字段
      var qqId = query.mid || query.songmid || query.id;
      if (qqId != null && String(qqId) !== '') sid = String(qqId);
      currentProvider = 'qq';
    } else if (kgSongPaths.indexOf(path) >= 0) {
      // 酷狗用 hash 字段
      var kgId = query.hash || query.id;
      if (kgId != null && String(kgId) !== '') sid = String(kgId);
      currentProvider = 'kugou';
    }
    if (sid && sid !== currentSongId) {
      currentSongId = sid;
      postSong();
    }
  });

  // MutationObserver：监听动态插入的 audio 元素（兜底，对其他网站有效）
  if (typeof MutationObserver !== 'undefined') {
    var obs = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var added = mutations[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var node = added[j];
          if (node.nodeType !== 1) continue;
          if (node.tagName === 'AUDIO') attachAudio(node);
          if (node.querySelectorAll) {
            try {
              var inner = node.querySelectorAll('audio');
              for (var k = 0; k < inner.length; k++) attachAudio(inner[k]);
            } catch (_) {}
          }
        }
      }
    });
    try { obs.observe(document.documentElement || document.body || document, { childList: true, subtree: true }); } catch (_) {}
  }

  // 定期扫描兜底（SPA 切换页面时 audio 元素可能被替换）
  setInterval(scanAudios, 2000);
  scanAudios();
})();
"""#
}

/// 供 Swift 端构造 `__mineradioDeliverJSON` 调用的 JSON 辅助工具。
enum MineradioBridgeDelivery {
    /// 将 API 响应序列化为 `__mineradioDeliverJSON` 参数 JSON 字符串。
    /// - Parameters:
    ///   - id: 请求 ID（与网页 `MINERADIO_API` 消息中的 `id` 对应）
    ///   - ok: 是否成功
    ///   - data: 响应数据（普通 API 为 router.js 返回值；二进制为 `{ __binary:true, status, contentType, buffer:<base64> }`）
    ///   - error: 错误信息（失败时）
    /// - Returns: JSON 字符串，供 `evaluateJavaScript("window.__mineradioDeliverJSON('\(escaped)')")` 使用
    static func makeDeliveryJSON(id: String, ok: Bool, data: Any?, error: String?) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let data = data { payload["data"] = data } else { payload["data"] = NSNull() }
        if let error = error { payload["error"] = error } else { payload["error"] = NSNull() }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return "{\"id\":\"\(id)\",\"ok\":false,\"data\":null,\"error\":\"serialization failed\"}"
        }
        return jsonStr
    }

    /// 将 JSON 字符串转义为可嵌入 JS 单引号字符串字面量的形式。
    /// 用于 `evaluateJavaScript("window.__mineradioDeliverJSON('\(escaped)')")`。
    static func escapeForJSSingleQuotedString(_ json: String) -> String {
        json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// 构造完整的 `evaluateJavaScript` 调用字符串。
    static func makeDeliverCall(id: String, ok: Bool, data: Any?, error: String?) -> String {
        let json = makeDeliveryJSON(id: id, ok: ok, data: data, error: error)
        let escaped = escapeForJSSingleQuotedString(json)
        return "window.__mineradioDeliverJSON('\(escaped)');"
    }
}
