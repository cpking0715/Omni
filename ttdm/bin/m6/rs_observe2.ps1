# rs_observe2.ps1 — js-reverse Observe: 检查页面已发 im-api 请求的 URL 形态 (X-Gnarly/X-Dynosaur 附加点)
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

$expr = @'
(() => {
  const entries = performance.getEntriesByType('resource');
  const hits = entries
    .map(e => e.name)
    .filter(n => /im-api|im\.tiktok|message|chat/i.test(n));
  const out = { total: entries.length, hits: hits.slice(0, 30) };
  // 也检查 window 上的签名相关全局/类
  const globals = [];
  for (const k in window) { if (/msToken|ttwid|msdk|secsdk|sign|guard/i.test(k)) globals.push(k); }
  out.globals = globals.slice(0, 40);
  return JSON.stringify(out);
})()
'@

$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== Observe2: resource timing 中的 im-api 请求 ==="
if ($resp.result.result.value) { Write-Host $resp.result.result.value } else { Write-Host ($resp | ConvertTo-Json -Compress -Depth 6) }
$ws.Dispose()
