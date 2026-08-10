# 诊断: 打开会话 -> 输入 test -> 检查输入内容 + 所有 Send 按钮 + 截图
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$targetUid = "17824815072124"
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
# 1. 先加载列表页, 再 SPA 内导航到会话 (直接带 u= 会被剥离)
Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages?lang=en'" } | Out-Null
Start-Sleep -Seconds 5
Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages?lang=en&u=$targetUid'" } | Out-Null
# 2. 轮询等待输入框 (最多 30s)
$inputProbe = 'JSON.stringify({href: location.href, input: !!(document.querySelector("[data-e2e=\"message-input-area\"]") || document.querySelector("div.DraftEditor-root")), items: document.querySelectorAll("[data-e2e=\"dm-new-conversation-item\"]").length})'
for ($t = 0; $t -lt 15; $t++) {
    Start-Sleep -Seconds 2
    $resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $inputProbe; returnByValue = $true }
    Write-Host "poll $t : $($resp.result.result.value)"
    $st = $resp.result.result.value | ConvertFrom-Json
    if ($st.input) { break }
}
$stateExpr = @'
(() => {
  const out = {};
  out.href = location.href;
  const input = document.querySelector('[data-e2e="message-input-area"]') || document.querySelector('div.DraftEditor-root');
  out.input = input ? 'found' : 'none';
  // 点击输入框
  if (input) {
    const r = input.getBoundingClientRect();
    out.inputRect = Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
  }
  // 所有 Send 相关元素
  const sels = ['svg[aria-label="Send"]', '[aria-label="Send"]', '[data-e2e="message-send"]', '[data-e2e="dm-new-send-btn"]', '[data-e2e="chat-send"]', '[data-e2e="send"]'];
  out.sends = [];
  for (const s of sels) {
    const els = document.querySelectorAll(s);
    if (els.length) {
      const el = els[0];
      const r = el.getBoundingClientRect();
      out.sends.push(s + ' x' + els.length + ' rect=' + Math.round(r.x+r.width/2) + '|' + Math.round(r.y+r.height/2) + ' visible=' + (r.width>0));
    }
  }
  // 所有含 send 的 data-e2e
  const all = [];
  document.querySelectorAll('[data-e2e]').forEach(el => {
    const e2e = el.getAttribute('data-e2e') || '';
    if (e2e.toLowerCase().indexOf('send') >= 0 || e2e.toLowerCase().indexOf('chat') >= 0) all.push(e2e);
  });
  out.e2e = [...new Set(all)].slice(0, 30);
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $stateExpr; returnByValue = $true }
Write-Host "STATE: $($resp.result.result.value)"
# 3. 点击输入框
$state = $resp.result.result.value | ConvertFrom-Json
if ($state.inputRect) {
    $parts = $state.inputRect -split '\|'
    $ix = [double]$parts[0]; $iy = [double]$parts[1]
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $ix; y = $iy } | Out-Null
    Start-Sleep -Milliseconds 50
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $ix; y = $iy; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 50
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $ix; y = $iy; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 300
    # 4. 逐字输入 test
    foreach ($ch in @('t','e','s','t')) {
        Invoke-Cdp $ws 6 "Input.insertText" @{ text = $ch } | Out-Null
        Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds 800
}
# 5. 检查输入内容 + 发送按钮状态
$checkExpr = @'
(() => {
  const out = {};
  const input = document.querySelector('[data-e2e="message-input-area"]') || document.querySelector('div.DraftEditor-root');
  out.inputText = input ? (input.textContent || '').slice(0, 80) : 'none';
  const sels = ['svg[aria-label="Send"]', '[aria-label="Send"]', '[data-e2e="message-send"]', '[data-e2e="dm-new-send-btn"]', '[data-e2e="chat-send"]', '[data-e2e="send"]', '[data-testid="send"]'];
  out.sends = [];
  for (const s of sels) {
    const els = document.querySelectorAll(s);
    if (els.length) {
      const el = els[0];
      const r = el.getBoundingClientRect();
      out.sends.push(s + ' x' + els.length + ' rect=' + Math.round(r.x+r.width/2) + '|' + Math.round(r.y+r.height/2) + ' vis=' + (r.width>0) + ' cls=' + String(el.className||'').slice(0,40));
    }
  }
  // 输入区下方的按钮容器
  const bottom = document.querySelector('div[data-e2e="dm-new-chat-bottom"]') || document.querySelector('div[data-e2e="dm-new-chatbox"]');
  out.bottom = bottom ? bottom.innerHTML.slice(0, 300) : 'no-bottom';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
Write-Host "AFTER TYPE: $($resp.result.result.value)"
# 6. 截图
$shot = Invoke-Cdp $ws 8 "Page.captureScreenshot" @{ format = "png" }
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\diag_send.png", [Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
