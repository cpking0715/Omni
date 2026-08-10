# 完整鼠标事件序列点击会话, 读聊天页 URL/标题
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
function Click-Coords($ws, [int]$seq, [double]$x, [double]$y) {
    Invoke-Cdp $ws $seq "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $x; y = $y } | Out-Null
    Start-Sleep -Milliseconds 80
    Invoke-Cdp $ws ($seq+1) "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $x; y = $y; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 80
    Invoke-Cdp $ws ($seq+2) "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $x; y = $y; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
}
# 逐个会话: 读坐标 -> 点击 -> 读 URL/标题 -> 返回列表
$itemExpr = @'
(i) => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  if (i >= items.length) return 'OUT_OF_RANGE';
  const c = items[i];
  const name = (c.textContent||'').trim().replace(/\s+/g,' ').slice(0,30);
  const r = c.getBoundingClientRect();
  return JSON.stringify({name: name, x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
}
'@
$stateExpr = 'JSON.stringify({href: location.href, title: document.title, uniqueid: (document.querySelector("[data-e2e=\"chat-uniqueid\"]")||{}).textContent || ""})'
$results = @()
for ($i = 0; $i -lt 6; $i++) {
    $resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "($itemExpr)($i)"; returnByValue = $true }
    $info = $resp.result.result.value
    if ($info -eq 'OUT_OF_RANGE') { break }
    $ci = $info | ConvertFrom-Json
    if (-not $ci.x) { Write-Host "item ${i}: $info"; continue }
    Click-Coords $ws 2 $ci.x $ci.y
    Start-Sleep -Seconds 3
    $resp = Invoke-Cdp $ws 10 "Runtime.evaluate" @{ expression = $stateExpr; returnByValue = $true }
    $st = $resp.result.result.value | ConvertFrom-Json
    $uid = $null
    if ($st.href -match "messages\?u=(\d+)") { $uid = $Matches[1] }
    $results += "$($ci.name) | uid=$uid | uniqueid=$($st.uniqueid) | $($st.href)"
    # 返回列表
    Invoke-Cdp $ws 11 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
    Start-Sleep -Seconds 3
}
Write-Host "=== 会话点击结果 ==="
$results | ForEach-Object { Write-Host $_ }
$ws.Dispose()
