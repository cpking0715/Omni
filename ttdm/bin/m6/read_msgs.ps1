# 读取会话消息文本 (宽松选择器)
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
$expr = @'
(() => {
  const out = {url: location.href};
  // uniqueid
  const u = document.querySelector('p[data-e2e="chat-uniqueid"]');
  out.uniqueid = u ? u.textContent : '';
  // 消息区: 各种可能的选择器
  const sels = [
    '[data-e2e="dm-new-chat-message"]',
    '[data-e2e="dm-message-item"]',
    'div[data-e2e="dm-new-chat-content"] [dir="auto"]',
    'div.DraftEditor-root [data-contents="true"] > div > div',
    '[data-e2e="conversation-message"]'
  ];
  for (const sel of sels) {
    const els = document.querySelectorAll(sel);
    if (els.length > 0) {
      out.sel = sel;
      out.msgs = Array.from(els).slice(-10).map(el => (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,80)).filter(t => t);
      return JSON.stringify(out);
    }
  }
  // 兜底: 消息区容器全文
  const box = document.querySelector('[data-e2e="dm-new-chat-content"], [data-e2e="dm-new-chatbox"], [data-e2e="message-list"]');
  out.fallback = box ? (box.textContent||'').replace(/\s+/g,' ').slice(0, 500) : 'no-box';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 会话消息 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
