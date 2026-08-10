# 点击目标会话 (17824815072124) 读取消息历史确认 probe7
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
# 列出所有会话项
$listExpr = @'
(() => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  return JSON.stringify(Array.from(items).slice(0, 10).map(el => (el.textContent||'').replace(/\s+/g,' ').slice(0,50)));
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $listExpr; returnByValue = $true }
Write-Host "=== 会话列表 ==="
Write-Host $resp.result.result.value
# 点击目标
$clickExpr = @'
(() => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  for (const el of items) {
    if ((el.textContent||'').includes('17824815072124')) {
      const r = el.getBoundingClientRect();
      return Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
    }
  }
  return 'not-found';
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$coord = $resp.result.result.value
Write-Host "conv coord: $coord"
if ($coord -match '^\d+\|\d+$') {
    $p = $coord.Split('|')
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 4
}
$expr = @'
(() => {
  const out = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let n;
  while ((n = walker.nextNode())) {
    const t = n.textContent || '';
    if (t.includes('probe')) {
      out.push(t.trim().slice(0, 60));
    }
  }
  const u = document.querySelector('p[data-e2e="chat-uniqueid"]');
  return JSON.stringify({uniqueid: u ? u.textContent : '', probes: out.slice(0, 15)});
})()
'@
$resp = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 目标会话消息 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
