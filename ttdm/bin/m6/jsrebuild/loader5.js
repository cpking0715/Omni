// loader5.js — js-reverse Patch: 沙箱内触发 webmssdk 拦截层, 捕获完整签名 URL
// 思路: webmssdk 加载时包装 fetch/XHR; 预置记录器版 fetch/XHR, 拦截层附加签名后调用它们 → 捕获签名后 URL
'use strict';
const fs = require('fs');
const vm = require('vm');

const sandbox = {};
sandbox.window = sandbox; sandbox.self = sandbox; sandbox.top = sandbox; sandbox.parent = sandbox; sandbox.globalThis = sandbox;
sandbox.navigator = {
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
  platform: 'Win32', language: 'en-US', languages: ['en-US'], maxTouchPoints: 0, webdriver: false,
};
sandbox.location = {
  href: 'https://www.tiktok.com/messages?lang=en', protocol: 'https:', host: 'www.tiktok.com',
  hostname: 'www.tiktok.com', pathname: '/messages', search: '?lang=en', origin: 'https://www.tiktok.com',
};
sandbox.document = {
  cookie: '', referrer: '', title: 'TikTok', readyState: 'complete',
  createElement: () => ({ style: {}, setAttribute() {}, getContext: () => null }),
  getElementById: () => null, querySelector: () => null,
  addEventListener() {}, removeEventListener() {},
  dispatchEvent: (e) => { console.log('[stub] document.dispatchEvent', e && e.type); return true; },
  documentElement: { style: {}, clientWidth: 1707, clientHeight: 1067 },
  body: { style: {}, clientWidth: 1707, clientHeight: 1067 },
  hidden: false, visibilityState: 'visible',
};
sandbox.screen = { width: 1707, height: 1067, availWidth: 1707, availHeight: 1067, colorDepth: 24, pixelDepth: 24 };
sandbox.history = { length: 14 };
for (const k of [
  'Uint8Array', 'Uint16Array', 'Uint32Array', 'Int8Array', 'Int16Array', 'Int32Array', 'Float32Array',
  'Float64Array', 'ArrayBuffer', 'SharedArrayBuffer', 'DataView', 'TextEncoder', 'TextDecoder',
  'crypto', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'queueMicrotask',
  'console', 'Headers', 'Request', 'Response', 'URL', 'URLSearchParams', 'Event',
  'Error', 'TypeError', 'RangeError', 'SyntaxError', 'Date', 'Math', 'JSON', 'Object', 'Array',
  'String', 'Number', 'Boolean', 'RegExp', 'Promise', 'Symbol', 'Map', 'Set', 'WeakMap', 'WeakSet',
  'Proxy', 'Reflect', 'atob', 'btoa', 'isNaN', 'parseInt', 'parseFloat', 'Infinity', 'NaN',
  'BigInt', 'AbortController', 'AbortSignal', 'MessageChannel', 'MessagePort',
]) {
  if (typeof globalThis[k] !== 'undefined') sandbox[k] = globalThis[k];
}
sandbox.Buffer = Buffer;
sandbox.performance = globalThis.performance;

// --- 签名拦截层的"原生底层"：记录器版 fetch/XHR (webmssdk 包装后附加签名再调用它们) ---
sandbox.__rsLog = [];
sandbox.__rsLogFetches = [];
sandbox.__rsLogXhr = [];
// 加载前快照, 用于检测 webmssdk 是否包装了 fetch/XHR
sandbox.__rsOrigFetchSnapshot = sandbox.fetch;

sandbox.fetch = (input, init) => {
  const url = typeof input === 'string' ? input : (input && input.url) || String(input);
  const entry = {
    fetch: true,
    url,
    method: (init && init.method) || 'GET',
    body: String((init && init.body) || '').slice(0, 800),
    headers: init && init.headers ? JSON.stringify(init.headers).slice(0, 400) : '',
  };
  sandbox.__rsLog.push(entry);
  if (url.indexOf('im-api') >= 0 || url.indexOf('X-Bogus') >= 0 || url.indexOf('X-Dynosaur') >= 0) {
    sandbox.__rsLogFetches.push(entry);
  }
  const respBody = JSON.stringify({ statusCode: 0, status_msg: 'ok', data: {} });
  return Promise.resolve(new sandbox.Response(respBody, {
    status: 200,
    headers: { 'content-type': 'application/json' },
  }));
};

sandbox.XMLHttpRequest = class {
  constructor() {
    this.readyState = 0; this.status = 0; this.responseText = ''; this.responseURL = '';
    this.__url = ''; this.__method = 'GET'; this.__body = '';
  }
  open(method, url) { this.__method = method; this.__url = url; this.readyState = 1; }
  setRequestHeader() {}
  send(body) {
    this.__body = String(body || '');
    const entry = {
      xhr: true, url: this.__url, method: this.__method,
      body: this.__body.slice(0, 800),
    };
    sandbox.__rsLog.push(entry);
    if (this.__url.indexOf('im-api') >= 0 || this.__url.indexOf('X-Bogus') >= 0 || this.__url.indexOf('X-Dynosaur') >= 0) {
      sandbox.__rsLogXhr.push(entry);
    }
    this.readyState = 4; this.status = 200;
    this.responseText = '{"statusCode":0,"data":{}}';
    try { if (this.onreadystatechange) this.onreadystatechange(); } catch (e) {}
    try { if (this.onload) this.onload(); } catch (e) {}
  }
  abort() {}
  getAllResponseHeaders() { return ''; }
  getResponseHeader() { return null; }
};
sandbox.__rsOrigXhrOpenSnapshot = sandbox.XMLHttpRequest.prototype.open;

vm.createContext(sandbox);
const src = fs.readFileSync('./webmssdk.js', 'utf8');
vm.runInContext(src, sandbox, { filename: 'webmssdk.js' });
console.log('=== loaded ===');

const probe = vm.runInContext(`(async () => {
  const out = {};
  out.fetchWrapped = window.fetch !== __rsOrigFetchSnapshot;
  out.byted = typeof window.byted_acrawler;
  out.xhrWrapped = XMLHttpRequest.prototype.open !== __rsOrigXhrOpenSnapshot;
  // 触发: 模拟业务请求
  const urls = [
    'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc&device_id=7669334412366218765&channel=tiktok_web',
    'https://im-api.tiktok.com/v1/message/conversation?aid=1988&device_platform=web_pc',
  ];
  for (const u of urls) {
    try {
      await window.fetch(u, { method: 'POST', body: '{"conversation_id":"731234567890","content":"hello"}', headers: { 'content-type': 'application/json' } });
    } catch (e) { out.errFetch = String(e).slice(0, 300); }
    try {
      const x = new XMLHttpRequest();
      x.open('POST', u);
      x.send('{"conversation_id":"731234567890","content":"hello"}');
    } catch (e) { out.errXhr = String(e).slice(0, 300); }
  }
  return JSON.stringify(out);
})()`, sandbox);
Promise.resolve(probe).then(v => {
  console.log('PROBE:', v);
  console.log('=== 捕获的签名 URL (im-api/X-Bogus/X-Dynosaur) ===');
  for (const e of sandbox.__rsLogFetches) console.log('FETCH:', e.url.slice(0, 700));
  for (const e of sandbox.__rsLogXhr) console.log('XHR  :', e.url.slice(0, 700));
  console.log('=== 全部请求 ===');
  for (const e of sandbox.__rsLog) console.log((e.fetch ? 'F' : 'X') + ': ' + e.url.slice(0, 300));
}).catch(e => console.log('PROMISE ERR:', String(e)));
