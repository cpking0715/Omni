# 从 k1flkhdn 浏览器提取 tiktok cookie → account_k1flkhdn.json (端到端测试用)
# 注意: k1flkhdn (tiktok-2) 与 k1fan6kh (tiktok) 是两个不同浏览器配置
param(
    [int]$Port = 57466
)
$userId = "k1flkhdn"
$outFile = "d:\MyProjects\Omni\ttdm\bin\m6\account_k1flkhdn.json"
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
$cookies = @()
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us|im-api\.tiktok\.com|mssdk") {
        $cookies += @{
            name = $c.name; value = $c.value; domain = $c.domain
            path = $c.path; httpOnly = $c.httpOnly; secure = $c.secure; sameSite = $c.sameSite
        }
    }
}
# device_id 从 ttwid 提取 (19 位数字)
$tw = ($cookies | Where-Object { $_.name -eq "ttwid" }).value
$m = [regex]::Match([uri]::UnescapeDataString($tw), '\d{19}')
$deviceId = if ($m.Success) { $m.Value } else { "" }
$acct = @{
    uid = 7664958044560016398        # k1flkhdn 实际 self uid (adspower sync 已确认)
    device_id = $deviceId
    cookies = $cookies
}
$json = $acct | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($outFile, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "account_k1flkhdn.json: $($cookies.Count) cookies, device_id=$deviceId -> $outFile"
$ws.Dispose()
