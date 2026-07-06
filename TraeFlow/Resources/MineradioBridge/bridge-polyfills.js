// bridge-polyfills.js — JSC environment polyfills for Mineradio Bridge bundle.
// Loaded before bridge-bundle.js in JSContext. Provides fetch / chrome.cookies /
// URL / URLSearchParams / TextEncoder / TextDecoder / atob / btoa / crypto /
// console that the extension code (router.js + api/*.js + crypto-es.mjs) expects.
// fetch and chrome.cookies bridge to Swift via __mineradioNative* callbacks;
// the rest are pure-JS implementations.

(function () {
  var g = this;

  // -------------------------------------------------------------------------
  // Native callback registry
  // -------------------------------------------------------------------------
  if (typeof g.__mineradioCallbacks === 'undefined') {
    g.__mineradioCallbacks = new Map();
    g.__mineradioCallbackId = 1;
  }
  function newCallbackId() {
    return 'cb_' + (g.__mineradioCallbackId++) + '_' + Math.floor(Math.random() * 1e9).toString(36);
  }

  // -------------------------------------------------------------------------
  // console
  // -------------------------------------------------------------------------
  g.console = (function () {
    function nativeLog(level, args) {
      if (typeof g.__mineradioNativeLog === 'function') {
        try { g.__mineradioNativeLog(level, Array.prototype.slice.call(args).map(function (a) { return typeof a === 'object' ? JSON.stringify(a) : String(a); }).join(' ')); } catch (_) {}
      }
    }
    return {
      log: function () { nativeLog('log', arguments); },
      info: function () { nativeLog('info', arguments); },
      warn: function () { nativeLog('warn', arguments); },
      error: function () { nativeLog('error', arguments); },
      debug: function () { nativeLog('debug', arguments); },
      trace: function () { nativeLog('debug', arguments); },
    };
  })();

  // -------------------------------------------------------------------------
  // atob / btoa
  // -------------------------------------------------------------------------
  if (typeof g.atob === 'undefined' || typeof g.btoa === 'undefined') {
    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var B64_REV = {};
    for (var i = 0; i < B64.length; i++) B64_REV[B64[i]] = i;

    g.btoa = function (str) {
      str = String(str);
      var out = '';
      for (var block, charCode, idx = 0; str.length > idx || (str.length === idx && block > 0); idx += 3) {
        charCode = str.charCodeAt(idx) << 16 | (str.charCodeAt(idx + 1) || 0) << 8 | (str.charCodeAt(idx + 2) || 0);
        block = charCode >> 18 & 63; out += B64.charAt(block);
        block = charCode >> 12 & 63; out += B64.charAt(block);
        out += str.length > idx + 1 ? B64.charAt(charCode >> 6 & 63) : '=';
        out += str.length > idx + 2 ? B64.charAt(charCode & 63) : '=';
      }
      return out;
    };

    g.atob = function (str) {
      str = String(str).replace(/[^A-Za-z0-9+/=]/g, '').replace(/=+$/, '');
      var out = '';
      for (var bc = 0, bs = 0, buffer, i = 0; (buffer = str[i++]); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? out += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
        buffer = B64_REV[buffer];
      }
      return out;
    };
  }

  function base64ToArrayBuffer(b64) {
    var bin = g.atob(b64);
    var len = bin.length;
    var bytes = new Uint8Array(len);
    for (var i = 0; i < len; i++) bytes[i] = bin.charCodeAt(i);
    return bytes.buffer;
  }

  function stringToArrayBuffer(str) {
    var len = str.length;
    var bytes = new Uint8Array(len);
    for (var i = 0; i < len; i++) bytes[i] = str.charCodeAt(i) & 0xff;
    return bytes.buffer;
  }

  function utf8StringToArrayBuffer(str) {
    var utf8 = unescape(encodeURIComponent(str));
    var bytes = new Uint8Array(utf8.length);
    for (var i = 0; i < utf8.length; i++) bytes[i] = utf8.charCodeAt(i);
    return bytes.buffer;
  }

  // -------------------------------------------------------------------------
  // TextEncoder / TextDecoder (UTF-8 only)
  // -------------------------------------------------------------------------
  if (typeof g.TextEncoder === 'undefined') {
    g.TextEncoder = function TextEncoder() {};
    g.TextEncoder.prototype.encode = function (str) {
      var utf8 = unescape(encodeURIComponent(String(str)));
      var bytes = new Uint8Array(utf8.length);
      for (var i = 0; i < utf8.length; i++) bytes[i] = utf8.charCodeAt(i);
      return bytes;
    };
  }
  if (typeof g.TextDecoder === 'undefined') {
    g.TextDecoder = function TextDecoder(label) {
      this._label = (label || 'utf-8').toLowerCase();
    };
    g.TextDecoder.prototype.decode = function (input) {
      var bytes;
      if (input instanceof ArrayBuffer) bytes = new Uint8Array(input);
      else if (input && input.buffer instanceof ArrayBuffer) bytes = new Uint8Array(input.buffer, input.byteOffset || 0, input.byteLength || input.length);
      else if (input && typeof input.length === 'number') bytes = new Uint8Array(input);
      else return String(input || '');
      var bin = '';
      for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      try { return decodeURIComponent(escape(bin)); } catch (_) { return bin; }
    };
  }

  // -------------------------------------------------------------------------
  // crypto.getRandomValues
  // -------------------------------------------------------------------------
  if (typeof g.crypto === 'undefined') g.crypto = {};
  if (!g.crypto.getRandomValues) {
    g.crypto.getRandomValues = function (arr) {
      for (var i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256);
      return arr;
    };
  }

  // -------------------------------------------------------------------------
  // URLSearchParams
  // -------------------------------------------------------------------------
  if (typeof g.URLSearchParams === 'undefined') {
    g.URLSearchParams = function URLSearchParams(init) {
      this._params = [];
      if (init == null) return;
      if (typeof init === 'string') {
        var s = init.charAt(0) === '?' ? init.slice(1) : init;
        if (s) {
          var pairs = s.split('&');
          for (var i = 0; i < pairs.length; i++) {
            var eq = pairs[i].indexOf('=');
            if (eq < 0) { this._params.push([decodeURIComponent(pairs[i]), '']); }
            else { this._params.push([decodeURIComponent(pairs[i].slice(0, eq)), decodeURIComponent(pairs[i].slice(eq + 1))]); }
          }
        }
      } else if (typeof init === 'object') {
        if (Array.isArray(init)) {
          for (var j = 0; j < init.length; j++) {
            if (Array.isArray(init[j])) this._params.push([String(init[j][0]), String(init[j][1])]);
          }
        } else {
          var keys = Object.keys(init);
          for (var k = 0; k < keys.length; k++) {
            this._params.push([keys[k], String(init[keys[k]])]);
          }
        }
      }
    };
    g.URLSearchParams.prototype.append = function (name, value) { this._params.push([String(name), String(value)]); };
    g.URLSearchParams.prototype.set = function (name, value) {
      var found = false;
      var k = String(name), v = String(value);
      var out = [];
      for (var i = 0; i < this._params.length; i++) {
        if (this._params[i][0] === k) {
          if (!found) { out.push([k, v]); found = true; }
        } else out.push(this._params[i]);
      }
      if (!found) out.push([k, v]);
      this._params = out;
    };
    g.URLSearchParams.prototype.get = function (name) {
      var k = String(name);
      for (var i = 0; i < this._params.length; i++) if (this._params[i][0] === k) return this._params[i][1];
      return null;
    };
    g.URLSearchParams.prototype.getAll = function (name) {
      var k = String(name), out = [];
      for (var i = 0; i < this._params.length; i++) if (this._params[i][0] === k) out.push(this._params[i][1]);
      return out;
    };
    g.URLSearchParams.prototype.has = function (name) {
      var k = String(name);
      for (var i = 0; i < this._params.length; i++) if (this._params[i][0] === k) return true;
      return false;
    };
    g.URLSearchParams.prototype.delete = function (name) {
      var k = String(name);
      this._params = this._params.filter(function (p) { return p[0] !== k; });
    };
    g.URLSearchParams.prototype.sort = function () {
      this._params.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
    };
    g.URLSearchParams.prototype.forEach = function (fn, thisArg) {
      for (var i = 0; i < this._params.length; i++) fn.call(thisArg, this._params[i][1], this._params[i][0], this);
    };
    g.URLSearchParams.prototype.entries = function () {
      var idx = 0, self = this;
      return { next: function () { return idx < self._params.length ? { value: self._params[idx++], done: false } : { value: undefined, done: true }; } };
    };
    g.URLSearchParams.prototype.keys = function () {
      var idx = 0, self = this;
      return { next: function () { return idx < self._params.length ? { value: self._params[idx++][0], done: false } : { value: undefined, done: true }; } };
    };
    g.URLSearchParams.prototype.values = function () {
      var idx = 0, self = this;
      return { next: function () { return idx < self._params.length ? { value: self._params[idx++][1], done: false } : { value: undefined, done: true }; } };
    };
    g.URLSearchParams.prototype.toString = function () {
      var out = '';
      for (var i = 0; i < this._params.length; i++) {
        if (i > 0) out += '&';
        out += encodeURIComponent(this._params[i][0]) + '=' + encodeURIComponent(this._params[i][1]);
      }
      return out;
    };
  }

  // -------------------------------------------------------------------------
  // URL
  // -------------------------------------------------------------------------
  if (typeof g.URL === 'undefined') {
    function parseURL(input, base) {
      // If input is an absolute URL, parse directly.
      var re = /^([a-z][a-z0-9+.-]*:)?\/\/([^\/?#]*)([^?#]*)?(\?[^#]*)?(#.*)?$/i;
      var m;
      var protocol, host, pathname, search, hash;
      if (typeof input !== 'string') input = String(input);
      var absMatch = /^([a-z][a-z0-9+.-]*:)\/\//i.exec(input) || /^[a-z][a-z0-9+.-]*:/i.exec(input);
      if (absMatch && input.charAt(absMatch[0].length) === '/' || (absMatch && /^https?:/i.test(absMatch[1]))) {
        // absolute URL
        var absolute = input;
        m = re.exec(absolute);
        if (m) {
          protocol = m[1] || '';
          host = m[2] || '';
          pathname = m[3] || '/';
          search = m[4] || '';
          hash = m[5] || '';
        } else {
          protocol = absMatch[1] || '';
          host = '';
          pathname = input.slice(protocol.length);
          search = '';
          hash = '';
        }
      } else if (base) {
        // relative URL against base
        var bp = parseURL(base, null);
        protocol = bp.protocol;
        host = bp.host;
        if (input.charAt(0) === '/') {
          pathname = input.split('#')[0].split('?')[0];
        } else {
          var basePath = bp.pathname || '/';
          var baseDir = basePath.lastIndexOf('/') >= 0 ? basePath.slice(0, basePath.lastIndexOf('/') + 1) : '/';
          var inputNoHash = input.split('#')[0];
          var inputQuery = inputNoHash.split('?');
          pathname = baseDir + inputQuery[0];
          if (inputQuery[1] != null) search = '?' + inputQuery[1];
          else search = '';
        }
        // Extract search/hash from input if present
        var ih = input.indexOf('#');
        if (ih >= 0) { hash = input.slice(ih); }
        else hash = '';
        var iq = input.indexOf('?');
        if (iq >= 0) {
          search = input.slice(iq, ih >= 0 ? ih : input.length);
        }
      } else {
        // treat as path only
        protocol = '';
        host = '';
        pathname = input;
        search = '';
        hash = '';
      }

      var hostname = host;
      var port = '';
      var colonIdx = host.lastIndexOf(':');
      if (colonIdx >= 0 && host.indexOf(']') < colonIdx) {
        // has port (ignore IPv6 brackets)
        hostname = host.slice(0, colonIdx);
        port = host.slice(colonIdx + 1);
      }
      if (hostname.charAt(0) === '[') hostname = hostname.slice(1, hostname.indexOf(']'));

      return {
        protocol: protocol,
        host: host,
        hostname: hostname,
        port: port,
        pathname: pathname || '/',
        search: search || '',
        hash: hash || '',
        origin: protocol ? protocol + '//' + host : '',
        href: (protocol ? protocol + '//' + host : '') + (pathname || '/') + (search || '') + (hash || ''),
      };
    }

    g.URL = function URL(input, base) {
      if (!(this instanceof g.URL)) return new g.URL(input, base);
      var parsed = parseURL(input, base);
      this.protocol = parsed.protocol;
      this.host = parsed.host;
      this.hostname = parsed.hostname;
      this.port = parsed.port;
      this.pathname = parsed.pathname;
      this.search = parsed.search;
      this.hash = parsed.hash;
      this.origin = parsed.origin;
      this.href = parsed.href;
      this._searchParams = new g.URLSearchParams(parsed.search);
    };
    Object.defineProperty(g.URL.prototype, 'searchParams', {
      get: function () { return this._searchParams; },
      configurable: true,
    });
    // Keep href in sync when searchParams changes (lazy via getter).
    var urlGetHref = function () {
      var qs = this._searchParams.toString();
      var s = qs ? '?' + qs : '';
      return (this.protocol ? this.protocol + '//' + this.host : '') + this.pathname + s + (this.hash || '');
    };
    Object.defineProperty(g.URL.prototype, 'href', { get: urlGetHref, set: function (v) { var p = parseURL(v, null); this.protocol = p.protocol; this.host = p.host; this.hostname = p.hostname; this.port = p.port; this.pathname = p.pathname; this.search = p.search; this.hash = p.hash; this.origin = p.origin; this._searchParams = new g.URLSearchParams(p.search); }, configurable: true });
    g.URL.createObjectURL = function (blob) {
      // Minimal stub — binary responses are delivered as ArrayBuffer, not Blob.
      return 'blob:traeflow/' + Math.random().toString(36).slice(2);
    };
    g.URL.revokeObjectURL = function () {};
  }

  // -------------------------------------------------------------------------
  // Headers (fetch uses plain objects, but provide Headers for completeness)
  // -------------------------------------------------------------------------
  if (typeof g.Headers === 'undefined') {
    g.Headers = function Headers(init) {
      this._h = {};
      if (init) {
        if (typeof init.forEach === 'function') init.forEach(function (v, k) { this.set(k, v); }, this);
        else if (typeof init === 'object') Object.keys(init).forEach(function (k) { this.set(k, init[k]); }, this);
      }
    };
    g.Headers.prototype.set = function (name, value) { this._h[String(name).toLowerCase()] = String(value); };
    g.Headers.prototype.get = function (name) { return this._h[String(name).toLowerCase()] || null; };
    g.Headers.prototype.has = function (name) { return Object.prototype.hasOwnProperty.call(this._h, String(name).toLowerCase()); };
    g.Headers.prototype.delete = function (name) { delete this._h[String(name).toLowerCase()]; };
    g.Headers.prototype.forEach = function (fn, thisArg) { var self = this; Object.keys(this._h).forEach(function (k) { fn.call(thisArg, self._h[k], k, self); }); };
  }

  // -------------------------------------------------------------------------
  // fetch → Swift __mineradioNativeFetch
  // -------------------------------------------------------------------------
  g.fetch = function fetch(url, options) {
    options = options || {};
    var requestId = newCallbackId();
    // Normalize body to string
    var bodyStr = null;
    if (options.body != null) {
      if (typeof options.body === 'string') bodyStr = options.body;
      else if (options.body instanceof g.URLSearchParams) bodyStr = options.body.toString();
      else if (options.body && typeof options.body.toString === 'function') bodyStr = String(options.body.toString());
      else bodyStr = String(options.body);
    }
    // Normalize headers to plain object
    var headersObj = {};
    if (options.headers) {
      if (options.headers instanceof g.Headers) options.headers.forEach(function (v, k) { headersObj[k] = v; });
      else if (typeof options.headers.forEach === 'function') options.headers.forEach(function (v, k) { headersObj[k] = v; });
      else if (typeof options.headers === 'object') Object.keys(options.headers).forEach(function (k) { headersObj[k] = String(options.headers[k]); });
    }
    var payload = {
      method: (options.method || 'GET').toUpperCase(),
      headers: headersObj,
      body: bodyStr,
    };
    return new Promise(function (resolve, reject) {
      g.__mineradioCallbacks.set(requestId, { resolve: resolve, reject: reject, kind: 'fetch' });
      if (typeof g.__mineradioNativeFetch !== 'function') {
        g.__mineradioCallbacks.delete(requestId);
        reject(new Error('__mineradioNativeFetch not registered'));
        return;
      }
      g.__mineradioNativeFetch(requestId, String(url), JSON.stringify(payload));
    }).then(function (result) {
      var headers = new g.Headers(result.headers || {});
      return {
        ok: result.status >= 200 && result.status < 300,
        status: result.status,
        statusText: result.statusText || '',
        headers: headers,
        url: String(url),
        _bodyText: result.bodyText != null ? result.bodyText : null,
        _bodyBase64: result.bodyBase64 != null ? result.bodyBase64 : null,
        json: function () { return Promise.resolve(JSON.parse(this._bodyText != null ? this._bodyText : '{}')); },
        text: function () { return Promise.resolve(this._bodyText != null ? this._bodyText : ''); },
        arrayBuffer: function () {
          if (this._bodyBase64) return Promise.resolve(base64ToArrayBuffer(this._bodyBase64));
          if (this._bodyText != null) return Promise.resolve(utf8StringToArrayBuffer(this._bodyText));
          return Promise.resolve(new ArrayBuffer(0));
        },
        blob: function () {
          // Minimal Blob stub; binary responses go through arrayBuffer in practice.
          var ab = this._bodyBase64 ? base64ToArrayBuffer(this._bodyBase64) : (this._bodyText != null ? utf8StringToArrayBuffer(this._bodyText) : new ArrayBuffer(0));
          return Promise.resolve({ size: ab.byteLength, type: headers.get('content-type') || '', arrayBuffer: function () { return Promise.resolve(ab); } });
        },
        clone: function () { return this; },
      };
    });
  };

  g.__mineradioResolveFetch = function (requestId, resultJson) {
    var cb = g.__mineradioCallbacks.get(requestId);
    if (!cb || cb.kind !== 'fetch') return;
    g.__mineradioCallbacks.delete(requestId);
    try {
      var result = typeof resultJson === 'string' ? JSON.parse(resultJson) : resultJson;
      cb.resolve(result);
    } catch (err) {
      cb.reject(err);
    }
  };

  g.__mineradioRejectFetch = function (requestId, errorStr) {
    var cb = g.__mineradioCallbacks.get(requestId);
    if (!cb || cb.kind !== 'fetch') return;
    g.__mineradioCallbacks.delete(requestId);
    cb.reject(new Error(errorStr));
  };

  // -------------------------------------------------------------------------
  // chrome.cookies / chrome.runtime → Swift __mineradioNativeCookies*
  // -------------------------------------------------------------------------
  g.chrome = g.chrome || {};
  g.chrome.runtime = g.chrome.runtime || { id: 'trae-flow' };
  if (!g.chrome.runtime.id) g.chrome.runtime.id = 'trae-flow';

  g.chrome.cookies = {
    getAll: function getAll(details) {
      return new Promise(function (resolve, reject) {
        var requestId = newCallbackId();
        g.__mineradioCallbacks.set(requestId, { resolve: resolve, reject: reject, kind: 'cookies' });
        if (typeof g.__mineradioNativeCookiesGetAll !== 'function') {
          g.__mineradioCallbacks.delete(requestId);
          reject(new Error('__mineradioNativeCookiesGetAll not registered'));
          return;
        }
        g.__mineradioNativeCookiesGetAll(requestId, JSON.stringify(details || {}));
      });
    },
    get: function get(details) {
      return new Promise(function (resolve, reject) {
        var requestId = newCallbackId();
        g.__mineradioCallbacks.set(requestId, { resolve: resolve, reject: reject, kind: 'cookies' });
        if (typeof g.__mineradioNativeCookiesGet !== 'function') {
          g.__mineradioCallbacks.delete(requestId);
          reject(new Error('__mineradioNativeCookiesGet not registered'));
          return;
        }
        g.__mineradioNativeCookiesGet(requestId, JSON.stringify(details || {}));
      });
    },
    set: function set(details) {
      return new Promise(function (resolve, reject) {
        var requestId = newCallbackId();
        g.__mineradioCallbacks.set(requestId, { resolve: resolve, reject: reject, kind: 'cookies' });
        if (typeof g.__mineradioNativeCookiesSet !== 'function') {
          g.__mineradioCallbacks.delete(requestId);
          reject(new Error('__mineradioNativeCookiesSet not registered'));
          return;
        }
        g.__mineradioNativeCookiesSet(requestId, JSON.stringify(details || {}));
      });
    },
  };

  g.__mineradioResolveCookies = function (requestId, resultJson) {
    var cb = g.__mineradioCallbacks.get(requestId);
    if (!cb || cb.kind !== 'cookies') return;
    g.__mineradioCallbacks.delete(requestId);
    try {
      var result = typeof resultJson === 'string' ? JSON.parse(resultJson) : resultJson;
      cb.resolve(result);
    } catch (err) {
      cb.reject(err);
    }
  };

  g.__mineradioRejectCookies = function (requestId, errorStr) {
    var cb = g.__mineradioCallbacks.get(requestId);
    if (!cb || cb.kind !== 'cookies') return;
    g.__mineradioCallbacks.delete(requestId);
    cb.reject(new Error(errorStr));
  };

  // -------------------------------------------------------------------------
  // setTimeout / clearTimeout — JSC lacks timers; bridge to Swift scheduler.
  // Some extension code may use Promise chains that resolve synchronously, but
  // crypto-es / node-forge occasionally defer. Provide a fallback that runs
  // synchronously if no native timer is registered.
  // -------------------------------------------------------------------------
  if (typeof g.setTimeout === 'undefined') {
    if (typeof g.__mineradioNativeSetTimeout === 'function') {
      var timerMap = new Map();
      var timerId = 1;
      g.setTimeout = function (fn, delay) {
        var id = timerId++;
        var args = Array.prototype.slice.call(arguments, 2);
        timerMap.set(id, { fn: fn, args: args });
        g.__mineradioNativeSetTimeout(id, delay || 0);
        return id;
      };
      g.__mineradioClearTimeout = function (id) { timerMap.delete(id); };
      g.__mineradioFireTimer = function (id) {
        var entry = timerMap.get(id);
        timerMap.delete(id);
        if (entry) { try { entry.fn.apply(null, entry.args); } catch (e) { console.error('timer error', e); } }
      };
    } else {
      // Synchronous fallback — runs immediately. Acceptable for non-deferred code.
      g.setTimeout = function (fn) {
        var args = Array.prototype.slice.call(arguments, 2);
        try { fn.apply(null, args); } catch (e) { console.error('setTimeout error', e); }
        return 0;
      };
      g.clearTimeout = function () {};
    }
  }
  if (typeof g.clearTimeout === 'undefined') g.clearTimeout = function () {};

  // -------------------------------------------------------------------------
  // Performance / Date.now — JSC has Date.now natively; ensure it exists.
  // -------------------------------------------------------------------------
  if (typeof g.performance === 'undefined') {
    g.performance = { now: function () { return Date.now(); } };
  }

  // Mark polyfills loaded so the bundle can detect the environment.
  g.__mineradioPolyfillsLoaded = true;
})();
