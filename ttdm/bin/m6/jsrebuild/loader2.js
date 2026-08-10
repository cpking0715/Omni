// loader2.js — js-reverse Rebuild 第2步: vm.runInThisContext 执行 webmssdk.js (绕过 UMD CJS 分支)
// 原理: require() 会让内部 UMD 走 exports 分支 (dwInfl 不挂全局); vm 执行则走 globalThis 分支
'use strict';
const fs = require('fs');
const vm = require('vm');

// 最小浏览器全局 (逐步补; Node 24 内置只读 navigator, 需 defineProperty 覆盖)
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.top = globalThis;
globalThis.parent = globalThis;
const nav = {
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
  platform: 'Win32',
  language: 'en-US',
  languages: ['en-US'],
  maxTouchPoints: 0,
  webdriver: false,
};
Object.defineProperty(globalThis, 'navigator', { value: nav, configurable: true, writable: true });
globalThis.location = {
  href: 'https://www.tiktok.com/messages?lang=en',
  protocol: 'https:',
  host: 'www.tiktok.com',
  hostname: 'www.tiktok.com',
  pathname: '/messages',
  search: '?lang=en',
  origin: 'https://www.tiktok.com',
};
globalThis.document = {
  cookie: '',
  referrer: '',
  title: 'TikTok',
  readyState: 'complete',
  createElement: () => ({ style: {}, setAttribute() {}, getContext: () => null }),
  getElementById: () => null,
  querySelector: () => null,
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent: (e) => { console.log('[stub] document.dispatchEvent', e && e.type); return true; },
  documentElement: { style: {}, clientWidth: 1707, clientHeight: 1067 },
  body: { style: {}, clientWidth: 1707, clientHeight: 1067 },
  hidden: false,
  visibilityState: 'visible',
};
globalThis.screen = { width: 1707, height: 1067, availWidth: 1707, availHeight: 1067, colorDepth: 24, pixelDepth: 24 };
globalThis.history = { length: 14 };

const src = fs.readFileSync('./webmssdk.js', 'utf8');
try {
  vm.runInThisContext(src, { filename: 'webmssdk.js' });
  console.log('=== loaded OK ===');
  console.log('byted_acrawler:', typeof globalThis.byted_acrawler);
  if (globalThis.byted_acrawler) console.log('keys:', Object.keys(globalThis.byted_acrawler).join(','));
  console.log('dwInfl:', typeof globalThis.dwInfl);
} catch (e) {
  console.log('=== LOAD ERROR ===');
  console.log(e && e.stack ? e.stack.split('\n').slice(0, 10).join('\n') : String(e));
}
