# M6-4 验证: 重放 message/send (复用捕获的签名 URL + body + cookie) → 判断签名可复用性
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
# 1. 提取捕获的完整 URL (send_body.txt PAGE HOOK 段)
$content = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\send_body.txt" -Raw
$m = [regex]::Match($content, 'XHR (https://im-api\.tiktok\.com/v1/message/send\?[^\s"]+)')
$url = $m.Groups[1].Value
Write-Host "URL len: $($url.Length)"
# 2. 提取 body b64
$idx = $content.IndexOf("=== GETREQUESTPOSTDATA ===")
$b64 = $content.Substring($idx + "=== GETREQUESTPOSTDATA ===".Length).Trim()
$body = [Convert]::FromBase64String($b64)
Write-Host "body len: $($body.Length)"
# 3. CDP 获取 tiktok.com cookie
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
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us") {
        $cookies += "$($c.name)=$($c.value)"
    }
}
$cookieStr = $cookies -join "; "
Write-Host "cookie count: $($cookies.Count) (len $($cookieStr.Length))"
$ws.Dispose()
# 4. 发送重放
$headers = @{
    "Content-Type" = "application/x-protobuf"
    "Cookie" = $cookieStr
    "Origin" = "https://www.tiktok.com"
    "Referer" = "https://www.tiktok.com/messages"
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
}
try {
    $r = Invoke-WebRequest -Method POST -Uri $url -Body $body -Headers $headers -UseBasicParsing -TimeoutSec 30
    Write-Host "=== RESP: $($r.StatusCode) ==="
    Write-Host "body: $($r.Content)"
} catch {
    $ex = $_.Exception
    if ($ex.Response) {
        $code = [int]$ex.Response.StatusCode
        Write-Host "=== RESP: $code ==="
        try {
            $sr = [IO.StreamReader]::new($ex.Response.GetResponseStream())
            Write-Host "body: $($sr.ReadToEnd())"
        } catch { }
    } else {
        Write-Host "=== ERROR: $($ex.Message) ==="
    }
}
