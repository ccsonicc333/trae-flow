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

    /// 构造注入脚本
    static func makeUserScript() -> WKUserScript {
        let script = scriptSource
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
