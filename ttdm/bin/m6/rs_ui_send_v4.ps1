# rs_ui_send_v4.ps1 — UI 发送 v4: 真实鼠标点击输入框 + insertText 真实输入 (Draft.js 正确路径)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uisend4.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 60000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 2097152
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
    return $null
}
$log = @()
$msg = "rs-click-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1. hook message/send
$hookExpr = @'
(() => {
  window.__rsSendResp4 = [];
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        const m = s.match(/"status_code":(\d+)/);
        window.__rsSendResp4.push({ status: r.status, code: m ? m[1] : '', body: s.slice(0, 200) });
      } catch (e) {}
    }
    return r;
  };
  return 'hooked';
})()
'@
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }

# 2. 打开会话 0 (royyen) 并获取输入框真实坐标
$openExpr = @'
(() => {
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (items.length === 0) return 'no convs';
  items[0].click();
  return 'clicked';
})()
'@
$null = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $openExpr; returnByValue = $true }
Start-Sleep -Seconds 5

$coordExpr = @'
(() => {
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  if (!input) return 'no input';
  const r = input.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: Math.round(r.width), h: Math.round(r.height) });
})()
'@
$rc = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $coordExpr; returnByValue = $true }
$coord = $rc.result.result.value
$log += 'coord: ' + $coord
if ($coord -and $coord -ne 'no input') {
    $p = $coord | ConvertFrom-Json
    # 3. 真实鼠标点击输入框中心
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $p.x; y = $p.y }
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $p.x; y = $p.y; button = "left"; clickCount = 1 }
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $p.x; y = $p.y; button = "left"; clickCount = 1 }
    $log += 'clicked input'
    Start-Sleep -Milliseconds 800
    # 4. insertText 真实输入
    $null = Invoke-Cdp $ws 5 "Input.insertText" @{ text = $msg }
    $log += 'inserted: ' + $msg
    Start-Sleep -Seconds 2
    # 5. 检查输入框内容 + 按钮
    $checkExpr = @'
(() => {
  const out = {};
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputText = input ? (input.textContent || '') : '';
  const ph = document.querySelector('.public-DraftEditorPlaceholder-inner');
  out.phVisible = !!ph && ph.offsetParent !== null;
  const sendEls = [];
  document.querySelectorAll('[aria-label], [data-e2e], svg').forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const e2e = el.getAttribute('data-e2e') || '';
    const r = el.getBoundingClientRect();
    if (/send/i.test(aria + ' ' + e2e) && el.offsetParent !== null && r.width > 10) {
      sendEls.push({ tag: el.tagName, aria: aria.slice(0, 40), e2e: e2e.slice(0, 40), x: Math.round(r.x), y: Math.round(r.y) });
    }
  });
  out.sendEls = sendEls.slice(0, 5);
  return JSON.stringify(out);
})()
'@
    $r1 = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
    $log += 'check: ' + $r1.result.result.value
    # 6. 若有按钮则点击, 否则按 Enter
    $sendExpr = @'
(() => {
  const send = document.querySelector('svg[aria-label="Send"], [aria-label="Send"]');
  if (send) {
    const r = send.getBoundingClientRect();
    return JSON.stringify({ method: 'click', x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) });
  }
  return JSON.stringify({ method: 'enter' });
})()
'@
    $rs = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $sendExpr; returnByValue = $true }
    $sendInfo = $rs.result.result.value | ConvertFrom-Json
    $log += 'send-method: ' + ($sendInfo | ConvertTo-Json -Compress)
    if ($sendInfo.method -eq 'click') {
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $sendInfo.x; y = $sendInfo.y; button = "left"; clickCount = 1 }
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $sendInfo.x; y = $sendInfo.y; button = "left"; clickCount = 1 }
        $log += 'send-clicked'
    } else {
        $null = Invoke-Cdp $ws 8 "Input.dispatchKeyEvent" @{ type = "rawKeyDown"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
        $null = Invoke-Cdp $ws 8 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
        $log += 'enter-sent'
    }
    Start-Sleep -Seconds 8
    # 7. 读结果
    $readExpr = @'
(() => {
  const out = { sendResp: window.__rsSendResp4 || [], chats: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputAfter = input ? (input.textContent || '') : '';
  return JSON.stringify(out);
})()
'@
    $r2 = Invoke-Cdp $ws 9 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
    $out = @{}
    if ($r2.result.result.value) { $out = $r2.result.result.value | ConvertFrom-Json }
    $ws.Dispose()
    @{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; input_after = $out.inputAfter; msg = $msg } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile"
} else {
    $ws.Dispose()
    @{ log = $log; err = 'no input coords' } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile (no input)"
}
