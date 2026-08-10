# 在页面内重放 spotlight/relation API (URL 自带签名), 提取会话 uid
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
# 1. 从 performance 拿 spotlight/relation URL
$expr = 'JSON.stringify(performance.getEntriesByType("resource").map(e=>e.name).filter(u=>/im\/spotlight/.test(u)))'
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$urls = $resp.result.result.value | ConvertFrom-Json
Write-Host "spotlight URLs: $($urls.Count)"
if ($urls.Count -eq 0) {
    # 重新加载消息页触发 API
    Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
    Start-Sleep -Seconds 6
    $resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
    $urls = $resp.result.result.value | ConvertFrom-Json
    Write-Host "after reload: $($urls.Count)"
}
# 2. 页面内 fetch 重放 (URL 经 ConvertTo-Json 转义)
$u = $urls[0]
$uJs = $u | ConvertTo-Json -Compress
$fetchExpr = "(async () => { try { const r = await fetch($uJs, {credentials:'include'}); const j = await r.json(); return JSON.stringify(j).slice(0, 200); } catch(e) { return 'ERR ' + e.message; } })()"
$resp = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $fetchExpr; awaitPromise = $true; returnByValue = $true }
Write-Host "fetch head: $($resp.result.result.value)"
# 3. 若成功, 完整解析
$fetchFull = "(async () => { try { const r = await fetch($uJs, {credentials:'include'}); const j = await r.json(); return JSON.stringify(j); } catch(e) { return 'ERR ' + e.message; } })()"
$resp = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $fetchFull; awaitPromise = $true; returnByValue = $true }
$body = $resp.result.result.value
if ($body -and $body -ne 'ERR') {
    $json = $body | ConvertFrom-Json
    Write-Host "=== spotlight 结构 ==="
    $json.PSObject.Properties | ForEach-Object { Write-Host "$($_.Name): $($_.Value.GetType().Name) len=$($_.Value.ToString().Length)" }
    # 尝试提取 uid
    Write-Host "=== 全文关键字段 ==="
    $matches2 = [regex]::Matches($body, '\d{10,}')
    $matches2 | Select-Object -First 20 | ForEach-Object { Write-Host $_.Value }
}
$ws.Dispose()
