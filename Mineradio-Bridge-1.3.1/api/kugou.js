import CryptoJS from '../vendor/crypto-es.mjs';
import {
  getKGCookie,
  parseCookieString,
  parseKGCookieObject,
  setBrowserCookies,
  kgCookieUserId,
  kgCookieToken,
  kgCookieNickname,
  kgCookieAvatar,
  kgCookieDfid,
  kgCookieVipType,
  kgCookieLoginPwd,
  kgCookieVipToken,
  kgCookieHasVipSession,
  analyzeKGCookieSession,
} from './cookies.js';

const KG_UA_MOBILE = 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.149 Mobile Safari/537.36';
const KG_UA_PC = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const KG_DEMO_UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Mobile Safari/537.36 KGMusic/9.3.0';
const KG_ANDROID_UA = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';
const KG_ANDROID_APPID = 1005;
const KG_ANDROID_CLIENTVER = 20489;
const KG_WEB_CLIENTVER = 9030;
const KG_ANDROID_SIGN_SALT = 'OIlwieks28dk2k092lksi2UIkp';
const KG_CLOUDLIST_GATEWAY = 'https://gateway.kugou.com/cloudlist.service';
const KG_CLOUDLIST_ROUTER = { 'x-router': 'cloudlist.service.kugou.com' };
const KG_PRODUCT_VIP_TYPE = { tvip: 6, vip: 6, svip: 33, qvip: 6, dvip: 6, mvip: 3 };
const KG_TRACKER_SECRET = '57ae12eb6890223e355ccfcb74edf70d1005';
const KG_TRACKER_HOSTS = [
  'https://trackercdn.kugou.com',
  'https://trackercdnbj.kugou.com',
  'http://trackercdn.kugou.com',
  'http://trackercdnbj.kugou.com',
];
const KG_TRACKER_FAST_HOSTS = ['https://trackercdn.kugou.com', 'https://trackercdnbj.kugou.com'];
const KG_SESSION_CACHE_TTL_MS = 5 * 60 * 1000;
const KG_PLAY_URL_CACHE_TTL_MS = 4 * 60 * 1000;
let kgMidCache = '';
let kgSessionCache = { key: '', at: 0, session: null };
const kgPlayUrlCache = new Map();

function md5(text) {
  return CryptoJS.MD5(String(text || '')).toString();
}

function buildKGAuthHeaders(token) {
  token = String(token || '').trim();
  if (!token) return {};
  return { Authorization: `KugooToken ${token}` };
}

function buildKGRequestHeaders(cookieHeader, token) {
  return Object.assign(
    { Cookie: cookieHeader || '' },
    buildKGAuthHeaders(token || kgCookieToken(cookieHeader)),
  );
}

function mapKGUserCenterVipType(vipTypeRaw) {
  const t = Number(vipTypeRaw) || 0;
  if (t === 4) return 33;
  if (t === 7) return 3;
  if (t === 2) return 6;
  return t;
}

function kgApiBodyOk(body) {
  if (!body || typeof body !== 'object') return false;
  if (Number(body.status) === 1) return true;
  if (Number(body.error_code) === 0 && body.data) return true;
  if (Number(body.errcode) === 0 && body.data) return true;
  return !!(body.data && typeof body.data === 'object' && (body.userid || body.data.userid || body.data.vip_type != null));
}

function parseKGUserCenterVipEnd(data) {
  const raw = data.vip_endtime || data.vip_end_time || data.su_vip_end_time || data.m_end_time || '';
  if (!raw) return { endMs: 0, hasEnd: false };
  const num = Number(raw);
  if (Number.isFinite(num) && num > 0) {
    return { endMs: num > 1e11 ? num : num * 1000, hasEnd: true };
  }
  const endMs = Date.parse(String(raw).replace(/-/g, '/'));
  return { endMs: Number.isFinite(endMs) ? endMs : 0, hasEnd: Number.isFinite(endMs) };
}

function formatKGExpireTime(endMs) {
  if (!endMs || endMs <= 0) return '';
  return new Date(endMs).toISOString().slice(0, 19).replace('T', ' ');
}

function parseKGUserCenterVip(data) {
  if (!data || typeof data !== 'object') {
    return { vipType: 0, isVip: false, vipLabel: '', expireTime: '' };
  }
  let vipTypeRaw = Number(data.vip_type || data.vipType || 0) || 0;
  if (!vipTypeRaw) {
    if (Number(data.su_vip) > 0) vipTypeRaw = 4;
    else if (Number(data.m_type) > 0) vipTypeRaw = 7;
    else if (Number(data.y_type) > 0 || Number(data.music_vip) > 0) vipTypeRaw = 2;
    else if (Number(data.is_vip) === 1 || Number(data.MusicPack) === 1) vipTypeRaw = 2;
    else if (Number(data.vip_growth_value) > 0) vipTypeRaw = 2;
  }
  const vipType = mapKGUserCenterVipType(vipTypeRaw);
  const { endMs, hasEnd } = parseKGUserCenterVipEnd(data);
  const isVip = vipTypeRaw > 0 && (!hasEnd || endMs > Date.now());
  let vipLabel = '';
  if (vipTypeRaw === 4) vipLabel = '超级VIP';
  else if (vipTypeRaw === 7) vipLabel = '音乐包';
  else if (vipTypeRaw === 2) vipLabel = '豪华VIP';
  return { vipType, isVip, vipLabel, expireTime: formatKGExpireTime(endMs) };
}

function parseKGUserCenterBody(body) {
  if (!kgApiBodyOk(body)) return null;
  const data = body.data || body;
  if (!data || typeof data !== 'object') return null;
  const vip = parseKGUserCenterVip(data);
  return {
    ...vip,
    nickname: stripKGHighlightHtml(data.nickname || data.nick_name || data.username || ''),
    avatar: normalizeKGCover(data.pic || data.user_pic || data.avatar || '', 180),
    detail: data,
  };
}

function signatureKGAndroidParams(params, data) {
  const paramsString = Object.keys(params)
    .sort()
    .map((key) => `${key}=${typeof params[key] === 'object' ? JSON.stringify(params[key]) : params[key]}`)
    .join('');
  return md5(`${KG_ANDROID_SIGN_SALT}${paramsString}${data || ''}${KG_ANDROID_SIGN_SALT}`);
}

async function kgFetchAndroidSigned(baseURL, urlPath, cookieHeader, extraParams, extraHeaders) {
  extraParams = extraParams || {};
  extraHeaders = extraHeaders || {};
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader) || '-';
  const clienttime = Math.floor(Date.now() / 1000);
  const params = Object.assign({
    dfid,
    mid,
    uuid: '-',
    appid: KG_ANDROID_APPID,
    clientver: KG_ANDROID_CLIENTVER,
    clienttime,
    token,
    userid: userId,
  }, extraParams);
  params.signature = signatureKGAndroidParams(params);
  const qs = Object.keys(params)
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)
    .join('&');
  const url = `${String(baseURL || '').replace(/\/$/, '')}${urlPath.startsWith('/') ? urlPath : `/${urlPath}`}?${qs}`;
  return kgFetchJSON(url, {
    mobile: true,
    referer: 'https://www.kugou.com/',
    headers: Object.assign({
      Cookie: cookieHeader || '',
      'User-Agent': KG_ANDROID_UA,
      dfid: String(dfid),
      clienttime: String(clienttime),
      mid: String(mid),
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    }, buildKGAuthHeaders(token), extraHeaders),
  });
}

async function kgPostAndroidSigned(baseURL, urlPath, cookieHeader, bodyData, extraParams, extraHeaders) {
  extraParams = extraParams || {};
  extraHeaders = extraHeaders || {};
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader) || '-';
  const clienttime = Math.floor(Date.now() / 1000);
  const bodyJson = JSON.stringify(bodyData || {});
  const params = Object.assign({
    dfid,
    mid,
    uuid: '-',
    appid: KG_ANDROID_APPID,
    clientver: KG_ANDROID_CLIENTVER,
    clienttime,
    token,
    userid: userId,
  }, extraParams);
  params.signature = signatureKGAndroidParams(params, bodyJson);
  const qs = Object.keys(params)
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)
    .join('&');
  const url = `${String(baseURL || '').replace(/\/$/, '')}${urlPath.startsWith('/') ? urlPath : `/${urlPath}`}?${qs}`;
  return kgFetchJSON(url, {
    mobile: true,
    method: 'POST',
    referer: 'https://www.kugou.com/',
    headers: Object.assign({
      Cookie: cookieHeader || '',
      'User-Agent': KG_ANDROID_UA,
      'Content-Type': 'application/json',
      dfid: String(dfid),
      clienttime: String(clienttime),
      mid: String(mid),
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    }, buildKGAuthHeaders(token), extraHeaders),
    body: bodyJson,
  });
}

let kgFavoriteListIdCache = { key: '', listId: '', at: 0 };

function kgCloudlistOk(body) {
  if (!body || typeof body !== 'object') return false;
  const status = Number(body.status);
  const err = Number(body.error_code);
  if (status === 1) return true;
  if (err === 0 && status !== 0) return true;
  return false;
}

function extractKGCloudLists(body) {
  return (body && body.data && (body.data.info || body.data.list)) || body.info || body.list || [];
}

function pickKGFavoriteList(lists) {
  const arr = Array.isArray(lists) ? lists : [];
  return arr.find((item) => /我喜欢|默认收藏|红心|favorite/i.test(String(item.name || item.listname || item.specialname || '')))
    || arr.find((item) => Number(item.type) === 0 || Number(item.is_default) === 1)
    || arr[0]
    || null;
}

async function resolveKGSongMetaForFavorite(hash, albumId, albumAudioId, name, cookieHeader) {
  hash = String(hash || '').trim().toLowerCase();
  albumId = String(albumId || '').trim();
  albumAudioId = String(albumAudioId || '').trim();
  name = String(name || '').trim();
  if (!hash) return null;
  if (albumAudioId && name) return { hash, albumId, albumAudioId, name };
  try {
    const info = await fetchKGPlayInfo(hash, albumAudioId, cookieHeader);
    if (info && typeof info === 'object') {
      if (!name) name = String(info.songName || info.songname || info.filename || '').trim();
      if (!albumId) albumId = String(info.albumid || info.album_id || info.albumId || '').trim();
      if (!albumAudioId) albumAudioId = String(info.mixsongid || info.album_audio_id || info.audio_id || info.albumAudioId || '').trim();
    }
  } catch (_) {}
  if (!name) name = hash;
  return { hash, albumId, albumAudioId, name };
}

async function fetchKGFavoriteListId(cookieHeader, forceRefresh) {
  const cacheKey = buildKGSessionCacheKey(cookieHeader);
  if (!forceRefresh && kgFavoriteListIdCache.key === cacheKey && kgFavoriteListIdCache.listId && (Date.now() - kgFavoriteListIdCache.at) < KG_SESSION_CACHE_TTL_MS) {
    return kgFavoriteListIdCache.listId;
  }
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return '';
  let lists = [];
  for (const listType of [0, 2]) {
    const body = await kgPostAndroidSigned(
      KG_CLOUDLIST_GATEWAY,
      '/v7/get_all_list',
      cookieHeader,
      { userid: userId, token, total_ver: 979, type: listType, page: 1, pagesize: 50 },
      { plat: 1 },
      KG_CLOUDLIST_ROUTER,
    );
    lists = extractKGCloudLists(body);
    const fav = pickKGFavoriteList(lists);
    if (fav && (fav.listid || fav.list_id || fav.id)) break;
  }
  const fav = pickKGFavoriteList(lists);
  const listId = String((fav && (fav.listid || fav.list_id || fav.id)) || '2');
  kgFavoriteListIdCache = { key: cacheKey, listId, at: Date.now() };
  return listId;
}

async function fetchKGFavoriteFileId(cookieHeader, hash, albumAudioId) {
  hash = String(hash || '').trim().toLowerCase();
  if (!hash) return '';
  const listId = await fetchKGFavoriteListId(cookieHeader);
  if (!listId) return '';
  const body = await kgPostAndroidSigned(
    KG_CLOUDLIST_GATEWAY,
    '/v2/get_list_all_file',
    cookieHeader,
    { listid: Number(listId) || listId, page: 1, pagesize: 300, type: 0 },
    {},
    KG_CLOUDLIST_ROUTER,
  );
  const tracks = extractKGCloudLists(body);
  const hit = (Array.isArray(tracks) ? tracks : []).find((item) => {
    const itemHash = String(item.hash || item.FileHash || item.HASH || '').trim().toLowerCase();
    const mixId = String(item.mixsongid || item.album_audio_id || item.AlbumAudioID || item.MixSongID || '');
    if (itemHash && itemHash === hash) return true;
    return albumAudioId && mixId && mixId === String(albumAudioId);
  });
  return String((hit && (hit.fileid || hit.file_id || hit.id)) || '');
}

export async function handleKGSongLikeCheck(ids, cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const liked = {};
  const login = await getKGPlayContext(cookieHeader);
  if (!login.loggedIn) return { provider: 'kg', error: 'LOGIN_REQUIRED', loggedIn: false, liked, ids };
  const listId = await fetchKGFavoriteListId(cookieHeader);
  if (!listId) {
    (ids || []).forEach((id) => { liked[id] = false; });
    return { provider: 'kg', loggedIn: true, ids, liked };
  }
  const body = await kgPostAndroidSigned(
    KG_CLOUDLIST_GATEWAY,
    '/v2/get_list_all_file',
    cookieHeader,
    { listid: Number(listId) || listId, page: 1, pagesize: 500, type: 0 },
    {},
    KG_CLOUDLIST_ROUTER,
  );
  const tracks = extractKGCloudLists(body);
  const hashSet = new Set((Array.isArray(tracks) ? tracks : []).map((item) => String(item.hash || item.FileHash || item.HASH || '').trim().toLowerCase()).filter(Boolean));
  const mixSet = new Set((Array.isArray(tracks) ? tracks : []).map((item) => String(item.mixsongid || item.album_audio_id || item.MixSongID || '')).filter(Boolean));
  (ids || []).forEach((id) => {
    const raw = String(id || '').trim();
    const lower = raw.toLowerCase();
    liked[id] = hashSet.has(lower) || mixSet.has(raw);
  });
  return { provider: 'kg', loggedIn: true, ids, liked };
}

export async function handleKGSongLike(hash, albumId, albumAudioId, name, like, cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const login = await getKGPlayContext(cookieHeader);
  if (!login.loggedIn) return { provider: 'kg', error: 'LOGIN_REQUIRED', loggedIn: false };
  const meta = await resolveKGSongMetaForFavorite(hash, albumId, albumAudioId, name, cookieHeader);
  if (!meta || !meta.hash) return { provider: 'kg', error: 'MISSING_HASH', loggedIn: true };
  hash = meta.hash;
  albumId = meta.albumId;
  albumAudioId = meta.albumAudioId;
  name = meta.name;
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  let listId = await fetchKGFavoriteListId(cookieHeader);
  if (!listId) return { provider: 'kg', error: 'FAVORITE_LIST_UNAVAILABLE', loggedIn: true, hash };
  if (like === false) {
    const fileId = await fetchKGFavoriteFileId(cookieHeader, hash, albumAudioId);
    if (!fileId) return { provider: 'kg', error: 'FAVORITE_ITEM_NOT_FOUND', loggedIn: true, hash, liked: true };
    const body = await kgPostAndroidSigned(
      KG_CLOUDLIST_GATEWAY,
      '/v4/delete_songs',
      cookieHeader,
      { listid: Number(listId) || listId, userid: userId, token, data: [{ fileid: Number(fileId) || fileId }], type: 0, list_ver: 0 },
      {},
      KG_CLOUDLIST_ROUTER,
    );
    if (!kgCloudlistOk(body)) return { provider: 'kg', error: 'KG_UNLIKE_FAILED', loggedIn: true, hash, liked: true, body };
    return { provider: 'kg', loggedIn: true, hash, liked: false };
  }
  const resource = [{
    number: 1,
    name,
    hash,
    size: 0,
    sort: 0,
    timelen: 0,
    bitrate: 0,
    album_id: Number(albumId) || 0,
    mixsongid: Number(albumAudioId) || 0,
  }];
  let body = await kgPostAndroidSigned(
    KG_CLOUDLIST_GATEWAY,
    '/v6/add_song',
    cookieHeader,
    {
      userid: userId,
      token,
      listid: Number(listId) || listId,
      list_ver: 0,
      type: 0,
      slow_upload: 1,
      scene: 'false;null',
      data: resource,
    },
    { last_time: Math.floor(Date.now() / 1000), last_area: 'gztx' },
    KG_CLOUDLIST_ROUTER,
  );
  if (!kgCloudlistOk(body)) {
    kgFavoriteListIdCache = { key: '', listId: '', at: 0 };
    listId = await fetchKGFavoriteListId(cookieHeader, true);
    if (listId) {
      body = await kgPostAndroidSigned(
        KG_CLOUDLIST_GATEWAY,
        '/v6/add_song',
        cookieHeader,
        {
          userid: userId,
          token,
          listid: Number(listId) || listId,
          list_ver: 0,
          type: 0,
          slow_upload: 1,
          scene: 'false;null',
          data: resource,
        },
        { last_time: Math.floor(Date.now() / 1000), last_area: 'gztx' },
        KG_CLOUDLIST_ROUTER,
      );
    }
  }
  if (!kgCloudlistOk(body)) return { provider: 'kg', error: 'KG_LIKE_FAILED', loggedIn: true, hash, liked: false, body };
  return { provider: 'kg', loggedIn: true, hash, liked: true };
}

function decodeCookieValue(value) {
  try {
    return decodeURIComponent(String(value || '').replace(/\+/g, '%20')).trim();
  } catch (_) {
    return String(value || '').trim();
  }
}

function normalizeKGCover(url, size) {
  url = String(url || '').trim();
  if (!url) return '';
  return url.replace(/\{size\}/gi, String(size || 240));
}

function normalizeKGDuration(value, fromSearch) {
  const n = Number(value) || 0;
  if (!n) return 0;
  if (fromSearch || n < 10000) return Math.round(n * 1000);
  return Math.round(n);
}

function stripKGHighlightHtml(value) {
  return String(value || '')
    .replace(/<\/?em>/gi, '')
    .replace(/<[^>]+>/g, '')
    .trim();
}

function extractKGFee(item) {
  item = item || {};
  const payType = Number(item.PayType ?? item.pay_type ?? 0);
  const privilege = Number(item.Privilege ?? item.privilege ?? 0);
  if (payType === 1 || payType === 2 || payType === 4) return 1;
  if ((privilege & 2) === 2) return 1;
  return 0;
}

function extractKGCover(item, size) {
  item = item || {};
  const trans = item.trans_param || item.TransParam || {};
  return normalizeKGCover(
    item.Image || item.img || item.album_img || item.album_sizable_cover || item.albumimg ||
    trans.union_cover || trans.unionCover || trans.album_img || trans.imgurl || '',
    size || 240,
  );
}

function mapKGSong(item, fromSearch) {
  item = item || {};
  const hash128 = String(item['128hash'] || item.FileHash || item.hash || item.HASH || '').trim().toLowerCase();
  const hash320 = String(item['320hash'] || item.HQFileHash || item.h320hash || '').trim().toLowerCase();
  const hashSq = String(item.sqhash || item.SQFileHash || '').trim().toLowerCase();
  const hash = hash128 || hash320 || hashSq;
  const albumId = String(item.AlbumID || item.album_id || item.albumid || item.AlbumId || item.album_id || '').trim();
  const albumAudioId = String(item.MixSongID || item.ID || item.AlbumAudioID || item.album_audio_id || '').trim();
  const fee = extractKGFee(item);
  let rawName = stripKGHighlightHtml(item.SongName || item.songname || item.name || '');
  let name = rawName;
  let artist = stripKGHighlightHtml(item.SingerName || item.singername || item.author_name || item.singer || '');
  const filename = stripKGHighlightHtml(item.filename || item.FileName || '');
  if (!name && filename) {
    if (filename.includes(' - ')) {
      const parts = filename.split(' - ');
      if (!artist) artist = parts[0].trim();
      name = parts.slice(1).join(' - ').trim() || filename;
    } else {
      name = filename;
    }
  }
  if (!artist && rawName.includes(' - ')) {
    const parts = rawName.split(' - ');
    artist = parts[0].trim();
    name = parts.slice(1).join(' - ').trim() || rawName;
  }
  const singerId = String(item.SingerId || item.singerid || item.singer_id || item.SingerID || '').trim();
  return {
    provider: 'kg',
    source: 'kg',
    type: 'kg',
    id: hash,
    hash,
    hash128,
    hash320,
    hashSq,
    albumId,
    albumAudioId,
    singerId,
    artistId: singerId,
    name,
    artist,
    album: stripKGHighlightHtml(item.AlbumName || item.album_name || item.album || item.album_name || ''),
    cover: extractKGCover(item, 240),
    duration: normalizeKGDuration(item.Duration || item.duration || item.timelength, fromSearch),
    fee,
    privilege: Number(item.Privilege ?? item.privilege ?? 0) || 0,
    payType: Number(item.PayType ?? item.pay_type ?? 0) || 0,
    playable: fee === 0,
  };
}

function mapKGPlaylist(item) {
  item = item || {};
  return {
    provider: 'kg',
    source: 'kg',
    type: 'playlist',
    id: String(item.specialid || item.special_id || item.id || ''),
    name: stripKGHighlightHtml(item.specialname || item.special_name || item.name || ''),
    cover: normalizeKGCover(item.imgurl || item.img || item.pic || '', 240),
    trackCount: Number(item.songcount || item.song_count || item.count || 0) || 0,
    creator: item.nickname || item.username || '酷狗音乐',
  };
}

async function kgFetchText(url, opts) {
  opts = opts || {};
  const resp = await fetch(url, {
    method: opts.method || 'GET',
    headers: Object.assign({
      'User-Agent': opts.mobile ? KG_UA_MOBILE : KG_UA_PC,
      Referer: opts.referer || 'https://www.kugou.com/',
      Accept: 'application/json, text/plain, */*',
    }, opts.headers || {}),
    body: opts.body,
  });
  return resp.text();
}

async function kgFetchJSON(url, opts) {
  const text = await kgFetchText(url, opts);
  const cleaned = String(text || '').replace(/<!--[\s\S]*?-->/g, '').trim();
  try {
    return JSON.parse(cleaned || text);
  } catch (_) {
    return null;
  }
}

function buildKGMid() {
  let out = '';
  for (let i = 0; i < 38; i++) out += Math.floor(Math.random() * 10);
  return out;
}

async function getKGMid(cookieHeader) {
  const obj = parseCookieString(cookieHeader || '');
  const fromCookie = String(obj.mid || obj.kg_mid || obj.KG_M_ID || '').replace(/\D/g, '');
  if (fromCookie.length >= 20) return fromCookie.slice(0, 38);
  if (kgMidCache) return kgMidCache;
  try {
    const stored = await chrome.storage.local.get(['kgMid']);
    if (stored && stored.kgMid) {
      kgMidCache = String(stored.kgMid);
      return kgMidCache;
    }
  } catch (_) {}
  kgMidCache = buildKGMid();
  try { await chrome.storage.local.set({ kgMid: kgMidCache }); } catch (_) {}
  return kgMidCache;
}

function buildKGTrackerKey(hash, mid, userId) {
  hash = String(hash || '').trim().toLowerCase();
  userId = String(userId || '0').replace(/\D/g, '') || '0';
  return md5(hash + KG_TRACKER_SECRET + mid + userId);
}

function parseKGPlayUrl(body) {
  if (!body) return '';
  const candidates = [
    body.url,
    body.backupUrl,
    body.backup_url,
    body.data && body.data.url,
    body.data && body.data.backupUrl,
    body.data && body.data.backup_url,
  ];
  for (const urls of candidates) {
    if (Array.isArray(urls)) {
      const hit = urls.find((item) => item && /^https?:\/\//i.test(item));
      if (hit) return hit;
    }
    if (typeof urls === 'string' && /^https?:\/\//i.test(urls)) return urls;
  }
  return '';
}

function pickPlayInfoUrl(playInfo) {
  if (!playInfo || playInfo.error) return '';
  if (playInfo.url && /^https?:\/\//i.test(playInfo.url)) return playInfo.url;
  const backup = playInfo.backup_url;
  if (Array.isArray(backup) && backup[0]) return backup[0];
  if (typeof backup === 'string' && backup) return backup;
  return '';
}

function isExpiredKGVipTime(value) {
  const ts = Date.parse(String(value || '').replace(/-/g, '/'));
  return Number.isFinite(ts) ? ts < Date.now() : false;
}

function parseKGVipFromData(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return { vipType: 0, isVip: false };
  const nestedRaw = data.vip || data.user_vip || data.userVip || data.music_vip || {};
  const nested = (nestedRaw && typeof nestedRaw === 'object' && !Array.isArray(nestedRaw)) ? nestedRaw : {};
  const vipEnd = data.vip_end_time || data.vipEndTime || nested.vip_end_time || data.expire_time || data.expireTime;
  let vipType = Number(
    data.vip_type || data.vipType || data.VIPType || data.VipType ||
    nested.vip_type || nested.vipType || nested.type || 0,
  ) || 0;
  const productType = String(data.product_type || nested.product_type || data.busi_type || nested.busi_type || '').toLowerCase();
  const isVipFlag = Number(data.is_vip ?? data.isVip ?? nested.is_vip ?? nested.isVip ?? data.isVipUser ?? -1);
  let isVip = !!(
    (vipType > 0 && (!vipEnd || !isExpiredKGVipTime(vipEnd))) ||
    isVipFlag === 1 ||
    Number(data.vip) === 1 ||
    Number(nested.vip) === 1 ||
    Number(data.MusicPack) === 1 ||
    Number(data.musicpack) === 1 ||
    Number(data.y_type) > 0 ||
    Number(data.music_vip) > 0 ||
    (productType && !/^(free|none|0|normal)$/.test(productType) && Number(data.is_vip) === 1) ||
    (vipEnd && !isExpiredKGVipTime(vipEnd)) ||
    (data.svip_end_time && !isExpiredKGVipTime(data.svip_end_time)) ||
    (data.musicvip_end_time && !isExpiredKGVipTime(data.musicvip_end_time)) ||
    (nested.vip_end_time && !isExpiredKGVipTime(nested.vip_end_time))
  );
  if (Number(data.is_vip) === 1 && data.vip_end_time && !isExpiredKGVipTime(data.vip_end_time)) {
    isVip = true;
    vipType = Math.max(vipType, KG_PRODUCT_VIP_TYPE[productType] || 6);
  }
  if (Number(data.m_type) > 0 && data.m_end_time && !isExpiredKGVipTime(data.m_end_time)) {
    isVip = true;
    vipType = Math.max(vipType, Number(data.m_type) || 6);
  }
  if (Number(data.su_vip) > 0 || (data.su_vip_end_time && !isExpiredKGVipTime(data.su_vip_end_time))) {
    isVip = true;
    vipType = Math.max(vipType, 33);
  }
  return { vipType: vipType || (isVip ? 6 : 0), isVip };
}

function pushKGVipQueueItem(queue, value) {
  if (!value) return;
  if (Array.isArray(value)) queue.push(...value);
  else queue.push(value);
}

function extractKGVipFromPayload(payload) {
  let best = parseKGVipFromData(payload);
  const queue = [];
  pushKGVipQueueItem(queue, payload);
  if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
    ['busi_vip', 'busiVip', 'vip_info', 'vipInfo', 'music_vip', 'svip', 'data', 'info', 'user_vip'].forEach((key) => {
      pushKGVipQueueItem(queue, payload[key]);
    });
    if (Array.isArray(payload.list)) queue.push(...payload.list);
    if (Array.isArray(payload.vip_list)) queue.push(...payload.vip_list);
  }
  queue.forEach((item) => {
    const hit = parseKGVipFromData(item);
    if (hit.isVip && (!best.isVip || hit.vipType >= best.vipType)) best = hit;
  });
  return best;
}

function resolveKGVipMeta(data) {
  if (!data || typeof data !== 'object') return { vipLabel: '', expireTime: '' };
  if (Number(data.m_type) > 0 && data.m_end_time && !isExpiredKGVipTime(data.m_end_time)) {
    return { vipLabel: '豪华VIP', expireTime: String(data.m_end_time) };
  }
  if (Number(data.su_vip) > 0 || (data.su_vip_end_time && !isExpiredKGVipTime(data.su_vip_end_time))) {
    return { vipLabel: '超级VIP', expireTime: String(data.su_vip_end_time || data.vip_end_time || '') };
  }
  const items = Array.isArray(data.busi_vip) ? data.busi_vip : (Array.isArray(data.busiVip) ? data.busiVip : []);
  let bestItem = null;
  items.forEach((item) => {
    if (!item || Number(item.is_vip) !== 1) return;
    if (item.vip_end_time && isExpiredKGVipTime(item.vip_end_time)) return;
    if (!bestItem || String(item.vip_end_time || '') > String(bestItem.vip_end_time || '')) bestItem = item;
  });
  if (bestItem) {
    const pt = String(bestItem.product_type || '').toLowerCase();
    const label = pt === 'svip' ? '超级VIP' : (pt === 'mvip' ? '音乐包' : '豪华VIP');
    return { vipLabel: label, expireTime: String(bestItem.vip_end_time || '') };
  }
  if (Number(data.vip_type) > 0 && data.vip_end_time && !isExpiredKGVipTime(data.vip_end_time)) {
    return { vipLabel: '豪华VIP', expireTime: String(data.vip_end_time) };
  }
  return { vipLabel: '', expireTime: '' };
}

async function fetchKGUserVipDetail(cookieHeader) {
  const busiTypes = ['music', 'concept', ''];
  const results = await Promise.all(busiTypes.map(async (busiType) => {
    try {
      const extra = busiType ? { busi_type: busiType } : {};
      const body = await kgFetchAndroidSigned('https://kugouvip.kugou.com', '/v1/get_union_vip', cookieHeader, extra);
      if (!body || Number(body.status) !== 1) return null;
      const data = body.data || body;
      const vip = extractKGVipFromPayload(data);
      const meta = resolveKGVipMeta(data);
      const isVip = !!(vip.isVip || meta.vipLabel);
      return {
        vipType: vip.vipType || (isVip ? 6 : 0),
        isVip,
        vipLabel: meta.vipLabel,
        expireTime: meta.expireTime,
        detail: data,
      };
    } catch (_) {
      return null;
    }
  }));
  let best = { vipType: 0, isVip: false, vipLabel: '', expireTime: '', detail: null };
  results.filter(Boolean).forEach((hit) => {
    const merged = mergeKGVipState(best, hit);
    best = {
      vipType: merged.vipType,
      isVip: merged.isVip,
      vipLabel: hit.vipLabel || best.vipLabel,
      expireTime: hit.expireTime || best.expireTime,
      detail: hit.detail || best.detail,
    };
  });
  return best.isVip || best.detail ? best : null;
}

export async function getKGUserVipDetail(cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) {
    return { provider: 'kg', loggedIn: false, error: 'NOT_LOGGED_IN', message: '未登录，无法查询 VIP 详情' };
  }
  const userCenter = await fetchKGUserCenterVip(cookieHeader);
  const detail = await fetchKGUserVipDetail(cookieHeader);
  const merged = mergeKGVipState(userCenter || {}, detail || {});
  if (!merged.isVip && !detail && !userCenter) {
    return { provider: 'kg', loggedIn: true, userId, isVip: false, vipType: 0, error: 'VIP_DETAIL_EMPTY' };
  }
  return {
    provider: 'kg',
    loggedIn: true,
    userId,
    isVip: merged.isVip,
    vipType: merged.vipType,
    vipLabel: (userCenter && userCenter.vipLabel) || (detail && detail.vipLabel) || (merged.isVip ? 'VIP' : '无VIP'),
    expireTime: (userCenter && userCenter.expireTime) || (detail && detail.expireTime) || '',
    detail: (userCenter && userCenter.detail) || (detail && detail.detail) || null,
  };
}

function mergeKGVipState(base, extra) {
  base = base || { vipType: 0, isVip: false };
  extra = extra || { vipType: 0, isVip: false };
  const vipType = Math.max(Number(base.vipType) || 0, Number(extra.vipType) || 0);
  const isVip = !!(base.isVip || extra.isVip || vipType > 0);
  return { vipType: vipType || (isVip ? 6 : 0), isVip };
}

function resolveKGTrackerVipType(cookieHeader, loginVipType) {
  const fromCookie = kgCookieVipType(cookieHeader);
  if (fromCookie > 0) return String(fromCookie);
  if (Number(loginVipType) > 0) return String(loginVipType);
  if (kgCookieHasVipSession(cookieHeader)) return '6';
  if (kgCookieToken(cookieHeader)) return '6';
  return '0';
}

function buildKGTrackerVipTypeCandidates(cookieHeader, loginVipType) {
  return [...new Set([
    resolveKGTrackerVipType(cookieHeader, loginVipType),
    String(kgCookieVipType(cookieHeader) || ''),
    kgCookieHasVipSession(cookieHeader) ? '6' : '',
    kgCookieToken(cookieHeader) ? '6' : '',
    '6', '11', '33', '3',
  ].filter(Boolean))];
}

function buildKGSessionCacheKey(cookieHeader) {
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  return `${userId}|${token ? token.slice(0, 12) : ''}|${kgCookieVipType(cookieHeader)}`;
}

const KG_QUALITY_OPTIONS = [
  { level: 'lossless', label: '无损 SQ', br: 999000 },
  { level: 'exhigh', label: '极高 HQ', br: 320000 },
  { level: 'standard', label: '标准', br: 128000 },
];

function normalizeQualityPreference(value) {
  const raw = String(value || '').toLowerCase().trim();
  if (['jymaster', 'master', 'studio', 'svip', 'highest'].includes(raw)) return 'jymaster';
  if (['hires', 'hi-res', 'highres', 'zhenyin', 'spatial'].includes(raw)) return 'hires';
  if (['lossless', 'flac', 'sq'].includes(raw)) return 'lossless';
  if (['exhigh', 'high', '320', '320k', 'hq'].includes(raw)) return 'exhigh';
  if (['standard', 'normal', '128', '128k', 'std'].includes(raw)) return 'standard';
  return 'hires';
}

function qualityCandidatesFrom(target, candidates) {
  target = normalizeQualityPreference(target);
  let start = candidates.findIndex((item) => item.level === target);
  if (start < 0) start = 0;
  return candidates.slice(start);
}

function extractKGQualityMap(extra, baseHash) {
  extra = extra || {};
  return {
    lossless: String(extra.sqhash || extra.SQFileHash || '').trim().toLowerCase(),
    exhigh: String(extra['320hash'] || extra.HQFileHash || '').trim().toLowerCase(),
    standard: String(extra['128hash'] || extra.FileHash || baseHash || '').trim().toLowerCase(),
  };
}

function pickKGHashForQuality(extra, baseHash, qualityPreference) {
  const map = extractKGQualityMap(extra, baseHash);
  const order = qualityCandidatesFrom(normalizeQualityPreference(qualityPreference), KG_QUALITY_OPTIONS);
  for (const item of order) {
    const hash = map[item.level];
    if (hash) return { hash, level: item.level, label: item.label, br: item.br };
  }
  const fallback = map.standard || String(baseHash || '').trim().toLowerCase();
  return { hash: fallback, level: 'standard', label: '标准', br: 128000 };
}

function buildKGPlayUrlCacheKey(hash, albumId, albumAudioId, qualityLevel) {
  return `${hash}|${albumId || '0'}|${albumAudioId || ''}|${qualityLevel || ''}`;
}

function readKGPlayUrlCache(key) {
  const hit = kgPlayUrlCache.get(key);
  if (!hit) return '';
  if (Date.now() - hit.at > KG_PLAY_URL_CACHE_TTL_MS) {
    kgPlayUrlCache.delete(key);
    return '';
  }
  return hit.url;
}

function writeKGPlayUrlCache(key, url) {
  if (!url) return;
  kgPlayUrlCache.set(key, { url, at: Date.now() });
  if (kgPlayUrlCache.size > 80) {
    const oldest = kgPlayUrlCache.keys().next().value;
    if (oldest) kgPlayUrlCache.delete(oldest);
  }
}

function rememberKGPlaySession(cookieHeader, session) {
  kgSessionCache = {
    key: buildKGSessionCacheKey(cookieHeader),
    at: Date.now(),
    session,
  };
}

async function getKGPlayContext(cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const cacheKey = buildKGSessionCacheKey(cookieHeader);
  const now = Date.now();
  const cached = kgSessionCache.key === cacheKey && kgSessionCache.session && (now - kgSessionCache.at) < KG_SESSION_CACHE_TTL_MS
    ? kgSessionCache.session
    : null;
  if (cached && (!cached.loggedIn || cached.vipResolved)) return cached;
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  const loggedIn = !!(userId && token);
  let vipType = kgCookieVipType(cookieHeader);
  let isVip = kgCookieHasVipSession(cookieHeader);
  let vipLabel = isVip ? 'VIP' : '无VIP';
  const session = { loggedIn, userId, vipType, isVip, vipLabel, vipResolved: false };
  if (loggedIn) {
    const vipInfo = await resolveKGSessionVip(cookieHeader, {
      vipType,
      isVip,
      vipLabel,
      nickname: kgCookieNickname(cookieHeader),
      avatar: kgCookieAvatar(cookieHeader),
    });
    Object.assign(session, vipInfo);
  } else {
    session.vipResolved = true;
  }
  rememberKGPlaySession(cookieHeader, session);
  return session;
}

function buildKGTrackerFastVipTypes(cookieHeader, loginVipType) {
  const primary = resolveKGTrackerVipType(cookieHeader, loginVipType);
  return [...new Set([primary, '6', '33', '0'].filter(Boolean))].slice(0, 3);
}

async function raceKGPlayTasks(taskFns, pickHit) {
  if (!taskFns.length) return null;
  return new Promise((resolve) => {
    let pending = taskFns.length;
    let settled = false;
    taskFns.forEach((fn) => {
      Promise.resolve()
        .then(fn)
        .then((result) => {
          if (settled) return;
          const hit = pickHit(result);
          if (hit) {
            settled = true;
            resolve(hit);
            return;
          }
          pending -= 1;
          if (pending <= 0) resolve(null);
        })
        .catch(() => {
          pending -= 1;
          if (!settled && pending <= 0) resolve(null);
        });
    });
  });
}

async function fetchKGUserCenterVip(cookieHeader) {
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader) || '-';
  const clienttime = String(Date.now());
  const commonParams = {
    userid: userId,
    token,
    appid: String(KG_ANDROID_APPID),
    clientver: String(KG_WEB_CLIENTVER),
    mid,
    dfid,
    uuid: '-',
    clienttime,
  };
  const attempts = [
    {
      base: 'https://apis.user.kugou.com/usercenter/v2/user/info',
      params: commonParams,
      headers: Object.assign({
        'User-Agent': KG_DEMO_UA,
        Accept: 'application/json, text/plain, */*',
      }, buildKGRequestHeaders(cookieHeader, token)),
    },
    {
      base: 'https://apis.user.kugou.com/usercenter/v2/user/info',
      params: { userid: userId },
      headers: Object.assign({
        'User-Agent': KG_DEMO_UA,
        Accept: 'application/json, text/plain, */*',
      }, buildKGRequestHeaders(cookieHeader, token)),
    },
    {
      base: 'https://gateway.kugou.com/usercenter.service/v2/user/info',
      params: commonParams,
      headers: Object.assign({
        'User-Agent': KG_DEMO_UA,
        mid: String(mid),
        dfid: String(dfid),
        clienttime,
        'kg-rc': '1',
        'kg-rec': '1',
      }, buildKGRequestHeaders(cookieHeader, token)),
    },
  ];
  for (const attempt of attempts) {
    const u = new URL(attempt.base);
    Object.entries(attempt.params).forEach(([key, value]) => {
      if (value != null && value !== '') u.searchParams.set(key, String(value));
    });
    try {
      const body = await kgFetchJSON(u.toString(), {
        referer: 'https://www.kugou.com/',
        headers: attempt.headers,
      });
      const parsed = parseKGUserCenterBody(body);
      if (parsed) return parsed;
    } catch (_) {}
  }
  try {
    const body = await kgFetchAndroidSigned(
      'https://gateway.kugou.com/usercenter.service',
      '/v2/user/info',
      cookieHeader,
      { clientver: String(KG_WEB_CLIENTVER) },
      { 'x-router': 'usercenter.service.kugou.com' },
    );
    const parsed = parseKGUserCenterBody(body);
    if (parsed) return parsed;
  } catch (_) {}
  return null;
}

async function resolveKGSessionVip(cookieHeader, seed) {
  seed = seed || {};
  let vipType = Number(seed.vipType) || kgCookieVipType(cookieHeader);
  let isVip = !!(seed.isVip || kgCookieHasVipSession(cookieHeader));
  let vipLabel = seed.vipLabel || (isVip ? 'VIP' : '无VIP');
  let expireTime = seed.expireTime || '';
  let nickname = seed.nickname || '';
  let avatar = seed.avatar || '';
  const [userCenter, vipDetail, profile, union, mobileVip] = await Promise.all([
    fetchKGUserCenterVip(cookieHeader),
    fetchKGUserVipDetail(cookieHeader),
    fetchKGUserProfile(cookieHeader),
    fetchKGUnionVip(cookieHeader),
    fetchKGMobileVipInfo(cookieHeader),
  ]);
  if (userCenter) {
    ({ vipType, isVip } = mergeKGVipState({ vipType, isVip }, userCenter));
    if (userCenter.vipLabel) vipLabel = userCenter.vipLabel;
    if (userCenter.expireTime) expireTime = userCenter.expireTime;
    if (userCenter.nickname) nickname = userCenter.nickname;
    if (userCenter.avatar) avatar = userCenter.avatar;
  }
  if (vipDetail) {
    ({ vipType, isVip } = mergeKGVipState({ vipType, isVip }, vipDetail));
    if (vipDetail.vipLabel) vipLabel = vipDetail.vipLabel;
    if (vipDetail.expireTime) expireTime = vipDetail.expireTime;
  }
  if (profile) {
    if (profile.nickname) nickname = profile.nickname;
    if (profile.avatar) avatar = profile.avatar;
    ({ vipType, isVip } = mergeKGVipState({ vipType, isVip }, profile));
  }
  if (union) ({ vipType, isVip } = mergeKGVipState({ vipType, isVip }, union));
  if (mobileVip) ({ vipType, isVip } = mergeKGVipState({ vipType, isVip }, mobileVip));
  if (!isVip && kgCookieHasVipSession(cookieHeader)) {
    vipType = vipType || 6;
    isVip = true;
    vipLabel = vipLabel === '无VIP' ? 'VIP' : vipLabel;
  }
  if (isVip && vipLabel === '无VIP') vipLabel = 'VIP';
  return { vipType, isVip, vipLabel, expireTime, nickname, avatar, vipResolved: true };
}

async function fetchKGUserProfile(cookieHeader) {
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader);
  const buildUrl = (secure) => {
    const u = new URL(`${secure ? 'https' : 'http'}://userinfo.user.kugou.com/v2/get_user_info`);
    u.searchParams.set('appid', '1005');
    u.searchParams.set('clientver', String(KG_WEB_CLIENTVER));
    u.searchParams.set('mid', mid);
    u.searchParams.set('userid', userId);
    u.searchParams.set('token', token);
    u.searchParams.set('dfid', dfid);
    u.searchParams.set('plat', '0');
    u.searchParams.set('clienttime', String(Date.now()));
    return u.toString();
  };
  const headers = Object.assign({
    'User-Agent': KG_DEMO_UA,
    Accept: 'application/json, text/plain, */*',
  }, buildKGRequestHeaders(cookieHeader, token));
  for (const url of [buildUrl(true), buildUrl(false)]) {
    try {
      const body = await kgFetchJSON(url, {
        referer: 'https://www.kugou.com/',
        headers,
      });
      if (!kgApiBodyOk(body)) continue;
      const data = body.data || body.info;
      if (!data || typeof data !== 'object') continue;
      const vip = extractKGVipFromPayload(data);
      return {
        nickname: stripKGHighlightHtml(data.nickname || data.nick_name || data.username || data.user_name || ''),
        avatar: normalizeKGCover(data.pic || data.Pic || data.user_pic || data.avatar || data.userpic || '', 180),
        vipType: vip.vipType,
        isVip: vip.isVip,
      };
    } catch (_) {}
  }
  return null;
}

async function fetchKGUnionVip(cookieHeader) {
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  const loginPwd = kgCookieLoginPwd(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader);
  const common = `appid=1005&clientver=9108&mid=${encodeURIComponent(mid)}&userid=${encodeURIComponent(userId)}&token=${encodeURIComponent(token)}&dfid=${encodeURIComponent(dfid)}`;
  const pwdPart = loginPwd ? `&pwd=${encodeURIComponent(loginPwd)}&KugooPwd=${encodeURIComponent(loginPwd)}` : '';
  const urls = [
    `https://mobileservice.kugou.com/api/v5/vip_info?${common}${pwdPart}&format=json`,
    `https://mobileservice.kugou.com/api/v5/vip_status?${common}${pwdPart}`,
    `http://mobileservice.kugou.com/api/v5/vip_info?${common}${pwdPart}&format=json`,
    `http://mobileservice.kugou.com/api/v5/vip_status?${common}${pwdPart}`,
    `https://kugouvip.kugou.com/v1/get_union_vip?busi_type=concept&${common}`,
    `https://kugouvip.kugou.com/v1/get_union_vip?busi_type=music&${common}`,
    `https://kugouvip.kugou.com/v1/get_union_vip?${common}`,
    `https://vip.kugou.com/recharge/getUserVip?kugouid=${encodeURIComponent(userId)}&clienttoken=${encodeURIComponent(token)}&appid=1005${loginPwd ? `&KugooPwd=${encodeURIComponent(loginPwd)}` : ''}`,
    `https://mobilecdn.kugou.com/api/v3/user/vip?userid=${encodeURIComponent(userId)}&token=${encodeURIComponent(token)}&appid=1005&mid=${encodeURIComponent(mid)}${loginPwd ? `&KugooPwd=${encodeURIComponent(loginPwd)}` : ''}`,
  ];
  const headers = Object.assign({
    'User-Agent': KG_DEMO_UA,
    Accept: 'application/json, text/plain, */*',
  }, buildKGRequestHeaders(cookieHeader, token));
  let best = { vipType: 0, isVip: false };
  for (const url of urls) {
    try {
      const body = await kgFetchJSON(url, {
        referer: 'https://www.kugou.com/',
        headers,
      });
      if (!body) continue;
      const vip = extractKGVipFromPayload(body.data || body.info || body);
      if (vip.isVip) best = mergeKGVipState(best, vip);
    } catch (_) {}
  }
  return best.isVip ? best : null;
}

async function fetchKGMobileVipInfo(cookieHeader) {
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  if (!userId || !token) return null;
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader);
  const common = `userid=${encodeURIComponent(userId)}&token=${encodeURIComponent(token)}&appid=1005&clientver=9108&mid=${encodeURIComponent(mid)}&dfid=${encodeURIComponent(dfid)}`;
  const urls = [
    `http://mobilecdn.kugou.com/api/v3/user/vipinfo?${common}`,
    `http://mobileservice.kugou.com/api/v3/user/vip?${common}`,
    `http://mobileservice.kugou.com/api/v5/user/vip?${common}`,
  ];
  let best = { vipType: 0, isVip: false };
  for (const url of urls) {
    try {
      const body = await kgFetchJSON(url, {
        mobile: true,
        referer: 'https://www.kugou.com/',
        headers: buildKGRequestHeaders(cookieHeader, token),
      });
      if (!body) continue;
      const vip = extractKGVipFromPayload(body.data || body.info || body);
      if (vip.isVip) best = mergeKGVipState(best, vip);
    } catch (_) {}
  }
  return best.isVip ? best : null;
}


export async function getKGLoginStatus(cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const userId = kgCookieUserId(cookieHeader);
  const token = kgCookieToken(cookieHeader);
  const loggedIn = !!(userId && token);
  let nickname = kgCookieNickname(cookieHeader);
  let avatar = kgCookieAvatar(cookieHeader);
  let vipType = kgCookieVipType(cookieHeader);
  let isVip = kgCookieHasVipSession(cookieHeader);
  let vipLabel = isVip ? 'VIP' : '无VIP';
  let expireTime = '';
  if (loggedIn) {
    const vipInfo = await resolveKGSessionVip(cookieHeader, { vipType, isVip, vipLabel, nickname, avatar });
    ({ vipType, isVip, vipLabel, expireTime } = vipInfo);
    if (vipInfo.nickname) nickname = vipInfo.nickname;
    if (vipInfo.avatar) avatar = vipInfo.avatar;
    rememberKGPlaySession(cookieHeader, { loggedIn, userId, vipType, isVip, vipLabel, vipResolved: true });
  }
  return {
    provider: 'kg',
    loggedIn,
    hasCookie: !!cookieHeader,
    userId,
    nickname: nickname || (loggedIn ? `酷狗 ${userId}` : '酷狗音乐'),
    avatar,
    vipType,
    isVip,
    vipLabel,
    expireTime,
    session: analyzeKGCookieSession(cookieHeader),
    hasKuGooSession: !!(parseKGCookieObject(cookieHeader).KugooID || parseKGCookieObject(cookieHeader).KugooID),
    message: !loggedIn
      ? '未检测到酷狗登录 Cookie（需要 KuGoo 或 userid+token）。你目前可能只有统计/路由 Cookie，请在 www.kugou.com 用手机号或微信完整登录。'
      : (!isVip ? '已登录（KuGoo 有效）。PC 站 KuGoo 通常不含 VIP 字段，会员状态由接口查询；若 App 有会员但这里仍显示普通账号，请在酷狗 App 内确认会员未过期。' : ''),
  };
}

export async function handleKGSearch(keywords, limit, cookieHeader, page) {
  keywords = String(keywords || '').trim();
  limit = Math.max(4, Math.min(30, Number(limit) || 16));
  page = Math.max(1, Number(page) || 1);
  if (!keywords) return [];
  const u = new URL('https://songsearch.kugou.com/song_search_v2');
  u.searchParams.set('keyword', keywords);
  u.searchParams.set('platform', 'WebFilter');
  u.searchParams.set('format', 'json');
  u.searchParams.set('page', String(page));
  u.searchParams.set('pagesize', String(limit));
  u.searchParams.set('userid', '-1');
  u.searchParams.set('tag', 'em');
  u.searchParams.set('filter', '2');
  u.searchParams.set('iscorrection', '1');
  u.searchParams.set('privilege_filter', '0');
  u.searchParams.set('_', String(Date.now()));
  const searchHeaders = kgCookieToken(cookieHeader)
    ? buildKGRequestHeaders(cookieHeader)
    : { Cookie: cookieHeader || '' };
  let body = await kgFetchJSON(u.toString(), { mobile: true, headers: searchHeaders });
  if (!body || !body.data) {
    body = await kgFetchJSON(u.toString(), { mobile: true });
  }
  const list = (body && body.data && body.data.lists) || [];
  return list.map((item) => mapKGSong(item, true)).filter((s) => s.hash && s.name);
}

async function fetchKGPlayInfo(hash, albumAudioId, cookieHeader) {
  const u = new URL('https://m.kugou.com/app/i/getSongInfo.php');
  u.searchParams.set('cmd', 'playInfo');
  u.searchParams.set('hash', String(hash || '').trim());
  if (albumAudioId) u.searchParams.set('album_audio_id', String(albumAudioId));
  return kgFetchJSON(u.toString(), {
    mobile: true,
    referer: 'https://m.kugou.com/',
    headers: buildKGRequestHeaders(cookieHeader),
  });
}

async function fetchKGTrackerOnce(host, vipType, hash, albumId, albumAudioId, cookieHeader) {
  const userId = kgCookieUserId(cookieHeader) || '0';
  const token = kgCookieToken(cookieHeader) || '';
  const mid = await getKGMid(cookieHeader);
  const key = buildKGTrackerKey(hash, mid, userId);
  const audioId = String(albumAudioId || '0');
  const dfid = kgCookieDfid(cookieHeader);
  const vipToken = kgCookieVipToken(cookieHeader);
  const u = new URL(`${host}/i/v2/`);
  u.searchParams.set('cmd', '26');
  u.searchParams.set('key', key);
  u.searchParams.set('hash', hash);
  u.searchParams.set('behavior', 'play');
  u.searchParams.set('mid', mid);
  u.searchParams.set('dfid', dfid);
  u.searchParams.set('appid', '1005');
  u.searchParams.set('userid', userId);
  u.searchParams.set('version', '9108');
  u.searchParams.set('vipType', vipType);
  u.searchParams.set('token', token);
  if (vipToken) u.searchParams.set('vip_token', vipToken);
  u.searchParams.set('album_id', albumId || '0');
  u.searchParams.set('album_audio_id', audioId);
  u.searchParams.set('area_code', '1');
  u.searchParams.set('pid', '2');
  u.searchParams.set('pidversion', '3001');
  u.searchParams.set('with_res_tag', '1');
  const body = await kgFetchJSON(u.toString(), {
    mobile: true,
    referer: 'https://www.kugou.com/',
    headers: buildKGRequestHeaders(cookieHeader, token),
  });
  const url = parseKGPlayUrl(body);
  const status = Number(body && body.status) || 0;
  return { url, status, blocked: status === 2, vipType };
}

async function fetchKGTrackerUrl(hash, albumId, albumAudioId, cookieHeader, loginVipType) {
  hash = String(hash || '').trim().toLowerCase();
  if (!hash) return { url: '', status: 0, blocked: false };
  const fastVipTypes = buildKGTrackerFastVipTypes(cookieHeader, loginVipType);
  const fastTasks = [];
  KG_TRACKER_FAST_HOSTS.forEach((host) => {
    fastVipTypes.forEach((vipType) => {
      fastTasks.push(() => fetchKGTrackerOnce(host, vipType, hash, albumId, albumAudioId, cookieHeader));
    });
  });
  const fastHit = await raceKGPlayTasks(fastTasks, (result) => result && result.url ? result : null);
  if (fastHit) return fastHit;
  let lastStatus = 0;
  const tried = new Set();
  KG_TRACKER_FAST_HOSTS.forEach((host) => {
    fastVipTypes.forEach((vipType) => tried.add(`${host}|${vipType}`));
  });
  const fallbackTasks = [];
  for (const host of KG_TRACKER_HOSTS) {
    for (const vipType of buildKGTrackerVipTypeCandidates(cookieHeader, loginVipType)) {
      const key = `${host}|${vipType}`;
      if (tried.has(key)) continue;
      tried.add(key);
      fallbackTasks.push(() => fetchKGTrackerOnce(host, vipType, hash, albumId, albumAudioId, cookieHeader));
    }
  }
  const fallbackHit = await raceKGPlayTasks(fallbackTasks, (result) => result && result.url ? result : null);
  if (fallbackHit) return fallbackHit;
  return { url: '', status: lastStatus, blocked: lastStatus === 2 };
}

async function resolveKGSongPlayUrl(hash, albumId, albumAudioId, cookieHeader, login) {
  const tasks = [
    () => fetchKGPlayGetData(hash, albumId, albumAudioId, cookieHeader, login.vipType)
      .then((url) => (url ? { url, source: 'getdata' } : null)),
    () => fetchKGTrackerUrl(hash, albumId, albumAudioId, cookieHeader, login.vipType)
      .then((result) => (result.url ? { url: result.url, source: 'tracker', tracker: result } : null)),
    () => fetchKGPlayInfo(hash, albumAudioId, cookieHeader)
      .then((info) => {
        const url = pickPlayInfoUrl(info);
        return url ? { url, source: 'playInfo' } : null;
      }),
  ];
  return raceKGPlayTasks(tasks, (result) => result);
}

async function fetchKGPlayGetData(hash, albumId, albumAudioId, cookieHeader, loginVipType) {
  hash = String(hash || '').trim().toLowerCase();
  if (!hash) return '';
  const userId = kgCookieUserId(cookieHeader) || '0';
  const token = kgCookieToken(cookieHeader) || '';
  const mid = await getKGMid(cookieHeader);
  const dfid = kgCookieDfid(cookieHeader);
  const u = new URL('https://wwwapi.kugou.com/yy/index.php');
  u.searchParams.set('r', 'play/getdata');
  u.searchParams.set('hash', hash);
  u.searchParams.set('album_id', albumId || '0');
  if (albumAudioId) u.searchParams.set('album_audio_id', String(albumAudioId));
  u.searchParams.set('mid', mid);
  u.searchParams.set('dfid', dfid);
  u.searchParams.set('platid', '4');
  u.searchParams.set('from', 'mkugou');
  if (token) {
    u.searchParams.set('appid', String(KG_ANDROID_APPID));
    u.searchParams.set('clientver', String(KG_ANDROID_CLIENTVER));
    u.searchParams.set('userid', userId);
    u.searchParams.set('token', token);
    u.searchParams.set('vipType', resolveKGTrackerVipType(cookieHeader, loginVipType));
  }
  try {
    const body = await kgFetchJSON(u.toString(), {
      referer: 'https://www.kugou.com/',
      headers: buildKGRequestHeaders(cookieHeader, token),
    });
    const data = body && body.data;
    const url = data && (data.play_url || data.play_backup_url || data.playUrl || data.url);
    if (typeof url === 'string' && url) return url;
    if (Array.isArray(url) && url[0]) return url[0];
  } catch (_) {}
  return '';
}

function normalizePlayUrl(url) {
  url = String(url || '').trim();
  if (!url) return '';
  if (/^https?:\/\//i.test(url)) return url;
  if (url.startsWith('//')) return 'http:' + url;
  if (url.startsWith('/')) return 'http://fs.open.kugou.com' + url;
  return 'http://fs.open.kugou.com/' + url.replace(/^\/+/, '');
}

export async function handleKGSongUrl(hash, albumId, albumAudioId, quality, cookieHeader, qualityHashes) {
  hash = String(hash || '').trim().toLowerCase();
  albumId = String(albumId || '').trim();
  albumAudioId = String(albumAudioId || '').trim();
  qualityHashes = qualityHashes || {};
  const hash320 = String(qualityHashes.hash320 || '').trim().toLowerCase();
  const hashSq = String(qualityHashes.hashSq || '').trim().toLowerCase();
  if (!hash) {
    return { provider: 'kg', url: '', playable: false, error: 'MISSING_HASH', message: 'Missing Kugou song hash' };
  }
  cookieHeader = cookieHeader || await getKGCookie();
  const requestedQuality = normalizeQualityPreference(quality);
  const extra = { '128hash': hash };
  if (hash320) extra['320hash'] = hash320;
  if (hashSq) extra.sqhash = hashSq;
  const desiredLevels = qualityCandidatesFrom(requestedQuality, KG_QUALITY_OPTIONS).map((item) => item.level);
  const desiredLevel = desiredLevels[0] || 'standard';
  const qualityMap = extractKGQualityMap(extra, hash);
  if (!qualityMap[desiredLevel]) {
    try {
      const playInfo = await fetchKGPlayInfo(hash, albumAudioId, cookieHeader);
      Object.assign(extra, (playInfo && playInfo.extra) || {});
      if (playInfo && playInfo.hash) extra['128hash'] = String(playInfo.hash).trim().toLowerCase();
    } catch (_) {}
  }
  const picked = pickKGHashForQuality(extra, hash, requestedQuality);
  const playHash = picked.hash;
  if (!playHash) {
    return { provider: 'kg', url: '', playable: false, error: 'MISSING_HASH', message: 'Missing Kugou song hash' };
  }
  const cacheKey = buildKGPlayUrlCacheKey(playHash, albumId, albumAudioId, picked.level);
  const login = await getKGPlayContext(cookieHeader);
  const successPayload = (url, source) => ({
    provider: 'kg',
    url: normalizePlayUrl(url),
    playable: true,
    loggedIn: login.loggedIn,
    isVip: login.isVip,
    vipType: login.vipType,
    vipLabel: login.vipLabel,
    level: picked.level,
    quality: picked.label,
    br: picked.br,
    requestedQuality,
    playHash,
    source,
  });
  const cachedUrl = readKGPlayUrlCache(cacheKey);
  if (cachedUrl) return successPayload(cachedUrl, 'cache');
  let trackerResult = { url: '', status: 0, blocked: false };
  try {
    const hit = await resolveKGSongPlayUrl(playHash, albumId, albumAudioId, cookieHeader, login);
    if (hit && hit.url) {
      writeKGPlayUrlCache(cacheKey, hit.url);
      if (hit.tracker) trackerResult = hit.tracker;
      return successPayload(hit.url, hit.source);
    }
    if (hit && hit.tracker) trackerResult = hit.tracker;
  } catch (_) {}
  const blocked = trackerResult.blocked || trackerResult.status === 2;
  const likelyVipSong = blocked || trackerResult.status === 2;
  return {
    provider: 'kg',
    url: '',
    playable: false,
    loggedIn: login.loggedIn,
    isVip: login.isVip,
    vipType: login.vipType,
    vipLabel: login.vipLabel,
    error: !login.loggedIn ? 'LOGIN_REQUIRED' : (likelyVipSong && !login.isVip ? 'VIP_REQUIRED' : 'URL_UNAVAILABLE'),
    reason: !login.loggedIn ? 'login_required' : (likelyVipSong ? 'vip_required' : 'url_unavailable'),
    message: !login.loggedIn
      ? '酷狗会员歌曲需要登录后播放'
      : (likelyVipSong && !login.isVip
        ? '酷狗会员歌曲需要开通酷狗 VIP，或在 kugou.com 重新登录后再试'
        : '酷狗未返回播放地址，请确认账号会员有效并在官网重新登录'),
    trackerStatus: trackerResult.status || 0,
  };
}

function decodeKGLyricContent(content) {
  content = String(content || '').trim();
  if (!content) return '';
  try {
    if (!content.includes('[') && /^[A-Za-z0-9+/=\s]+$/.test(content)) {
      const bin = atob(content.replace(/\s/g, ''));
      const decoded = decodeURIComponent(escape(bin));
      if (decoded && (decoded.includes('[') || /[\u4e00-\u9fa5]/.test(decoded))) return decoded;
    }
  } catch (_) {}
  return content;
}

async function fetchKGBasicLrc(hash) {
  if (!hash) return '';
  try {
    const text = await kgFetchText(`http://m.kugou.com/krc/${encodeURIComponent(hash)}.lrc`, {
      mobile: true,
      referer: 'https://m.kugou.com/',
    });
    return String(text || '').trim();
  } catch (_) {
    return '';
  }
}

export async function handleKGLyric(hash, albumId, duration) {
  hash = String(hash || '').trim();
  albumId = String(albumId || '').trim();
  if (!hash) return { provider: 'kg', lyric: '', error: 'MISSING_HASH' };
  let lyric = await fetchKGBasicLrc(hash);
  if (lyric) return { provider: 'kg', lyric, source: 'basic' };
  try {
    const u = new URL('https://krcs.kugou.com/search');
    u.searchParams.set('ver', '1');
    u.searchParams.set('man', 'yes');
    u.searchParams.set('client', 'mobi');
    u.searchParams.set('keyword', hash);
    u.searchParams.set('hash', hash);
    if (albumId) u.searchParams.set('album_audio_id', albumId);
    if (duration) u.searchParams.set('duration', String(Math.max(1, Math.round(Number(duration) / 1000))));
    const search = await kgFetchJSON(u.toString(), { mobile: true, referer: 'https://www.kugou.com/' });
    const candidate = (search && search.candidates && search.candidates[0]) || null;
    if (candidate && candidate.id && candidate.accesskey) {
      const dl = new URL('http://lyrics.kugou.com/download');
      dl.searchParams.set('ver', '1');
      dl.searchParams.set('client', 'pc');
      dl.searchParams.set('id', String(candidate.id));
      dl.searchParams.set('accesskey', String(candidate.accesskey));
      dl.searchParams.set('fmt', 'lrc');
      dl.searchParams.set('charset', 'utf8');
      const body = await kgFetchJSON(dl.toString(), { referer: 'https://www.kugou.com/' });
      lyric = decodeKGLyricContent(body && (body.content || body.data && body.data.content));
      if (lyric) return { provider: 'kg', lyric, source: 'krc' };
    }
  } catch (_) {}
  return { provider: 'kg', lyric: '' };
}

export async function handleKGUserPlaylists(cookieHeader) {
  cookieHeader = cookieHeader || await getKGCookie();
  const login = await getKGLoginStatus(cookieHeader);
  if (!login.loggedIn) return { provider: 'kg', loggedIn: false, playlists: [] };
  const u = new URL('http://m.kugou.com/plist/index');
  u.searchParams.set('op', 'getMyPlist');
  u.searchParams.set('token', kgCookieToken(cookieHeader));
  u.searchParams.set('t', String(Date.now()));
  const body = await kgFetchJSON(u.toString(), {
    mobile: true,
    referer: 'http://m.kugou.com/',
    headers: buildKGRequestHeaders(cookieHeader),
  });
  const list = (body && (body.lists || body.data && body.data.lists)) || [];
  const playlists = list.map(mapKGPlaylist).filter((pl) => pl.id);
  return { provider: 'kg', loggedIn: true, userId: login.userId, playlists };
}

export async function handleKGPlaylistTracks(id, cookieHeader) {
  id = String(id || '').trim();
  if (!id) return { provider: 'kg', error: 'Missing playlist id', tracks: [] };
  cookieHeader = cookieHeader || await getKGCookie();
  const login = await getKGLoginStatus(cookieHeader);
  const pageSize = 200;
  let page = 1;
  let total = Infinity;
  const tracks = [];
  while (tracks.length < total && page <= 20) {
    const u = new URL('http://mobilecdn.kugou.com/api/v3/special/song');
    u.searchParams.set('specialid', id);
    u.searchParams.set('page', String(page));
    u.searchParams.set('pagesize', String(pageSize));
    u.searchParams.set('version', '9108');
    u.searchParams.set('area_code', '1');
    const body = await kgFetchJSON(u.toString(), {
      mobile: true,
      referer: 'https://www.kugou.com/',
      headers: buildKGRequestHeaders(cookieHeader),
    });
    const info = (body && body.data && body.data.info) || (body && body.info) || [];
    total = Number((body && body.data && body.data.total) || body.total || info.length) || info.length;
    info.forEach((item) => {
      const song = mapKGSong(item, false);
      if (song.hash) tracks.push(song);
    });
    if (!info.length) break;
    page += 1;
  }
  const playlist = { id, provider: 'kg', trackCount: tracks.length };
  return { provider: 'kg', loggedIn: login.loggedIn, playlist, tracks };
}

export function normalizeKGCookieInput(raw) {
  return String(raw || '').trim();
}

export function validateKGCookie(raw) {
  const obj = parseKGCookieObject(normalizeKGCookieInput(raw));
  const userId = obj.userid || obj.KugooID || obj.kugouid || '';
  const token = obj.token || obj.KToken || obj.kg_token || obj.t || '';
  return !!(String(userId).trim() && String(token).trim());
}

function normalizeKGArtistName(name) {
  return String(name || '').replace(/<[^>]+>/g, '').trim().toLowerCase();
}

async function searchKGSingerId(name) {
  name = String(name || '').trim();
  if (!name) return { singerId: '', singerName: '' };
  const u = new URL('http://mobilecdn.kugou.com/api/v3/search/singer');
  u.searchParams.set('keyword', name);
  u.searchParams.set('page', '1');
  u.searchParams.set('pagesize', '8');
  u.searchParams.set('version', '9108');
  u.searchParams.set('plat', '0');
  u.searchParams.set('with_res_tag', '1');
  const body = await kgFetchJSON(u.toString(), { mobile: true, referer: 'https://www.kugou.com/' });
  const list = (body && body.data && body.data.info) || (body && body.info) || [];
  const target = normalizeKGArtistName(name);
  const matched = list.find((item) => normalizeKGArtistName(item.singername || item.author_name || item.name) === target)
    || list.find((item) => {
      const candidate = normalizeKGArtistName(item.singername || item.author_name || item.name);
      return candidate && (candidate.includes(target) || target.includes(candidate));
    })
    || list[0];
  if (!matched) return { singerId: '', singerName: name };
  return {
    singerId: String(matched.singerid || matched.singer_id || matched.id || '').trim(),
    singerName: matched.singername || matched.author_name || matched.name || name,
  };
}

export async function handleKGArtistDetail(id, name, limit) {
  limit = Math.max(10, Math.min(80, Number(limit) || 36));
  let singerId = String(id || '').trim();
  let singerName = String(name || '').trim();
  if (!singerId && singerName) {
    const found = await searchKGSingerId(singerName);
    singerId = found.singerId;
    singerName = found.singerName || singerName;
  }
  if (!singerId) {
    return { provider: 'kg', error: 'MISSING_SINGER_ID', message: '缺少酷狗歌手 ID', artist: null, songs: [] };
  }
  let info = {};
  try {
    const infoBody = await kgFetchJSON(
      `http://mobilecdn.kugou.com/api/v3/singer/info?singerid=${encodeURIComponent(singerId)}&with_res_tag=1`,
      { mobile: true, referer: 'https://www.kugou.com/' },
    );
    info = (infoBody && infoBody.data) || infoBody || {};
  } catch (_) {}
  const songsUrl = new URL('http://mobilecdn.kugou.com/api/v3/singer/song');
  songsUrl.searchParams.set('singerid', singerId);
  songsUrl.searchParams.set('page', '1');
  songsUrl.searchParams.set('pagesize', String(limit));
  songsUrl.searchParams.set('sorttype', '2');
  songsUrl.searchParams.set('plat', '0');
  songsUrl.searchParams.set('version', '9108');
  songsUrl.searchParams.set('area_code', '1');
  songsUrl.searchParams.set('with_res_tag', '1');
  let rawSongs = [];
  try {
    const songsBody = await kgFetchJSON(songsUrl.toString(), { mobile: true, referer: 'https://www.kugou.com/' });
    rawSongs = (songsBody && songsBody.data && songsBody.data.info) || (songsBody && songsBody.info) || [];
  } catch (_) {}
  return {
    provider: 'kg',
    artist: {
      provider: 'kg',
      id: singerId,
      name: info.singername || info.author_name || singerName || '',
      avatar: normalizeKGCover(info.imgurl || info.singerHead || info.pic || info.avatar || '', 240),
      briefDesc: info.intro || info.description || '',
    },
    songs: rawSongs.map((item) => mapKGSong(item, false)).filter((song) => song.hash && song.name),
  };
}

function parseKGCommentTime(value) {
  const text = String(value || '').trim();
  if (!text) return 0;
  const parsed = Date.parse(text.replace(/-/g, '/'));
  return Number.isFinite(parsed) ? parsed : 0;
}

export async function handleKGSongComments(hash, albumAudioId, limit, page) {
  hash = String(hash || '').trim().toLowerCase();
  albumAudioId = String(albumAudioId || '').trim();
  limit = Math.max(1, Math.min(40, Number(limit) || 20));
  page = Math.max(1, Number(page) || 1);
  if (!hash) {
    return { provider: 'kg', error: 'Missing song hash', comments: [] };
  }
  const u = new URL('http://m.comment.service.kugou.com/index.php');
  u.searchParams.set('r', 'commentsv2/getCommentWithLike');
  u.searchParams.set('extdata', hash);
  u.searchParams.set('p', String(page));
  u.searchParams.set('pagesize', String(limit));
  u.searchParams.set('code', 'fc4be23b4e972707f36b8a828a93ba8a');
  u.searchParams.set('clientver', '8983');
  if (albumAudioId) u.searchParams.set('mixsongid', albumAudioId);
  try {
    const body = await kgFetchJSON(u.toString(), { referer: 'https://www.kugou.com/' });
    const raw = (body && (body.list || body.comments)) || [];
    const comments = (Array.isArray(raw) ? raw : [])
      .map((item) => ({
        id: item.id || item.cmtid || item.comment_id || '',
        content: stripKGHighlightHtml(item.content || item.msg || ''),
        likedCount: Number((item.like && (item.like.likenum || item.like.count)) || item.like_count || 0) || 0,
        time: parseKGCommentTime(item.addtime || item.add_time || item.time),
        user: {
          id: item.user_id || (item.udetail && item.udetail.user_id) || '',
          nickname: stripKGHighlightHtml(item.user_name || item.nickname || item.username || '酷狗用户'),
          avatar: item.user_pic || item.user_avatar || (item.udetail && item.udetail.user_pic) || '',
        },
      }))
      .filter((item) => item.content);
    return {
      provider: 'kg',
      hash,
      albumAudioId,
      total: Number((body && (body.combine_count || body.count)) || 0) || comments.length,
      comments,
    };
  } catch (err) {
    return { provider: 'kg', error: err.message || 'KG_COMMENTS_FAILED', comments: [] };
  }
}

export async function handleKGLoginCookie(raw) {
  const normalized = normalizeKGCookieInput(raw);
  if (!validateKGCookie(normalized)) {
    return {
      provider: 'kg',
      loggedIn: false,
      error: 'INVALID_KG_COOKIE',
      message: '酷狗 cookie 缺少 userid 或 token',
    };
  }
  await setBrowserCookies('https://www.kugou.com/', normalized);
  await setBrowserCookies('https://m.kugou.com/', normalized);
  const cookieHeader = await getKGCookie();
  const info = await getKGLoginStatus(cookieHeader);
  return { ...info, saved: info.loggedIn, hasCookie: info.loggedIn };
}
