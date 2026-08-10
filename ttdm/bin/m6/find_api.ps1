# 获取页面 JS bundle 列表 + 在页面上下文 fetch 消息历史 API 候选端点 (webmssdk 自动签名)
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
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 25000) {
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
    }
    return $null
}
# 1. 列出全部 JS bundle URL
$expr = @'
(() => {
  const scripts = performance.getEntriesByType('resource').filter(r => r.initiatorType === 'script').map(r => r.name);
  return JSON.stringify(scripts);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$scripts = $resp.result.result.value | ConvertFrom-Json
Write-Host "=== JS bundles ($($scripts.Count)) ==="
# 2. 找包含 tiktok webapp 的 bundle, 抓取并 grep API 端点
$out = ""
$count = 0
foreach ($s in $scripts) {
    if ($s -notmatch "webapp-desktop|webmssdk") { continue }
    $count++
    try {
        $fetchExpr = "(async () => { try { const r = await fetch('$s'); const t = await r.text(); const hits = []; const re = /(im-api|\/v1\/message|conversation|conv_id|im\/msg|tray)[a-zA-Z0-9/_.?=&{}-]{0,60}/g; let m; while ((m = re.exec(t)) && hits.length < 20) { hits.push(m[0].slice(0, 130)); } return JSON.stringify(hits); } catch(e) { return 'ERR'; } })()"
        $resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $fetchExpr; returnByValue = $true; awaitPromise = $true }
        $hits = $resp.result.result.value
        if ($hits -and $hits -ne "ERR" -and $hits -ne "[]") {
            $out += "=== $s ===`n$hits`n`n"
            Write-Host "=== $s ==="
            Write-Host $hits
        }
    } catch { }
}
[IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\api_endpoints.txt", $out, [System.Text.Encoding]::UTF8)
Write-Host "scanned=$count saved -> api_endpoints.txt"
$ws.Dispose()
