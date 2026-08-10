# rs_capture2.ps1 — js-reverse Capture: 浏览器侧深挖签名拦截层 (X-Gnarly/X-Dynosaur 生成点)
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}

# 1) byted_acrawler 各方法的 VM 存根 + fetch/XHR 是否被包装
$expr1 = @'
(() => {
  const out = {};
  const ac = window.byted_acrawler;
  const fns = {};
  for (const k of Object.keys(ac)) {
    if (typeof ac[k] === 'function') {
      const s = ac[k].toString();
      const m = s.match(/F\((\d+),t,this,arguments,0,(\d+)\)/);
      fns[k] = m ? 'F(' + m[1] + ',' + m[2] + ')' : s.slice(0, 80);
    } else fns[k] = typeof ac[k];
  }
  out.acrawler = fns;
  out.fetchIsNative = window.fetch.toString().slice(0, 120);
  out.xhrOpenIsNative = XMLHttpRequest.prototype.open.toString().slice(0, 120);
  out.xhrSendIsNative = XMLHttpRequest.prototype.send.toString().slice(0, 120);
  // __bytedImCallTrace 是什么
  out.imCallTrace = typeof window.__bytedImCallTrace;
  return JSON.stringify(out);
})()
'@
$resp1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
Write-Host "=== Capture2.1: 签名入口存根与拦截层 ==="
if ($resp1.result.result.value) { Write-Host $resp1.result.result.value } else { Write-Host ($resp1 | ConvertTo-Json -Compress -Depth 6) }

# 2) hook fetch 记录带签名的请求 + 调用栈 (触发一次页面请求: 刷新 conversations 列表)
$expr2 = @'
(() => {
  window.__rsHooked = [];
  const origFetch = window.fetch.bind(window);
  window.fetch = (...args) => {
    let url = '';
    try { url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || String(args[0]); } catch (e) {}
    if (/X-Dynosaur|X-Gnarly/.test(url)) {
      window.__rsHooked.push({ url: url.slice(0, 3000), stack: new Error().stack.split('\n').slice(1, 8).join(' | ') });
    }
    return origFetch(...args);
  };
  // 同时 hook XHR
  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    try { if (/X-Dynosaur|X-Gnarly/.test(String(u))) window.__rsHooked.push({ url: String(u).slice(0, 3000), xhr: true, stack: new Error().stack.split('\n').slice(1, 8).join(' | ') }); } catch (e) {}
    return origOpen.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$resp2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
Write-Host "=== Capture2.2: hook 已注入 ==="
Write-Host $resp2.result.result.value
$ws.Dispose()
