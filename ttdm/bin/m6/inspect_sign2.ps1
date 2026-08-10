# 探测 byted_acrawler.frontierSign 的调用方式与输出
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 65536
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
# 1. 函数源码概览 (前 800 字符, 看参数解构)
$expr1 = @'
(() => {
  const src = String(window.byted_acrawler.frontierSign);
  return 'len=' + src.length + '\nHEAD: ' + src.slice(0, 1200);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
Write-Host "=== frontierSign 源码概览 ==="
Write-Host $resp.result.result.value
# 2. 尝试调用: 方案 A - 传 URL 字符串
$expr2 = @'
(async () => {
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const results = {};
  try {
    const r = await window.byted_acrawler.frontierSign(url);
    results.modeA_string = (typeof r === 'string' ? r : JSON.stringify(r)).slice(0, 600);
  } catch (e) { results.modeA_err = String(e).slice(0, 300); }
  try {
    const r = await window.byted_acrawler.frontierSign({url: url, method: 'POST'});
    results.modeB_obj = (typeof r === 'string' ? r : JSON.stringify(r)).slice(0, 600);
  } catch (e) { results.modeB_err = String(e).slice(0, 300); }
  return JSON.stringify(results);
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; awaitPromise = $true; returnByValue = $true }
Write-Host "=== frontierSign 调用尝试 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
