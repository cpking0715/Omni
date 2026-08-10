# 下载页面 JS bundle 列表 (性能条目), 用浏览器 cookies 下载到本地供扫描
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outDir = "d:\MyProjects\OmniMarket\ttdm\bin\m6\bundles"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
if (-not $wsUrl) { $wsUrl = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1 -ExpandProperty webSocketDebuggerUrl }
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
# 1. bundle 列表: 优先 im/ws 相关
$expr = 'JSON.stringify(performance.getEntriesByType("resource").map(e=>e.name).filter(u=>/\.js/.test(u) && /(im|ws|sdk|message|webcast|tiktok_web)/i.test(u)))'
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$urls = $resp.result.result.value | ConvertFrom-Json
Write-Host "candidate bundles: $($urls.Count)"
# 2. cookies
$cres = Invoke-Cdp $ws 2 "Network.getAllCookies" $null
$cookieParts = @()
foreach ($c in $cres.result.cookies) {
    if ($c.domain -match "tiktok") { $cookieParts += "$($c.name)=$($c.value)" }
}
$cookieHeader = $cookieParts -join "; "
# 3. 下载 (最多 25 个, 每个限 8MB)
$ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
$headers = @{ "User-Agent" = $ua; "Referer" = "https://www.tiktok.com/"; "Cookie" = $cookieHeader; "Accept" = "*/*" }
$i = 0
foreach ($u in $urls) {
    if ($i -ge 25) { break }
    $i++
    $name = [IO.Path]::GetFileName([Uri]::new($u).AbsolutePath)
    if (-not $name) { $name = "bundle_$i.js" }
    $name = $name -replace '[^\w.-]', '_'
    $path = Join-Path $outDir "$i`_$name"
    try {
        $wc = New-Object System.Net.WebClient
        foreach ($k in $headers.Keys) { $wc.Headers.Add($k, $headers[$k]) }
        $wc.DownloadFile($u, $path)
        $sz = (Get-Item $path).Length
        Write-Host "downloaded $name ($sz bytes)"
        if ($sz -gt 8388608) { Remove-Item $path; Write-Host "  too big, dropped" }
    } catch {
        Write-Host "FAIL $name : $($_.Exception.Message)"
        if (Test-Path $path) { Remove-Item $path }
    }
}
$ws.Dispose()
Write-Host "done"
