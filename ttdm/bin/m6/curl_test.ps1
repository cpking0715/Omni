# 对照实验: curl http1.1 vs http2 (原始 URL + Go body) → 判断 204 是否由 HTTP/2 引起
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
# 1. 提取原始 URL
$content = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\send_body.txt" -Raw
$cdp = $content.Substring($content.IndexOf("=== CDP NETWORK EVENTS ==="))
foreach ($line in ($cdp -split "`n")) {
    if ($line -match 'url=(https://im-api\.tiktok\.com/v1/message/send\?.*?)(\s+status=.*)?$') {
        $url = $Matches[1].Trim()
        break
    }
}
Write-Host "URL len: $($url.Length)"
# 2. 生成 body
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" "probe14 - curl version test"
$body = [Convert]::FromBase64String($b64.Trim())
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\body14.bin", $body)
Write-Host "body len: $($body.Length)"
# 3. cookies
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=k1fan6kh" -Headers @{Authorization = "Bearer $key"}
$port = [int]$start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = ($targets | Where-Object { $_.type -eq "page" -and $_.url -match "tiktok\.com" } | Select-Object -First 1).webSocketDebuggerUrl
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$req = @{ id = 1; method = "Network.getAllCookies" } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($req)
$ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$buf = New-Object byte[] 2097152
$ms = [System.IO.MemoryStream]::new()
do {
    $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $ms.Write($buf, 0, $r.Count)
} while (-not $r.EndOfMessage)
$resp = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
$ws.Dispose()
$cookies = @()
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us") {
        $cookies += "$($c.name)=$($c.value)"
    }
}
$cookieStr = $cookies -join "; "
Write-Host "cookie count: $($cookies.Count)"
# 4. curl 发送
$args = @(
    "-s", "-i", "-X", "POST", $url,
    "-H", "Content-Type: application/x-protobuf",
    "-H", "Cookie: $cookieStr",
    "-H", "Origin: https://www.tiktok.com",
    "-H", "Referer: https://www.tiktok.com/messages",
    "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
    "--data-binary", "@d:\MyProjects\OmniMarket\ttdm\bin\m6\body14.bin"
)
foreach ($ver in @("--http1.1", "--http2")) {
    Write-Host "`n===== curl $ver ====="
    $out = & curl.exe @args $ver 2>&1
    $out | Select-Object -First 12
}
