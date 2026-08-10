# rs_search_user.ps1 — 页面搜索框搜用户, 拿搜索结果结构与 uid (为无签名第1条验证找新接收方)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_search.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 45000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 2097152
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
    return $null
}
$log = @()

# 1. hook 网络(拿搜索请求里的 uid)
$hookExpr = @'
(() => {
  if (window.__searchLog) return 'already';
  window.__searchLog = [];
  const push = u => { if (window.__searchLog.length > 50) window.__searchLog.shift(); window.__searchLog.push(String(u).slice(0, 500)); };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (String(u).includes('search') || String(u).includes('sug') || String(u).includes('user')) push('F|' + u);
    return of.apply(this, args);
  };
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    if (String(u).includes('search') || String(u).includes('sug') || String(u).includes('user')) push('X|' + u);
    return oo.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 2. 聚焦搜索框并输入关键字 (输入 royyen 已存在用户, 验证搜索链路)
$expr = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  input.value = '';
  // React 受控组件: 用原生 setter + input 事件
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'royyen');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  input.dispatchEvent(new Event('change', { bubbles: true }));
  await new Promise(r => setTimeout(r, 3000));
  // 读取搜索结果 DOM
  const results = [];
  document.querySelectorAll('[data-e2e], [role="option"], li, a').forEach(el => {
    const e2e = el.getAttribute('data-e2e') || '';
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    if ((e2e && /user|search|result|sug/i.test(e2e)) || (txt.includes('royyen') && txt.length < 80)) {
      results.push({ e2e, txt, href: (el.getAttribute('href') || '').slice(0, 100) });
    }
  });
  out.results = results.slice(0, 12);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'search: ' + $r1.result.result.value

$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__searchLog || [])'; returnByValue = $true }
$log += 'net: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
