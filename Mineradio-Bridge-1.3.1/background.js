import { handleApiRequest, getBridgeStatus } from './api/router.js';

const injectedTabs = new Set();
const MEDIA_RULE_DEFS = [
  { suffix: 1, urlFilter: '||126.net', referer: 'https://music.163.com/' },
  { suffix: 2, urlFilter: '||163.com', referer: 'https://music.163.com/' },
  { suffix: 3, urlFilter: '||gtimg.cn', referer: 'https://y.qq.com/' },
  { suffix: 4, urlFilter: '||qq.com', referer: 'https://y.qq.com/' },
  { suffix: 5, urlFilter: '||qlogo.cn', referer: 'https://y.qq.com/' },
  { suffix: 6, urlFilter: '||stream.qqmusic.qq.com', referer: 'https://y.qq.com/' },
  { suffix: 7, urlFilter: '||isure.stream.qqmusic.qq.com', referer: 'https://y.qq.com/' },
  { suffix: 8, urlFilter: '||kugou.com', referer: 'https://www.kugou.com/' },
  { suffix: 9, urlFilter: '||kugou.net', referer: 'https://www.kugou.com/' },
];

function isPrivateLanHost(host) {
  host = String(host || '').toLowerCase();
  if (/^192\.168\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
  if (/^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)) return true;
  const m = /^172\.(\d{1,2})\.\d{1,3}\.\d{1,3}$/.exec(host);
  return !!(m && Number(m[1]) >= 16 && Number(m[1]) <= 31);
}

function isLocalBridgeHost(host) {
  host = String(host || '').toLowerCase();
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]' || host === '0.0.0.0';
}

function isBridgeDevUrl(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
    const host = u.hostname.toLowerCase();
    if (host.includes('xxhuberrr.github.io') && u.pathname.startsWith('/Mineradio')) return true;
    if (host === 'mineradio.art' || host === 'www.mineradio.art') return true;
    return isLocalBridgeHost(host) || isPrivateLanHost(host);
  } catch (_) {
    return false;
  }
}

function mediaRuleIds(tabId) {
  return MEDIA_RULE_DEFS.map((d) => tabId * 10 + d.suffix);
}

async function ensureMediaRefererRules(tabId) {
  if (!chrome.declarativeNetRequest || !chrome.declarativeNetRequest.updateSessionRules) return;
  const addRules = MEDIA_RULE_DEFS.map((d) => ({
    id: tabId * 10 + d.suffix,
    priority: 1,
    action: {
      type: 'modifyHeaders',
      requestHeaders: [{ header: 'Referer', operation: 'set', value: d.referer }],
    },
    condition: {
      urlFilter: d.urlFilter,
      resourceTypes: ['media', 'image', 'xmlhttprequest', 'other'],
      tabIds: [tabId],
    },
  }));
  try {
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: mediaRuleIds(tabId),
      addRules,
    });
  } catch (err) {
    console.warn('[Mineradio Bridge] media referer rules failed', tabId, err);
  }
}

async function clearMediaRefererRules(tabId) {
  if (!chrome.declarativeNetRequest || !chrome.declarativeNetRequest.updateSessionRules) return;
  try {
    await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: mediaRuleIds(tabId) });
  } catch (_) {}
}

async function clearBridgeGuard(tabId) {
  if (!chrome.scripting) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        delete window.__mineradioBridgeInjected;
        delete window.__mineradioBridgeExtId;
      },
    });
  } catch (_) {}
}

async function injectBridgePageHandshake(tabId, extId, version) {
  if (!chrome.scripting || !tabId) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      world: 'MAIN',
      func: (id, ver) => {
        try {
          window.__mineradioBridgeExtId = id;
          localStorage.setItem('mineradio-bridge-ext-id', id);
        } catch (_) {}
        var base = { source: 'mineradio-extension-bridge', ready: true, version: ver, extId: id };
        window.postMessage(Object.assign({ type: 'MINERADIO_BRIDGE_READY' }, base), '*');
        window.postMessage(Object.assign({ type: 'MINERADIO_BRIDGE_PONG' }, base), '*');
      },
      args: [extId || '', version || ''],
    });
  } catch (err) {
    console.warn('[Mineradio Bridge] page handshake failed', tabId, err);
  }
}

async function injectBridge(tabId, url, force) {
  if (!isBridgeDevUrl(url) || !chrome.scripting) return false;
  if (!force && injectedTabs.has(tabId)) {
    await injectBridgePageHandshake(tabId, chrome.runtime.id, getExtensionVersion());
    return true;
  }
  try {
    if (force) await clearBridgeGuard(tabId);
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ['content-bridge.js'],
      injectImmediately: true,
    });
    injectedTabs.add(tabId);
    await injectBridgePageHandshake(tabId, chrome.runtime.id, getExtensionVersion());
    await ensureMediaRefererRules(tabId);
    return true;
  } catch (err) {
    injectedTabs.delete(tabId);
    console.warn('[Mineradio Bridge] inject failed', tabId, url, err);
    return false;
  }
}

function getExtensionVersion() {
  try {
    return chrome.runtime.getManifest().version || '0.0.0';
  } catch (_) {
    return '0.0.0';
  }
}

function tabMatchesBridgePage(tab, pageUrl) {
  if (!tab || !tab.url) return false;
  if (!pageUrl) return isBridgeDevUrl(tab.url);
  try {
    return new URL(tab.url).origin === new URL(pageUrl).origin;
  } catch (_) {
    return tab.url === pageUrl;
  }
}

async function forceInjectBridgeForPage(pageUrl, force) {
  if (!chrome.tabs || !chrome.tabs.query) return false;
  const tabs = await chrome.tabs.query({});
  let injected = false;
  for (const tab of tabs) {
    if (!tab.id || !tab.url || !isBridgeDevUrl(tab.url)) continue;
    if (pageUrl && !tabMatchesBridgePage(tab, pageUrl)) continue;
    await injectBridge(tab.id, tab.url, !!force);
    injected = true;
  }
  return injected;
}

async function respondBridgeProbe(sendResponse) {
  try {
    const data = await getBridgeStatus();
    sendResponse({ ok: true, version: getExtensionVersion(), bridge: data });
  } catch (err) {
    sendResponse({ ok: false, error: (err && err.message) || String(err) });
  }
}

function scanOpenTabs(force) {
  if (!chrome.tabs || !chrome.tabs.query) return;
  if (force) injectedTabs.clear();
  chrome.tabs.query({}, (tabs) => {
    tabs.forEach((tab) => {
      if (tab.id && tab.url) injectBridge(tab.id, tab.url, force);
    });
  });
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!tab.url || !isBridgeDevUrl(tab.url)) return;
  if (changeInfo.status === 'loading') injectedTabs.delete(tabId);
  if (changeInfo.status === 'loading' || changeInfo.status === 'complete') {
    injectBridge(tabId, tab.url);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  injectedTabs.delete(tabId);
  clearMediaRefererRules(tabId);
});

chrome.runtime.onInstalled.addListener(() => { scanOpenTabs(true); });
chrome.runtime.onStartup.addListener(() => { scanOpenTabs(true); });
scanOpenTabs(true);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || !message.type) return;
  if (message.type === 'MINERADIO_ENSURE_MEDIA_RULES') {
    const tabId = sender.tab && sender.tab.id;
    if (tabId) {
      ensureMediaRefererRules(tabId).then(() => sendResponse({ ok: true })).catch((err) => sendResponse({ ok: false, error: err.message }));
    } else {
      sendResponse({ ok: false, error: 'missing tab id' });
    }
    return true;
  }
  if (message.type === 'MINERADIO_FORCE_INJECT') {
    const tabId = sender.tab && sender.tab.id;
    const pageUrl = message.pageUrl || (sender.tab && sender.tab.url) || '';
    const task = tabId
      ? injectBridge(tabId, sender.tab.url, true)
      : forceInjectBridgeForPage(pageUrl, true);
    Promise.resolve(task)
      .then(() => sendResponse({ ok: true, version: getExtensionVersion(), extId: chrome.runtime.id }))
      .catch((err) => sendResponse({ ok: false, error: (err && err.message) || String(err) }));
    return true;
  }
  if (message.type === 'MINERADIO_RESCAN_TABS') {
    scanOpenTabs(true);
    const activeId = message.tabId;
    const activeUrl = message.url || '';
    const task = activeId && activeUrl
      ? injectBridge(activeId, activeUrl, true)
      : Promise.resolve(false);
    Promise.resolve(task)
      .then(() => sendResponse({ ok: true, version: getExtensionVersion(), extId: chrome.runtime.id }))
      .catch((err) => sendResponse({ ok: false, error: (err && err.message) || String(err) }));
    return true;
  }
  if (message.type === 'MINERADIO_BRIDGE_STATUS') {
    getBridgeStatus().then((data) => sendResponse({ ok: true, data })).catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }
  if (message.type === 'MINERADIO_API') {
    handleApiRequest(message.payload || {})
      .then((data) => sendResponse({ ok: true, data }))
      .catch((err) => sendResponse({ ok: false, error: (err && err.message) || String(err) }));
    return true;
  }
  return undefined;
});

chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  if (!message || !message.type) return;
  if (message.type === 'MINERADIO_BRIDGE_PROBE') {
    forceInjectBridgeForPage(message.pageUrl || sender.url || '', !!message.force)
      .then(async () => {
        try {
          const data = await getBridgeStatus();
          sendResponse({ ok: true, version: getExtensionVersion(), extId: chrome.runtime.id, bridge: data });
        } catch (err) {
          sendResponse({ ok: false, error: (err && err.message) || String(err) });
        }
      });
    return true;
  }
  if (message.type !== 'MINERADIO_API') return;
  handleApiRequest(message.payload || {})
    .then((data) => sendResponse({ ok: true, data }))
    .catch((err) => sendResponse({ ok: false, error: (err && err.message) || String(err) }));
  return true;
});
