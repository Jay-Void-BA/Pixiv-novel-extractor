/* global validatePairing */
if (typeof importScripts === 'function') importScripts('validation.js');
const api = globalThis.browser ?? globalThis.chrome;
const pendingKey = 'pendingPairing';
let transferring = false;

async function sendSession(pending) {
  if (transferring) return false;
  if (!pending || Date.now() > pending.expires) {
    await api.storage.session.remove(pendingKey); return false;
  }
  const cookie = await api.cookies.get({url: 'https://www.pixiv.net/', name: 'PHPSESSID'});
  if (!cookie?.value || !/^[A-Za-z0-9_%.-]{8,512}$/.test(cookie.value)) return false;
  transferring = true;
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(pending.endpoint, {
        method: 'POST', redirect: 'error', credentials: 'omit', cache: 'no-store',
        headers: {'Content-Type': 'application/json', Authorization: `Bearer ${pending.token}`},
        body: JSON.stringify({session: cookie.value}), signal: controller.signal,
      });
      if (!response.ok) throw new Error('本机应用拒绝了连接，请从 Shiori 重新发起登录。');
      await api.storage.session.remove(pendingKey);
      return true;
    } finally { clearTimeout(timeout); }
  } finally { transferring = false; }
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    if (message.kind === 'pair') {
      const pairing = validatePairing(message.url);
      const source = validatePairing(sender.url);
      if (pairing.endpoint !== source.endpoint || pairing.token !== source.token) throw new Error('连接来源不匹配');
      await api.tabs.create({url: api.runtime.getURL('approve.html') + '#' + encodeURIComponent(message.url)});
      return {ok: true};
    }
    if (!sender.url?.startsWith(api.runtime.getURL('approve.html') + '#')) throw new Error('只允许扩展确认页授权');
    const pairing = validatePairing(decodeURIComponent(new URL(sender.url).hash.slice(1)));
    const pending = {...pairing, expires: Date.now() + 5 * 60 * 1000};
    if (message.kind === 'login') {
      await api.storage.session.set({[pendingKey]: pending});
      await api.tabs.create({url: 'https://accounts.pixiv.net/login?return_to=https%3A%2F%2Fwww.pixiv.net%2F'});
      return {ok: true, waiting: true};
    }
    if (message.kind === 'connect') {
      const ok = await sendSession(pending);
      return {ok, error: ok ? null : '未找到登录 Cookie。请先登录 Pixiv，再点击连接。'};
    }
    throw new Error('未知操作');
  })().then(sendResponse, (e) => sendResponse({ok: false, error: e.message}));
  return true;
});

api.cookies.onChanged.addListener(async ({removed, cookie}) => {
  if (removed || cookie.name !== 'PHPSESSID' || !/(^|\.)pixiv\.net$/.test(cookie.domain)) return;
  const pending = (await api.storage.session.get(pendingKey))[pendingKey];
  if (!pending) return;
  try { await sendSession(pending); } catch { /* Retry from the explicit confirmation page. */ }
});
