# rs_combo_probe2.ps1 — 搜索未联系用户 "tiktok", 抓 get_by_user_combo 完整 URL+响应 (uid/conv_id)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_combo2.json"
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
$hookExpr = @'
(() => {
  if (window.__combo2) return 'already';
  window.__combo2 = [];
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) {
    this.__u2 = u;
    return oo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    this.addEventListener('load', () => {
      const u = String(this.__u2 || '');
      if (u.includes('get_by_user_combo')) {
        window.__combo2.push({ url: u.slice(0, 1500), len: (this.responseText||'').length, head: (this.responseText||'').slice(0, 4000) });
        if (window.__combo2.length > 8) window.__combo2.shift();
      }
    });
    return os.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

$expr = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'tiktok');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 5000));
  // 也尝试按下回车
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
  input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
  await new Promise(r => setTimeout(r, 4000));
  out.comboCount = (window.__combo2 || []).length;
  // 读搜索结果 DOM (搜索建议列表)
  const sugg = [];
  document.querySelectorAll('[role="option"], [data-e2e*="search"], li').forEach(el => {
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 70);
    const e2e = el.getAttribute('data-e2e') || '';
    if (txt && (e2e.includes('search') || el.querySelector('img, [data-e2e*="avatar"]'))) {
      sugg.push({ e2e: e2e.slice(0, 50), txt: txt.slice(0, 70) });
    }
  });
  out.sugg = sugg.slice(0, 10);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 40000 }
$log += 'typed: ' + $r1.result.result.value

$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__combo2 || [])'; returnByValue = $true }
$log += 'combo: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
