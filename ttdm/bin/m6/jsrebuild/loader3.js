// loader3.js — js-reverse Rebuild 第3步: 干净沙箱加载 webmssdk.js (环境指纹对齐浏览器)
// 指纹: window=2 global=1 require=1 module=1 Buffer=2 __dirname=1 => "211121" (与真实浏览器一致)
'use strict';
const fs = require('fs');
const vm = require('vm');

const sandbox = {};
// 浏览器身份全局
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.top = sandbox;
sandbox.parent = sandbox;
sandbox.globalThis = sandbox;
// 浏览器 API stub (指纹对齐)
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

// Node 提供的语言/运行时能力 (沙箱默认没有, 逐一注入)
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
// 明确不注入: process / require / module / __dirname / global (指纹要求)

vm.createContext(sandbox);
const src = fs.readFileSync('./webmssdk.js', 'utf8');
try {
  vm.runInContext(src, sandbox, { filename: 'webmssdk.js' });
  console.log('=== loaded OK ===');
  console.log('byted_acrawler:', typeof sandbox.byted_acrawler);
  if (sandbox.byted_acrawler) console.log('keys:', Object.keys(sandbox.byted_acrawler).join(','));
  console.log('dwInfl:', typeof sandbox.dwInfl);
} catch (e) {
  console.log('=== LOAD ERROR ===');
  console.log(e && e.stack ? e.stack.split('\n').slice(0, 10).join('\n') : String(e));
}
