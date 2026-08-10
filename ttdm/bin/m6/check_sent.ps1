# 验证上一轮 wshook 的 "test" 消息是否真实发出:
# 1. 当前页面 URL / 会话状态
# 2. 聊天记录 DOM 中所有消息文本 (找 "test")
# 3. 截图
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
$expr = @'
(() => {
  const out = {};
  out.url = location.href;
  out.uniqueid = (document.querySelector('[data-e2e="chat-uniqueid"]')||{}).textContent || 'none';
  out.nickname = (document.querySelector('[data-e2e="dm-new-chat-nickname"]')||{}).textContent || 'none';
  // 聊天记录消息 (各种可能的容器/消息项选择器)
  const selList = [
    '[data-e2e="dm-new-message-item"]',
    '[data-e2e="chat-message-item"]',
    '[data-e2e="message-item"]',
    '[data-e2e="dm-conversation-message"]',
    'div[data-e2e="dm-new-chat-messages"] [data-e2e]'
  ];
  const found = {};
  for (const s of selList) {
    const els = document.querySelectorAll(s);
    if (els.length) {
      found[s] = Array.from(els).slice(-8).map(el => (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,80));
    }
  }
  out.messages = found;
  // 页面是否含 "test" 文本
  const all = document.body.innerText || '';
  out.hasTest = all.includes('test');
  const idx = all.indexOf('test');
  out.testContext = idx >= 0 ? all.slice(Math.max(0, idx-120), idx+60).replace(/\n+/g,' | ') : '';
  // 输入框内容
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') || document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  out.editorText = ed ? (ed.textContent||ed.innerText||'').slice(0,60) : 'no-editor';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 页面状态 ==="
Write-Host $resp.result.result.value
$shot = Invoke-Cdp $ws 2 "Page.captureScreenshot" @{ format = "png" }
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\check_sent.png", [Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
