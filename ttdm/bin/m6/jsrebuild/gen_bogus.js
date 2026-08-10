'use strict';
const fs = require('fs');
const vm = require('vm');
const sandbox = {};
sandbox.window = sandbox; sandbox.self = sandbox; sandbox.top = sandbox; sandbox.parent = sandbox; sandbox.globalThis = sandbox;
sandbox.navigator = { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36', platform: 'Win32', language: 'en-US', languages: ['en-US'], maxTouchPoints: 0, webdriver: false };
sandbox.location = { href: 'https://www.tiktok.com/messages?lang=en', protocol: 'https:', host: 'www.tiktok.com', hostname: 'www.tiktok.com', pathname: '/messages', search: '?lang=en', origin: 'https://www.tiktok.com' };
sandbox.document = { cookie: '', referrer: '', title: 'TikTok', readyState: 'complete', createElement: () => ({ style: {}, setAttribute() {}, getContext: () => null }), getElementById: () => null, querySelector: () => null, addEventListener() {}, removeEventListener() {}, dispatchEvent: () => true, documentElement: { style: {} }, body: { style: {} }, hidden: false, visibilityState: 'visible' };
sandbox.screen = { width: 1707, height: 1067, colorDepth: 24, pixelDepth: 24 };
sandbox.history = { length: 14 };
for (const k of ['Uint8Array','Uint16Array','Uint32Array','Int8Array','Int16Array','Int32Array','Float32Array','Float64Array','ArrayBuffer','SharedArrayBuffer','DataView','TextEncoder','TextDecoder','crypto','setTimeout','clearTimeout','setInterval','clearInterval','queueMicrotask','console','fetch','Headers','Request','Response','URL','URLSearchParams','Event','Error','TypeError','RangeError','SyntaxError','Date','Math','JSON','Object','Array','String','Number','Boolean','RegExp','Promise','Symbol','Map','Set','WeakMap','WeakSet','Proxy','Reflect','atob','btoa','isNaN','parseInt','parseFloat','Infinity','NaN','BigInt','AbortController','AbortSignal','MessageChannel','MessagePort']) { if (typeof globalThis[k] !== 'undefined') sandbox[k] = globalThis[k]; }
sandbox.Buffer = Buffer;
sandbox.performance = globalThis.performance;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync('./webmssdk.js', 'utf8'), sandbox, { filename: 'webmssdk.js' });
const r = vm.runInContext(`(async () => {
  const u = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const r = await window.byted_acrawler.frontierSign(u);
  return JSON.stringify(r);
})()`, sandbox);
Promise.resolve(r).then(v => { fs.writeFileSync('out_bogus.txt', v); console.log('bogus:', v); });
