# 刷新 messages 页面, 捕获会话列表/消息历史 API 的真实响应, 验证 probe7 是否在服务端
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\inbox_capture.txt"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$script:netReqs = @()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 30000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
        if ($msg.method -eq "Network.requestWillBeSent" -and $msg.params.request.url -match "im-api|message|conversation|tray|/im/") {
            $script:netReqs += @{ requestId = $msg.params.requestId; url = $msg.params.request.url; method = $msg.params.request.method }
        }
        if ($msg.method -eq "Network.responseReceived" -and $msg.params.response.url -match "im-api|message|conversation|tray|/im/") {
            $script:netReqs += @{ requestId = $msg.params.requestId; url = $msg.params.response.url; status = $msg.params.response.status }
        }
    }
    return $null
}
# 1. 启用 Network
Invoke-Cdp $ws 1 "Network.enable" -timeoutMs 5000 | Out-Null
# 2. 刷新页面
Invoke-Cdp $ws 2 "Page.reload" @{ ignoreCache = $true } -timeoutMs 5000 | Out-Null
Write-Host "reloading..."
Start-Sleep -Seconds 12
# 3. 收集响应体
$out = ""
$seen = @{}
$probeHits = @()
foreach ($nr in $script:netReqs) {
    $u = $nr.url
    if (-not $u) { continue }
    if ($nr.requestId -and -not $seen.ContainsKey($nr.requestId)) {
        $seen[$nr.requestId] = $true
        try {
            $pr = Invoke-Cdp $ws 3 "Network.getResponseBody" @{ requestId = $nr.requestId } -timeoutMs 10000
            $body = $pr.result.body
            if ($body) {
                $hasProbe = $body -match "probe"
                $line = "req=$($nr.requestId) status=$($nr.status) method=$($nr.method) hasProbe=$hasProbe url=$u`nBODY($($body.Length)): $($body.Substring(0, [Math]::Min(800, $body.Length)))`n"
                $out += $line + "`n"
                if ($hasProbe) { $probeHits += "req=$($nr.requestId) url=$u" }
            } else {
                $out += "req=$($nr.requestId) status=$($nr.status) url=$u -> NO BODY`n"
            }
        } catch {
            $out += "req=$($nr.requestId) status=$($nr.status) url=$u -> ERR`n"
        }
    }
}
[IO.File]::WriteAllText($outFile, $out, [System.Text.Encoding]::UTF8)
Write-Host "=== probe 命中 ==="
if ($probeHits.Count -eq 0) { Write-Host "(none)" }
foreach ($h in $probeHits) { Write-Host $h }
Write-Host "=== 请求列表 ==="
foreach ($nr in $script:netReqs) { Write-Host "status=$($nr.status) method=$($nr.method) $($nr.url.Substring(0, [Math]::Min(140, $nr.url.Length)))" }
Write-Host "saved -> $outFile"
$ws.Dispose()
