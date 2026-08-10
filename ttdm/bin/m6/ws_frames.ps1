# CDP 层级 WS 帧捕获: Go 发送 probe9, 观察页面 WS 是否收到新消息推送
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
$script:wsFrames = @()
$script:collecting = $false
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
        if ($script:collecting -and $msg.method -eq "Network.webSocketFrameReceived") {
            $payload = $msg.params.response.payloadData
            $script:wsFrames += $payload
        }
        if ($script:collecting -and $msg.method -eq "Network.webSocketFrameSent") {
            $script:wsFrames += "SENT: " + $msg.params.response.payloadData
        }
    }
    return $null
}
Invoke-Cdp $ws 1 "Network.enable" -timeoutMs 5000 | Out-Null
$script:collecting = $true
# Go 发送 probe10 (后台任务, 与 WS 帧收集并行)
Write-Host "=== 发送 probe10 (后台) ==="
$sendJob = Start-Job -ScriptBlock {
    cd "d:\MyProjects\OmniMarket\ttdm"
    & "$env:LOCALAPPDATA\Programs\Go\go\bin\go.exe" run ".\cmd\websend" "d:\MyProjects\OmniMarket\ttdm\bin\m6\sign_snapshot.json" "d:\MyProjects\OmniMarket\ttdm\bin\m6\account.json" "probe10 - ws frame collect"
} 
# 收集 20 秒 WS 帧 (dummy 请求循环)
Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = '1' } -timeoutMs 20000 | Out-Null
$script:collecting = $false
$sendResult = Receive-Job $sendJob -Wait -AutoRemoveJob
Write-Host $sendResult
$out = "=== WS frames ($($script:wsFrames.Count)) ===`n"
$probeHits = 0
foreach ($f in $script:wsFrames) {
    $isProbe = $f -match "probe"
    if ($isProbe) { $probeHits++ }
    $out += "[$($f.Length)] $($f.Substring(0, [Math]::Min(500, $f.Length)))`n"
    Write-Host "[$($f.Length)] $($f.Substring(0, [Math]::Min(300, $f.Length)))"
}
[IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\ws_frames.txt", $out, [System.Text.Encoding]::UTF8)
Write-Host "=== probe 命中: $probeHits ==="
$ws.Dispose()
