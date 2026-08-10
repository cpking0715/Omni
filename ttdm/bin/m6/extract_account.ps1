# 从 AdsPower 浏览器提取 tiktok cookie → account.json (M6-4 真实发送验证用)
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\account.json"
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
    $buf = New-Object byte[] 1048576
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
$resp = Invoke-Cdp $ws 1 "Network.getAllCookies" $null
$cookies = @()
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us|im-api\.tiktok\.com|mssdk") {
        $cookies += @{
            name = $c.name; value = $c.value; domain = $c.domain
            path = $c.path; httpOnly = $c.httpOnly; secure = $c.secure; sameSite = $c.sameSite
        }
    }
}
$acct = @{
    uid = 7664958044560016398        # 真实 self uid (来自 WS 推送帧 conversation_id)
    device_id = "7669334412366218765" # 真实 device id (来自 ttwid)
    cookies = $cookies
}
$json = $acct | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "account.json: $($cookies.Count) cookies -> $outFile"
Write-Host "uid=7664958044560016398 device_id=7669334412366218765"
$ws.Dispose()
