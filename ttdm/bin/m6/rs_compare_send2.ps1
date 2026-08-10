# rs_compare_send2.ps1 — js-reverse Patch: 空 meta 对照实验 (meta 是否必需)
# D: 空meta + 无签名   E: 空meta + 快照签名   对照 A(有meta+无签名)=7193
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_compare_send2.json"
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$text = "rs-meta-test"

$results = @()

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
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}
$resp = Invoke-Cdp $ws 1 "Network.getAllCookies" $null
$cookies = @()
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us") { $cookies += "$($c.name)=$($c.value)" }
}
$cookieStr = $cookies -join "; "
$ws.Dispose()

# 空 meta body
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" -empty $text
$bodyEmpty = [Convert]::FromBase64String($b64.Trim())
# 有 meta body
$b64b = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" $text
$bodyMeta = [Convert]::FromBase64String($b64b.Trim())
Write-Host "body empty len: $($bodyEmpty.Length), meta len: $($bodyMeta.Length)"

$snap = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\sign_snapshot.json" -Raw | ConvertFrom-Json
$base = "https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc"
$signed = "$base&X-Dynosaur=$($snap.sign.x_dynosaur)&msToken=$($snap.sign.ms_token)&X-Bogus=1&X-Gnarly=$($snap.sign.x_gnarly)"

$headers = @{
    "Content-Type" = "application/x-protobuf"
    "Cookie" = $cookieStr
    "Origin" = "https://www.tiktok.com"
    "Referer" = "https://www.tiktok.com/messages"
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
}

$variants = @(
    @{ name = "D_emptymeta_nosign"; url = $base; body = $bodyEmpty },
    @{ name = "E_emptymeta_signed"; url = $signed; body = $bodyEmpty },
    @{ name = "F_meta_nosign"; url = $base; body = $bodyMeta }
)
foreach ($v in $variants) {
    $entry = @{ name = $v.name }
    try {
        $r = Invoke-WebRequest -Method POST -Uri $v.url -Body $v.body -Headers $headers -UseBasicParsing -TimeoutSec 30
        $entry.status = $r.StatusCode
        $content = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        # 提取 protobuf 内 JSON (status_code)
        if ($content -match '\{"status_code":(\d+)') { $entry.biz_code = [int]$Matches[1] }
        if ($content -match '"tips":"([^"]{0,80})') { $entry.tips = $Matches[1] }
        $entry.bodylen = $content.Length
    } catch {
        $ex = $_.Exception
        if ($ex.Response) {
            $entry.status = [int]$ex.Response.StatusCode
        } else {
            $entry.status = -1
            $entry.err = $ex.Message
        }
    }
    $results += $entry
    Write-Host ("{0}: HTTP {1} biz={2}" -f $entry.name, $entry.status, $entry.biz_code)
    Start-Sleep -Seconds 2
}

$result = @{ variants = $results }
$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
