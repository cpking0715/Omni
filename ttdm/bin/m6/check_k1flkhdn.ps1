# 检查 k1flkhdn 浏览器 TikTok 登录态 (CDP 只读检查, 不发送任何消息)
param(
    [int]$Port = 57466
)
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
if (-not $wsUrl) { Write-Host "NO_TIKTOK_PAGE"; exit 1 }

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
$ck = @{}
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok") { $ck[$c.name] = $c }
}
Write-Host ("COOKIE_COUNT=" + $ck.Count)
foreach ($name in @("sessionid","sessionid_ss","ttwid","uid_tt","sid_tt","passport_csrf_token","msToken","odin_tt","sid_guard")) {
    if ($ck.ContainsKey($name)) {
        $v = $ck[$name].value
        $short = if ($v.Length -gt 24) { $v.Substring(0,24) + "..." } else { $v }
        Write-Host ("  {0} = {1} (len={2})" -f $name, $short, $v.Length)
    } else {
        Write-Host ("  {0} = MISSING" -f $name)
    }
}
# 通过 tiktok api 探测登录 uid (只读 GET)
$uid = $null
try {
    $r = Invoke-WebRequest -Uri "https://www.tiktok.com/passport/web/account/info/" -Headers @{ "Cookie" = ($ck.Values | ForEach-Object { "$($_.name)=$($_.value)" }) -join "; " } -TimeoutSec 15 -UseBasicParsing
    $uid = $r.Content
    Write-Host ("ACCOUNT_INFO_RESP: " + $uid.Substring(0, [Math]::Min(200, $uid.Length)))
} catch {
    Write-Host "ACCOUNT_INFO_FAIL: $($_.Exception.Message)"
}
$ws.Dispose()
