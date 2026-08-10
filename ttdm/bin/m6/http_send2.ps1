# 抓所有 HTTP 请求 + WS 帧 (不过滤), 定位 send_text 真实通道
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
$script:netLog = @()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
        if ($msg.method -eq "Network.webSocketCreated") {
            $script:netLog += "WS-CREATED " + $msg.params.url
        } elseif ($msg.method -eq "Network.webSocketFrameSent") {
            $p = $msg.params.response.payloadData
            $script:netLog += "WS-SENT len=" + $p.Length + " " + $p
        } elseif ($msg.method -eq "Network.webSocketFrameReceived") {
            $p = $msg.params.response.payloadData
            $script:netLog += "WS-RECV len=" + $p.Length + " " + $p
        } elseif ($msg.method -eq "Network.requestWillBeSent") {
            $script:netLog += "HTTP " + $msg.params.request.method + " " + $msg.params.request.url
        } elseif ($msg.method -eq "Network.responseReceived") {
            $script:netLog += "RESP " + $msg.params.response.status + " " + $msg.params.response.url
        }
    }
}
Invoke-Cdp $ws 1 "Network.enable" @{} | Out-Null
Write-Host "Network enabled"
# 1. 点击目标会话 (幂等)
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
if ($coord -match '^\d+\|\d+$') {
    $p = $coord.Split('|')
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 2
}
# 2. 聚焦 + 输入 probe3
$focusExpr = @'
(() => {
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') ||
            document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  if (!ed) return 'no-editor';
  ed.focus();
  const r = ed.getBoundingClientRect();
  return Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
})()
'@
$resp = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
$fi = $resp.result.result.value
if ($fi -match '^\d+\|\d+$') {
    $p = $fi.Split('|')
    Invoke-Cdp $ws 7 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 9 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 500
}
foreach ($ch in @('p','r','o','b','e','3')) {
    Invoke-Cdp $ws 10 "Input.insertText" @{ text = $ch } | Out-Null
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Milliseconds 800
# 3. 点击发送
$sendExpr = @'
(() => {
  const box = document.querySelector('div[data-e2e="dm-new-chat-bottom"]') || document.querySelector('div[data-e2e="dm-new-chatbox"]');
  if (!box) return 'no-box';
  const el = box.querySelector('svg[aria-label="Send"], [aria-label="Send"], [data-e2e=message-send], [data-e2e=dm-new-send-btn]');
  if (!el) return 'no-send';
  const r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) return 'hidden';
  return Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
})()
'@
$resp = Invoke-Cdp $ws 11 "Runtime.evaluate" @{ expression = $sendExpr; returnByValue = $true }
$sc = $resp.result.result.value
Write-Host "=== 发送按钮: $sc ==="
if ($sc -match '^\d+\|\d+$') {
    $p = $sc.Split('|')
    Invoke-Cdp $ws 12 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 13 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 14 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Write-Host "已点击发送"
} else {
    Write-Host "发送按钮不可用: $sc"
}
Start-Sleep -Seconds 4
# 4. DOM 验证
$checkExpr = @'
(() => {
  const out = {};
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') || document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  out.editorText = ed ? (ed.textContent||ed.innerText||'') : 'no-editor';
  const convs = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  out.firstConv = convs.length ? convs[0].textContent.trim().replace(/\s+/g,' ').slice(0,60) : '';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 15 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
Write-Host "=== 发送后 ==="
Write-Host $resp.result.result.value
Write-Host "=== 网络日志 (发送期间) ==="
$script:netLog | ForEach-Object { Write-Host $_ }
$ws.Dispose()
