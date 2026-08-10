# rs_capture4.ps1 — js-reverse Capture: 签名层之下 hook + CDP Network 事件对照采样
# 方法: addScriptToEvaluateOnNewDocument 在 webmssdk 之前注入 hook → hook 位于拦截层之下
#       同时 Network.enable 采集 requestWillBeSent (最终 URL + initiator 栈)
$ErrorActionPreference = 'Stop'
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture4.json"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

$hookSrc = @'
(() => {
  window.__rsHookLog = [];
  const rec = (kind, url, body) => {
    try {
      window.__rsHookLog.push({
        kind, url: String(url).slice(0, 1500),
        body: body ? String(body).slice(0, 300) : '',
        stack: new Error().stack.split('\n').slice(1, 6).join(' | ')
      });
      if (window.__rsHookLog.length > 300) window.__rsHookLog.splice(0, 150);
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
})();
'@

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

# 事件收集: 只保留 im-api 请求的最终 URL + initiator
$script:netEvents = New-Object System.Collections.ArrayList
$netCollector = {
    param($msg)
    if ($msg.method -eq 'Network.requestWillBeSent') {
        $u = $msg.params.request.url
        if ($u -match 'im-api|X-Bogus|X-Dynosaur|X-Gnarly') {
            $stack = ''
            if ($msg.params.initiator -and $msg.params.initiator.stack -and $msg.params.initiator.stack.callFrames) {
                $stack = (($msg.params.initiator.stack.callFrames | Select-Object -First 6 | ForEach-Object { $_.functionName }) -join ' <- ')
            }
            [void]$script:netEvents.Add(@{ url = $u; stack = $stack })
        }
    }
}

# 1) Network + 注入 hook + reload
Invoke-Cdp $ws 1 "Network.enable" $null
$null = Read-UntilId $ws 1 $null
Invoke-Cdp $ws 2 "Page.addScriptToEvaluateOnNewDocument" @{ source = $hookSrc }
$null = Read-UntilId $ws 2 $null
Invoke-Cdp $ws 3 "Page.reload" @{ ignoreCache = $true }
$null = Read-UntilId $ws 3 $netCollector

# 2) reload 后 10 秒内的请求事件
$cts = [System.Threading.CancellationTokenSource]::new(10000)
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
} catch [System.OperationCanceledException] {
    # 超时结束
}

# 3) 读 hook log (页面上下文)
$expr = @'
(() => {
  const arr = window.__rsHookLog || [];
  const out = [];
  for (const h of arr) {
    if (/im-api|X-Bogus|X-Dynosaur|X-Gnarly/.test(h.url)) out.push(h);
  }
  return JSON.stringify(out.slice(-12));
})()
'@
Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$resp4 = Read-UntilId $ws 4 $netCollector
$hookLog = @()
if ($resp4.result.result.value) { $hookLog = $resp4.result.result.value | ConvertFrom-Json }
$ws.Dispose()

$result = @{
    hook_log = $hookLog
    network_im_api = @($script:netEvents | Select-Object -Last 15)
}
$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile (netEvents=$($script:netEvents.Count))"
