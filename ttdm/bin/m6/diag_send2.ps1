# 检查弹窗 + JS 聚焦输入框 + 重新输入
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
# 1. 检查弹窗
$modalExpr = @'
(() => {
  const out = [];
  document.querySelectorAll('[role="dialog"], [data-testid*="modal"], [aria-modal="true"]').forEach(el => {
    out.push((el.getAttribute('role')||'') + ' | ' + (el.getAttribute('data-testid')||'') + ' | ' + (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,120));
  });
  return out.join('\n') || 'no modal';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $modalExpr; returnByValue = $true }
Write-Host "=== 弹窗 ==="
Write-Host $resp.result.result.value
# 2. 聊天区信息
$chatExpr = @'
(() => {
  const out = {};
  const uniq = document.querySelector('[data-e2e="chat-uniqueid"]');
  out.uniqueid = uniq ? uniq.textContent : 'none';
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  out.nickname = nick ? nick.textContent : 'none';
  const bottom = document.querySelector('[data-e2e="dm-new-chat-bottom"]');
  out.bottomHTML = bottom ? bottom.innerHTML.slice(0, 500) : 'none';
  // 消息区是否有消息
  const msgs = document.querySelectorAll('[data-e2e="dm-new-message-item"], [data-e2e="chat-message-item"]');
  out.msgCount = msgs.length;
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $chatExpr; returnByValue = $true }
Write-Host "=== 聊天区 ==="
Write-Host $resp.result.result.value
# 3. JS 聚焦输入框 (DraftEditor contenteditable)
$focusExpr = @'
(() => {
  const ed = document.querySelector('[data-e2e="message-input-area"] div.DraftEditor-root [contenteditable="true"]') ||
            document.querySelector('div.DraftEditor-root [contenteditable="true"]') ||
            document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]');
  if (!ed) return 'no-editor';
  ed.focus();
  // 触发 React 感知的 input 事件
  const r = ed.getBoundingClientRect();
  return JSON.stringify({x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2), tag: ed.tagName, cls: String(ed.className||'').slice(0,50)});
})()
'@
$resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
Write-Host "=== 聚焦结果 ==="
Write-Host $resp.result.result.value
$fi = $resp.result.result.value | ConvertFrom-Json
if ($fi.x) {
    # 点击确保焦点 + 输入
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $fi.x; y = $fi.y } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $fi.x; y = $fi.y; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 6 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $fi.x; y = $fi.y; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 500
    foreach ($ch in @('t','e','s','t')) {
        Invoke-Cdp $ws 7 "Input.insertText" @{ text = $ch } | Out-Null
        Start-Sleep -Milliseconds 150
    }
    Start-Sleep -Milliseconds 800
}
# 4. 检查输入内容 + Send 按钮
$checkExpr = @'
(() => {
  const out = {};
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') || document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  out.text = ed ? (ed.textContent || ed.innerText || '').slice(0, 60) : 'no-editor';
  const sels = ['svg[aria-label="Send"]', '[aria-label="Send"]', '[data-e2e="message-send"]', '[data-e2e="dm-new-send-btn"]', '[data-e2e="chat-send"]', '[data-e2e="send"]'];
  out.sends = [];
  for (const s of sels) {
    const els = document.querySelectorAll(s);
    if (els.length) {
      const el = els[0];
      const r = el.getBoundingClientRect();
      out.sends.push(s + ' x' + els.length + ' rect=' + Math.round(r.x+r.width/2) + '|' + Math.round(r.y+r.height/2) + ' vis=' + (r.width>0));
    }
  }
  // dm-new-chat-bottom 里所有 button
  const bottom = document.querySelector('[data-e2e="dm-new-chat-bottom"]');
  if (bottom) {
    out.buttons = [];
    bottom.querySelectorAll('button, [role="button"], svg').forEach(b => {
      out.buttons.push((b.tagName) + ' aria=' + (b.getAttribute('aria-label')||'') + ' e2e=' + (b.getAttribute('data-e2e')||''));
    });
  }
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 8 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
Write-Host "=== 输入后 ==="
Write-Host $resp.result.result.value
$shot = Invoke-Cdp $ws 9 "Page.captureScreenshot" @{ format = "png" }
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\diag_send2.png", [Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
