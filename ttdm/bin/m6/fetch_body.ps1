# 捕获 message/send 的 POST body (ArrayBuffer → base64) —— M6-3 收官 (probe6 最后一条)
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\send_body.txt"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$script:netReqs = @()
$script:netId = 100
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
        if ($msg.method -eq "Network.requestWillBeSent" -and $msg.params.request.url -match "message/send") {
            $script:netReqs += @{ id = $script:netId; requestId = $msg.params.requestId; url = $msg.params.request.url; postData = $msg.params.request.postData }
            $script:netId++
        }
        if ($msg.method -eq "Network.responseReceived" -and $msg.params.response.url -match "message/send") {
            $script:netReqs += @{ id = $script:netId; requestId = $msg.params.requestId; url = $msg.params.response.url; status = $msg.params.response.status }
            $script:netId++
        }
    }
}
# 1. 启用 Network 域
Invoke-Cdp $ws 1 "Network.enable" | Out-Null
# 2. 注入增强 hook (ArrayBuffer → base64)
$hook = @'
(() => {
  if (window.__bodyHooked) return 'already';
  window.__bodyHooked = true;
  window.__sendBodies = [];
  const toB64 = (buf) => {
    const u8 = new Uint8Array(buf);
    let bin = '';
    const chunk = 0x8000;
    for (let i = 0; i < u8.length; i += chunk) {
      bin += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
    }
    return btoa(bin);
  };
  const decode = (body) => {
    if (body == null) return '(none)';
    if (typeof body === 'string') return 'STR ' + body.slice(0, 3000);
    if (body instanceof ArrayBuffer) {
      const u8 = new Uint8Array(body);
      let txt = '';
      try { txt = new TextDecoder().decode(u8); } catch (e) {}
      return 'AB(len=' + u8.length + ') utf8=' + JSON.stringify(txt.slice(0, 600)) + '\nB64=' + toB64(body);
    }
    if (ArrayBuffer.isView(body)) {
      const ab = body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
      return decode(ab);
    }
    return String(body).slice(0, 3000);
  };
  const OX = XMLHttpRequest.prototype.open;
  const OS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__u = String(url);
    return OX.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function(body) {
    if (String(this.__u).indexOf('message/send') >= 0) {
      window.__sendBodies.push('XHR ' + this.__u + '\n' + decode(body));
    }
    return OS.call(this, body);
  };
  const of = window.fetch;
  window.fetch = function(...args) {
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (String(url).indexOf('message/send') >= 0) {
      const b = args[1] && args[1].body;
      window.__sendBodies.push('FETCH ' + url + '\n' + (b instanceof ReadableStream ? 'STREAM' : decode(b)));
    }
    return of.apply(this, args);
  };
  return 'ok';
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $hook; returnByValue = $true }
Write-Host "hook: $($resp.result.result.value)"
# 3. 点击会话
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
$resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$coord = $resp.result.result.value
if ($coord -match '^\d+\|\d+$') {
    $p = $coord.Split('|')
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 6 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 2
}
# 4. 聚焦输入框
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
$resp = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
$fi = $resp.result.result.value
if ($fi -match '^\d+\|\d+$') {
    $p = $fi.Split('|')
    Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 9 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 10 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Milliseconds 500
}
foreach ($ch in @('p','r','o','b','e','6')) {
    Invoke-Cdp $ws 11 "Input.insertText" @{ text = $ch } | Out-Null
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Milliseconds 800
# 5. 点击发送
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
$resp = Invoke-Cdp $ws 12 "Runtime.evaluate" @{ expression = $sendExpr; returnByValue = $true }
$sc = $resp.result.result.value
Write-Host "=== 发送按钮: $sc ==="
if ($sc -match '^\d+\|\d+$') {
    $p = $sc.Split('|')
    Invoke-Cdp $ws 13 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 14 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 15 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Write-Host "已点击发送"
}
Start-Sleep -Seconds 3
# 6. 取回页面 hook 捕获
$resp = Invoke-Cdp $ws 16 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__sendBodies || [])'; returnByValue = $true }
$pageCaptured = $resp.result.result.value
# 7. 对 CDP 捕获的 requestId 调用 getRequestPostData
$cdpBody = ""
foreach ($nr in $script:netReqs) {
    if ($nr.requestId -and $nr.url -match "message/send" -and -not $nr.postData) {
        try {
            $pr = Invoke-Cdp $ws 17 "Network.getRequestPostData" @{ requestId = $nr.requestId }
            if ($pr.result -and $pr.result.postData) { $cdpBody = $pr.result.postData }
        } catch { }
    }
}
# 8. 落盘
$content = "=== PAGE HOOK (message/send bodies) ===`n$pageCaptured`n`n=== CDP NETWORK EVENTS ===`n"
foreach ($nr in $script:netReqs) {
    $content += "id=$($nr.id) req=$($nr.requestId) url=$($nr.url) status=$($nr.status) postDataLen=$($nr.postData.Length)`n"
}
$content += "`n=== GETREQUESTPOSTDATA ===`n$cdpBody`n"
[IO.File]::WriteAllText($outFile, $content, [System.Text.Encoding]::UTF8)
Write-Host "=== 页面捕获 ==="
Write-Host $pageCaptured
Write-Host "=== CDP 事件数: $($script:netReqs.Count) ==="
foreach ($nr in $script:netReqs) { Write-Host "net: req=$($nr.requestId) status=$($nr.status) postDataLen=$($nr.postData.Length)" }
Write-Host "=== getRequestPostData ==="
Write-Host $cdpBody
Write-Host "saved -> $outFile"
$ws.Dispose()
