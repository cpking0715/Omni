// loader4.js — js-reverse Rebuild 第4步: 沙箱内调用 frontierSign 生成 X-Bogus (验证本地签名能力)
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
  'console', 'fetch', 'Headers', 'Request', 'Response', 'URL', 'URLSearchParams', 'Event',
  'Error', 'TypeError', 'RangeError', 'SyntaxError', 'Date', 'Math', 'JSON', 'Object', 'Array',
  'String', 'Number', 'Boolean', 'RegExp', 'Promise', 'Symbol', 'Map', 'Set', 'WeakMap', 'WeakSet',
  'Proxy', 'Reflect', 'atob', 'btoa', 'isNaN', 'parseInt', 'parseFloat', 'Infinity', 'NaN',
  'BigInt', 'AbortController', 'AbortSignal', 'MessageChannel', 'MessagePort',
]) {
  if (typeof globalThis[k] !== 'undefined') sandbox[k] = globalThis[k];
}
sandbox.Buffer = Buffer;
sandbox.performance = globalThis.performance;

vm.createContext(sandbox);
const src = fs.readFileSync('./webmssdk.js', 'utf8');
vm.runInContext(src, sandbox, { filename: 'webmssdk.js' });
console.log('=== loaded, 测试 frontierSign ===');

const testUrl = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
try {
  const r = vm.runInContext(`(async () => {
    const url = ${JSON.stringify(testUrl)};
    const out = { url };
    try {
      const r = await window.byted_acrawler.frontierSign(url);
      out.result = r;
    } catch (e) { out.err = String(e).slice(0, 500); }
    return JSON.stringify(out);
  })()`, sandbox);
  Promise.resolve(r).then(v => console.log('RESULT:', v)).catch(e => console.log('PROMISE ERR:', String(e)));
} catch (e) {
  console.log('CALL ERROR:', e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : String(e));
}
