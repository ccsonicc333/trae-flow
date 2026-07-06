(function () {
  var BRIDGE_SOURCE = 'mineradio-extension-bridge';
  var PAGE_SOURCE = 'mineradio-web-page';
  var BRIDGE_VERSION = '1.3.1';
  var PROXY_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  if (window.__mineradioBridgeInjected) {
    window.postMessage({ source: BRIDGE_SOURCE, type: 'MINERADIO_BRIDGE_READY', version: BRIDGE_VERSION, extId: chrome.runtime.id }, '*');
    window.postMessage({ source: BRIDGE_SOURCE, type: 'MINERADIO_BRIDGE_PONG', ready: true, version: BRIDGE_VERSION, extId: chrome.runtime.id }, '*');
    try { chrome.runtime.sendMessage({ type: 'MINERADIO_ENSURE_MEDIA_RULES' }); } catch (_) {}
    return;
  }
  window.__mineradioBridgeInjected = true;
  window.__mineradioBridgeExtId = chrome.runtime && chrome.runtime.id;

  function proxyRefererFor(url) {
    if (/qqmusic|gtimg|qpic|y\.qq/i.test(url)) return 'https://y.qq.com/';
    if (/kugou/i.test(url)) return 'https://www.kugou.com/';
    return 'https://music.163.com/';
  }

  function postToPage(payload, transfer) {
    window.postMessage(Object.assign({ source: BRIDGE_SOURCE }, payload), '*', transfer || []);
  }

  async function fetchBinaryInContentScript(payload) {
    var query = payload.query || {};
    var targetUrl = query.url;
    if (!targetUrl) throw new Error('Missing url');
    var extraHeaders = payload.headers && typeof payload.headers === 'object' ? payload.headers : {};
    var resp = await fetch(targetUrl, {
      method: payload.method || 'GET',
      headers: Object.assign({
        'User-Agent': PROXY_UA,
        Referer: proxyRefererFor(targetUrl),
      }, extraHeaders),
    });
    if (!resp.ok) throw new Error('proxy fetch failed: ' + resp.status);
    var buffer = await resp.arrayBuffer();
    return {
      __binary: true,
      status: resp.status,
      contentType: resp.headers.get('content-type') || 'application/octet-stream',
      buffer: buffer,
    };
  }

  window.addEventListener('message', function (event) {
    if (event.source !== window) return;
    var data = event.data;
    if (!data || data.source !== PAGE_SOURCE) return;

    if (data.type === 'MINERADIO_BRIDGE_PING' || data.type === 'MINERADIO_BRIDGE_PROBE') {
      if (data.type === 'MINERADIO_BRIDGE_PROBE') {
        try {
          chrome.runtime.sendMessage({
            type: 'MINERADIO_FORCE_INJECT',
            pageUrl: data.pageUrl || String(window.location && window.location.href || ''),
            force: !!data.force,
          });
        } catch (_) {}
      }
      postToPage({ type: 'MINERADIO_BRIDGE_PONG', ready: true, version: BRIDGE_VERSION, extId: chrome.runtime.id });
      return;
    }

    if (data.type === 'MINERADIO_API') {
      var id = data.id;
      var payload = data.payload || {};
      var path = payload.path || '';

      if (path === '/api/audio' || path === '/api/cover') {
        fetchBinaryInContentScript(payload).then(function (result) {
          var transfer = result && result.buffer instanceof ArrayBuffer ? [result.buffer] : [];
          postToPage({
            type: 'MINERADIO_API_RESPONSE',
            id: id,
            ok: true,
            data: result,
          }, transfer);
        }).catch(function (err) {
          postToPage({
            type: 'MINERADIO_API_RESPONSE',
            id: id,
            ok: false,
            error: (err && err.message) || String(err),
          });
        });
        return;
      }

      chrome.runtime.sendMessage(
        { type: 'MINERADIO_API', payload: payload },
        function (response) {
          if (chrome.runtime.lastError) {
            postToPage({
              type: 'MINERADIO_API_RESPONSE',
              id: id,
              ok: false,
              error: chrome.runtime.lastError.message || 'Extension unavailable',
            });
            return;
          }
          var result = response && response.data;
          var transfer = [];
          if (result && result.__binary && result.buffer instanceof ArrayBuffer) {
            transfer.push(result.buffer);
          }
          postToPage({
            type: 'MINERADIO_API_RESPONSE',
            id: id,
            ok: !!(response && response.ok),
            data: result,
            error: response && response.error,
          }, transfer);
        },
      );
    }
  });

  postToPage({ type: 'MINERADIO_BRIDGE_READY', version: BRIDGE_VERSION, extId: chrome.runtime.id });
  try {
    chrome.runtime.sendMessage({ type: 'MINERADIO_ENSURE_MEDIA_RULES' });
  } catch (_) {}
})();
