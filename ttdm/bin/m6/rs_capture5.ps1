# rs_capture5.ps1 — js-reverse Capture v3: 短连接容错 + 页面内自记录 (hook log + resource timing 对照)
# 结论判定: hook 看到的业务层 URL vs resource timing 的最终 URL (浏览器记录, 带签名)
$ErrorActionPreference = 'Stop'
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture5.json"

function New-Cdp($wsUrl) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $null = $ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $ws
}
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
function Read-UntilId($ws, [int]$targetId) {
    $buf = New-Object byte[] 524288
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $targetId) { return $msg }
    }
}

$log = @()

# 步骤 0: reload 清理所有旧 hook (连接断开无妨)
try {
    $ws0 = New-Cdp $wsUrl
    Invoke-Cdp $ws0 1 "Runtime.evaluate" @{ expression = 'location.reload(); "reloading"'; returnByValue = $true }
    $null = Read-UntilId $ws0 1
    $ws0.Dispose()
    $log += 'step0 reload sent'
} catch { $log += 'step0 failed: ' + $_.Exception.Message }
Start-Sleep -Seconds 10

# 步骤 1: 注入干净 hook
try {
    $ws1 = New-Cdp $wsUrl
    $hookExpr = @'
(() => {
  window.__rsHookLog3 = [];
  const rec = (kind, url, body) => {
    try {
      window.__rsHookLog3.push({ kind, url: String(url).slice(0, 1500), body: body ? String(body).slice(0, 300) : '' });
      if (window.__rsHookLog3.length > 300) window.__rsHookLog3.splice(0, 150);
    } catch (e) {}
  };
  const of = window.fetch;
  window.fetch = function (...args) {
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || String(args[0]);
    rec('fetch', url, args[1] && args[1].body);
    return of.apply(this, args);
  };
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) { rec('xhr', u); return oo.apply(this, arguments); };
  return 'hooked';
})()
'@
    Invoke-Cdp $ws1 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
    $r1 = Read-UntilId $ws1 1
    $log += 'step1 hook: ' + $r1.result.result.value
    $ws1.Dispose()
} catch { $log += 'step1 failed: ' + $_.Exception.Message }

# 步骤 2: 点击会话项触发 im-api 请求
try {
    $ws2 = New-Cdp $wsUrl
    $clickExpr = @'
(() => {
  const els = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (els.length === 0) return 'no conversation items';
  els[0].click();
  return 'clicked ' + els.length + ' items, first: ' + (els[0].innerText || '').replace(/\s+/g, ' ').slice(0, 30);
})()
'@
    Invoke-Cdp $ws2 1 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
    $r2 = Read-UntilId $ws2 1
    $log += 'step2 click: ' + $r2.result.result.value
    $ws2.Dispose()
} catch { $log += 'step2 failed: ' + $_.Exception.Message }
Start-Sleep -Seconds 5

# 步骤 3: 读 hook log + resource timing
$hookLog = @()
$timings = @()
try {
    $ws3 = New-Cdp $wsUrl
    $readExpr = @'
(() => {
  const out = { hooks: [], timings: [] };
  const arr = window.__rsHookLog3 || [];
  for (const h of arr) {
    if (/im-api|X-Bogus|X-Dynosaur|X-Gnarly/.test(h.url)) out.hooks.push(h);
  }
  out.hooks = out.hooks.slice(-10);
  const entries = performance.getEntriesByType('resource');
  for (const e of entries) {
    if (e.name.indexOf('im-api') >= 0) out.timings.push({ url: e.name, dur: Math.round(e.duration) });
  }
  out.timings = out.timings.slice(-8);
  return JSON.stringify(out);
})()
'@
    Invoke-Cdp $ws3 1 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
    $r3 = Read-UntilId $ws3 1
    if ($r3.result.result.value) {
        $parsed = $r3.result.result.value | ConvertFrom-Json
        $hookLog = $parsed.hooks
        $timings = $parsed.timings
    } else { $log += 'step3 no value: ' + ($r3 | ConvertTo-Json -Compress -Depth 5) }
    $ws3.Dispose()
} catch { $log += 'step3 failed: ' + $_.Exception.Message }

$result = @{
    log = $log
    hook_business_layer = $hookLog
    resource_timing_final = $timings
}
$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
