const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const {validatePairing} = require('../browser_extension/validation.js');
const token = 'x'.repeat(43);
test('only sends to an explicit loopback ephemeral endpoint', () => {
  assert.deepEqual(validatePairing(`http://127.0.0.1:49152/pair#${token}`), {
    endpoint: 'http://127.0.0.1:49152/session', token,
  });
});
test('rejects remote destinations, embedded credentials and malformed nonces', () => {
  for (const url of [
    `https://evil.example/pair#${token}`, `http://127.0.0.1.evil.example:45000/pair#${token}`,
    `http://127.0.0.1:80/pair#${token}`, `http://user:password@127.0.0.1:45000/pair#${token}`,
    `http://127.0.0.1:45000/redirect#${token}`, 'http://127.0.0.1:45000/pair#short',
    `http://127.0.0.1:45000/pair?target=evil#${token}`, `file:///pair#${token}`,
  ]) assert.throws(() => validatePairing(url), url);
});

function backgroundHarness() {
  let onMessage, onCookie, cookieReads = 0;
  const storage = {};
  const sent = [];
  const opened = [];
  const prefix = 'chrome-extension://' + 'a'.repeat(32) + '/';
  const api = {
    runtime: {getURL: (p) => prefix + p, onMessage: {addListener: (fn) => { onMessage = fn; }}},
    tabs: {create: async (args) => { opened.push(args.url); }},
    cookies: {
      get: async () => { cookieReads++; return {value: '123456_test_session'}; },
      onChanged: {addListener: (fn) => { onCookie = fn; }},
    },
    storage: {session: {
      get: async (key) => ({[key]: storage[key]}),
      set: async (data) => Object.assign(storage, data),
      remove: async (key) => { delete storage[key]; },
    }},
  };
  const context = vm.createContext({browser: api, URL, Date, setTimeout, clearTimeout, AbortController,
    fetch: async (url, options) => { sent.push({url, options}); return {ok: true}; },
  });
  for (const name of ['validation.js', 'background.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../browser_extension', name), 'utf8'), context);
  }
  const pair = `http://127.0.0.1:49152/pair#${token}`;
  return {
    pair, sent, opened, storage, get reads() { return cookieReads; },
    sender: {url: prefix + 'approve.html#' + encodeURIComponent(pair)},
    message: (m, sender) => new Promise((resolve) => onMessage(m, sender, resolve)),
    cookie: (change) => onCookie(change),
  };
}

test('pairing and unauthorised pages never read or transmit the cookie', async () => {
  const h = backgroundHarness();
  assert.equal((await h.message({kind: 'pair', url: h.pair}, {url: h.pair})).ok, true);
  assert.equal(h.opened.length, 1);
  assert.equal(h.reads, 0);
  assert.equal((await h.message({kind: 'connect'}, {url: 'https://evil.example'})).ok, false);
  assert.equal(h.reads, 0);
  assert.equal(h.sent.length, 0);
  await h.cookie({removed: false, cookie: {name: 'PHPSESSID', domain: '.pixiv.net'}});
  assert.equal(h.reads, 0);
});

test('explicit approval transmits once to loopback with no redirects or cookies', async () => {
  const h = backgroundHarness();
  assert.equal((await h.message({kind: 'connect'}, h.sender)).ok, true);
  assert.equal(h.sent.length, 1);
  const {url, options} = h.sent[0];
  assert.equal(url, 'http://127.0.0.1:49152/session');
  assert.equal(options.headers.Authorization, 'Bearer ' + token);
  assert.equal(options.redirect, 'error');
  assert.equal(options.credentials, 'omit');
  assert.deepEqual(JSON.parse(options.body), {session: '123456_test_session'});
});

test('login consent allows a later cookie change and clears pending state', async () => {
  const h = backgroundHarness();
  assert.equal((await h.message({kind: 'login'}, h.sender)).waiting, true);
  assert.equal(h.reads, 0);
  assert.match(h.opened[0], /^https:\/\/accounts\.pixiv\.net\/login\?/);
  await h.cookie({removed: false, cookie: {name: 'PHPSESSID', domain: '.pixiv.net'}});
  assert.equal(h.sent.length, 1);
  assert.equal(h.storage.pendingPairing, undefined);
  await h.cookie({removed: false, cookie: {name: 'PHPSESSID', domain: '.pixiv.net'}});
  assert.equal(h.sent.length, 1);
});

test('expired pending pairing and cookie changes on other domains cannot send', async () => {
  const h = backgroundHarness();
  await h.message({kind: 'login'}, h.sender);
  await h.cookie({removed: false, cookie: {name: 'PHPSESSID', domain: 'evilpixiv.net'}});
  assert.equal(h.sent.length, 0);
  h.storage.pendingPairing.expires = Date.now() - 1;
  await h.cookie({removed: false, cookie: {name: 'PHPSESSID', domain: '.pixiv.net'}});
  assert.equal(h.reads, 0);
  assert.equal(h.sent.length, 0);
});
