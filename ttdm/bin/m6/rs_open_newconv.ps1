# rs_open_newconv.ps1 — 搜索并打开 royyen 主号新会话, 检查 UI 发送链路可用性
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_opennewconv.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 60000) {
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
# hook 网络拿 UI 发送请求
$hookExpr = @'
(() => {
  if (window.__uiNet) return 'already';
  window.__uiNet = [];
  const push = (k, u) => { if (window.__uiNet.length > 60) window.__uiNet.shift(); window.__uiNet.push(k + '|' + String(u).slice(0, 600)); };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (String(u).includes('im-api') || String(u).includes('message/send')) push('F', u);
    return of.apply(this, args);
  };
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    if (String(u).includes('im-api') || String(u).includes('message/send')) push('X', u);
    return oo.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 搜索框输入并触发搜索, 等待建议出现
$expr1 = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'royyen');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 3500));
  // 列出所有可点击的建议项 (含头像 img 的 li/div)
  const sugg = [];
  document.querySelectorAll('li, [role="option"], [data-e2e*="sug"], [data-e2e*="search"]').forEach(el => {
    const hasAvatar = !!el.querySelector('img');
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    if ((hasAvatar || /royyen/.test(txt)) && txt && txt.length < 80) {
      sugg.push({ e2e: (el.getAttribute('data-e2e')||'').slice(0,50), txt });
    }
  });
  out.sugg = sugg.slice(0, 15);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr1; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'sugg: ' + $r1.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
