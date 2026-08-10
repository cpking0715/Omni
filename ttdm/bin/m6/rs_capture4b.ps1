# rs_capture4b.ps1 — js-reverse Capture: 业务层 URL (hook) vs 最终 URL (Network) 对照采样
# 不 reload, 点击会话项触发 im-api 请求; 对比签名在哪个层级附加
$ErrorActionPreference = 'Stop'
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture4b.json"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Read-UntilId($ws, [int]$targetId, $collector) {
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
        if ($null -ne $collector) { & $collector $msg }
    }
}

$script:netEvents = New-Object System.Collections.ArrayList
$netCollector = {
    param($msg)
    if ($msg.method -eq 'Network.requestWillBeSent') {
        $u = $msg.params.request.url
        if ($u -match 'im-api') {
            $stack = ''
            if ($msg.params.initiator -and $msg.params.initiator.stack -and $msg.params.initiator.stack.callFrames) {
                $stack = (($msg.params.initiator.stack.callFrames | Select-Object -First 8 | ForEach-Object { $_.functionName }) -join ' <- ')
            }
            [void]$script:netEvents.Add(@{ url = $u; stack = $stack })
        }
    }
}

# 1) Network.enable
Invoke-Cdp $ws 1 "Network.enable" $null
$null = Read-UntilId $ws 1 $null

# 2) 注入 hook (当前上下文, webmssdk 之上): 记录业务层 URL
$hookExpr = @'
(() => {
  window.__rsHookLog2 = [];
  const rec = (kind, url, body) => {
    try {
      window.__rsHookLog2.push({ kind, url: String(url).slice(0, 1500), body: body ? String(body).slice(0, 300) : '', stack: new Error().stack.split('\n').slice(1, 6).join(' | ') });
      if (window.__rsHookLog2.length > 300) window.__rsHookLog2.splice(0, 150);
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
Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$resp2 = Read-UntilId $ws 2 $netCollector
Write-Host ("hook: " + $resp2.result.result.value)

# 3) 触发: 点击会话列表项 (切换会话 → 加载消息 im-api)
$clickExpr = @'
(() => {
  const els = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (els.length === 0) return 'no conversation items';
  els[0].click();
  return 'clicked ' + els.length + ' items, first: ' + (els[0].innerText || '').slice(0, 40);
})()
'@
Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$resp3 = Read-UntilId $ws 3 $netCollector
Write-Host ("click: " + $resp3.result.result.value)

# 4) 收集 6 秒请求事件
$cts = [System.Threading.CancellationTokenSource]::new(6000)
$buf2 = New-Object byte[] 524288
try {
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf2), $cts.Token).GetAwaiter().GetResult()
            $ms.Write($buf2, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        & $netCollector $msg
    }
} catch [System.OperationCanceledException] { }

# 5) 读 hook log
$readExpr = @'
(() => {
  const arr = window.__rsHookLog2 || [];
  const out = [];
  for (const h of arr) {
    if (/im-api|X-Bogus|X-Dynosaur|X-Gnarly|X-Gorgon/.test(h.url)) out.push(h);
  }
  return JSON.stringify(out.slice(-10));
})()
'@
Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
$resp4 = Read-UntilId $ws 4 $netCollector
$hookLog = @()
if ($resp4.result.result.value) { $hookLog = $resp4.result.result.value | ConvertFrom-Json }
$ws.Dispose()

$result = @{
    hook_business_layer = $hookLog
    network_final_urls = @($script:netEvents | Select-Object -Last 12)
}
$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile (netEvents=$($script:netEvents.Count))"
