# 对照实验: 原始格式 URL (未转义签名) + Go 构造 body → 判断 204 是否由 URL 编码引起
$goExe = "$env:LOCALAPPDATA\Programs\Go\go\bin\go.exe"
# 1. 提取 CDP 段原始 URL (去掉尾部 " status=...")
$content = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\send_body.txt" -Raw
$cdp = $content.Substring($content.IndexOf("=== CDP NETWORK EVENTS ==="))
$lines = $cdp -split "`n"
$url = ""
foreach ($line in $lines) {
    if ($line -match 'url=(https://im-api\.tiktok\.com/v1/message/send\?.*?)(\s+status=.*)?$') {
        $url = $Matches[1].Trim()
        break
    }
}
Write-Host "URL len: $($url.Length)"
# 2. 生成 Go body b64 (用已编译 exe,避免 go run stderr 混杂)
$bodyB64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" "probe11 - raw url test"
$body = [Convert]::FromBase64String($bodyB64.Trim())
if ($body.Length -lt 100) { Write-Host "FATAL: body too short ($($body.Length))"; exit 1 }
Write-Host "Go body len: $($body.Length)"
# 3. Cookie
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=k1fan6kh" -Headers @{Authorization = "Bearer $key"}
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
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us") {
        $cookies += "$($c.name)=$($c.value)"
    }
}
$cookieStr = $cookies -join "; "
$ws.Dispose()
Write-Host "cookie count: $($cookies.Count)"
# 4. 发送 (原始 URL + Go body)
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
    $bytes = $r.Content
    if ($bytes -is [byte[]]) {
        $b64 = [Convert]::ToBase64String($bytes)
        [IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\resp_rawurl.b64", $b64, [System.Text.Encoding]::ASCII)
        Write-Host "body b64 len: $($b64.Length) saved"
    } else {
        Write-Host "body: $($r.Content)"
    }
} catch {
    $ex = $_.Exception
    if ($ex.Response) {
        $code = [int]$ex.Response.StatusCode
        Write-Host "=== RESP: $code ==="
        try {
            $sr = [IO.StreamReader]::new($ex.Response.GetResponseStream())
            $c = $sr.ReadToEnd()
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c))
            [IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\resp_rawurl.b64", $b64, [System.Text.Encoding]::ASCII)
            Write-Host "body: $($c)"
        } catch { }
    } else {
        Write-Host "=== ERROR: $($ex.Message) ==="
    }
}
