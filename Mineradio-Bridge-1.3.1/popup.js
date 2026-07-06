function setProviderCard(prefix, data, extra) {
  const statusEl = document.getElementById(prefix + '-status');
  const avatarEl = document.getElementById(prefix + '-avatar');
  if (!statusEl) return;
  if (!data || !data.loggedIn) {
    statusEl.className = 'meta bad';
    statusEl.textContent = '未登录 · 点击上方按钮去官网登录';
    if (avatarEl) avatarEl.hidden = true;
    return;
  }
  statusEl.className = 'meta ok';
  statusEl.textContent = '已登录 · ' + (data.nickname || '用户') + (extra || '');
  if (avatarEl && data.avatar) {
    avatarEl.src = data.avatar;
    avatarEl.hidden = false;
  } else if (avatarEl) {
    avatarEl.hidden = true;
  }
}

try {
  var manifestVer = chrome.runtime.getManifest().version;
  if (manifestVer) document.getElementById('ver').textContent = 'v' + manifestVer;
} catch (_) {}

async function refreshStatus() {
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    const active = tabs && tabs[0];
    await chrome.runtime.sendMessage({
      type: 'MINERADIO_RESCAN_TABS',
      tabId: active && active.id,
      url: active && active.url,
    });
  } catch (_) {}
  const resp = await chrome.runtime.sendMessage({ type: 'MINERADIO_BRIDGE_STATUS' });
  if (!resp || !resp.ok) {
    ['ne', 'qq', 'kg'].forEach(function(prefix){
      var el = document.getElementById(prefix + '-status');
      if (el) el.textContent = '扩展状态读取失败';
    });
    return;
  }
  const data = resp.data || {};
  if (data.version) document.getElementById('ver').textContent = 'v' + data.version;
  setProviderCard('ne', data.netease || {});
  const qqExtra = data.qq && data.qq.playbackKeyReady ? '' : ' · 播放票据未就绪';
  setProviderCard('qq', data.qq || {}, qqExtra);
  setProviderCard('kg', data.kg || {});
}

document.getElementById('refresh').addEventListener('click', refreshStatus);
refreshStatus();
