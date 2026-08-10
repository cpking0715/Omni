# 点击会话列表项 "user17824815072124" → 验证右侧窗格真正打开
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
Write-Host "page ws: $wsUrl"
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
# 1. 列出会话项
$listExpr = @'
(() => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  const out = [];
  items.forEach(el => {
    const r = el.getBoundingClientRect();
    out.push((el.textContent||'').trim().replace(/\s+/g,' ').slice(0,60) + ' @ ' + Math.round(r.x+r.width/2) + '|' + Math.round(r.y+r.height/2) + ' w=' + Math.round(r.width));
  });
  return out.join('\n') || 'no items';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $listExpr; returnByValue = $true }
Write-Host "=== 会话列表 ==="
Write-Host $resp.result.result.value
# 2. 点击目标会话项 (返回坐标)
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
Write-Host "=== 点击目标: $coord ==="
if ($coord -match '^\d+\|\d+$') {
    $p = $coord.Split('|')
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 3
}
# 3. 检查会话窗格状态
$checkExpr = @'
(() => {
  const out = {};
  out.url = location.href;
  out.uniqueid = (document.querySelector('[data-e2e="chat-uniqueid"]')||{}).textContent || 'none';
  out.nickname = (document.querySelector('[data-e2e="dm-new-chat-nickname"]')||{}).textContent || 'none';
  // 消息项
  const msgs = document.querySelectorAll('[data-e2e="dm-new-message-item"], [data-e2e="chat-message-item"]');
  out.msgCount = msgs.length;
  out.lastMsgs = Array.from(msgs).slice(-5).map(el => (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,60));
  // 输入框
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') || document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  out.editor = ed ? 'present' : 'none';
  // 消息区容器
  const msgsBox = document.querySelector('[data-e2e="dm-new-chat-messages"], [data-e2e="dm-new-chat-message-list"]');
  out.msgsBox = msgsBox ? msgsBox.textContent.trim().replace(/\s+/g,' ').slice(0,200) : 'none';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
Write-Host "=== 点击后状态 ==="
Write-Host $resp.result.result.value
$shot = Invoke-Cdp $ws 7 "Page.captureScreenshot" @{ format = "png" }
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\click_conv.png", [Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
