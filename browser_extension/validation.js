/* Pure validation, shared with the browser extension's Node test suite. */
function validatePairing(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('连接地址无效'); }
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' ||
      !url.port || Number(url.port) < 1024 || url.pathname !== '/pair' ||
      url.username || url.password || url.search || !/^[A-Za-z0-9_-]{43}$/.test(url.hash.slice(1))) {
    throw new Error('仅允许 Shiori 的本机临时连接页');
  }
  return {endpoint: `${url.origin}/session`, token: url.hash.slice(1)};
}
if (typeof module !== 'undefined') module.exports = {validatePairing};
