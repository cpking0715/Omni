# rs_ui_ws_probe.ps1 — 最终: UI 发送同时 hook HTTP+WS, 确认消息走哪条通道 + 业务码
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uiws.json"
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
$msg = "rs-uiws-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1. hook HTTP (fetch+XHR) + WebSocket (send + message)
$hookExpr = @'
(() => {
  if (window.__uiwsHooked) return 'already';
  window.__uiwsHooked = true;
  window.__uiws = { http: [], wsOut: [], wsIn: [] };
  // HTTP
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0 || url.indexOf('im-api') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        const m = s.match(/"status_code":(\d+)/);
        window.__uiws.http.push({ kind: 'fetch', url: url.slice(0, 120), status: r.status, code: m ? m[1] : '', body: s.slice(0, 150) });
      } catch (e) {}
    }
    return r;
  };
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__u = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    this.addEventListener('load', () => {
      const u = String(this.__u || '');
      if (u.indexOf('message/send') >= 0 || u.indexOf('im-api') >= 0) {
        try {
          const s = this.responseText || '';
          const m = s.match(/"status_code":(\d+)/);
          window.__uiws.http.push({ kind: 'xhr', url: u.slice(0, 120), status: this.status, code: m ? m[1] : '', body: s.slice(0, 150) });
        } catch (e) {}
      }
    });
    return os.apply(this, arguments);
  };
  // WebSocket
  const logWS = (dir, data) => {
    try {
      let s = '';
      if (typeof data === 'string') s = data;
      else if (data && data.data) s = typeof data.data === 'string' ? data.data : '[binary]';
      if (s && s.length < 8000) window.__uiws[dir].push(s.slice(0, 3000));
    } catch (e) {}
  };
  const origSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function(data) { logWS('wsOut', data); return origSend.call(this, data); };
  const origAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function(type, fn, opts) {
    if (this instanceof WebSocket) {
      const wrap = (ev) => { logWS('wsIn', ev); return fn.call(this, ev); };
      return origAdd.call(this, type, wrap, opts);
    }
    return origAdd.call(this, type, fn, opts);
  };
  return 'hooked';
})()
'@
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: done'

# 2. 清空日志, 确保 royyen 会话打开
$expr0 = @'
(async () => {
  window.__uiws.http = []; window.__uiws.wsOut = []; window.__uiws.wsIn = [];
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  if (nick && nick.textContent.trim()) return 'open: ' + nick.textContent.trim();
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (items.length === 0) return 'no convs';
  items[0].click();
  await new Promise(r => setTimeout(r, 4000));
  return 'opened';
})()
'@
$r0 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr0; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += $r0.result.result.value

# 3. 输入 (真实点击+focus+insertText)
$coordExpr = @'
(() => {
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  if (!input) return 'no input';
  const r = input.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
})()
'@
$rc = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $coordExpr; returnByValue = $true }
$coord = $rc.result.result.value
$log += 'coord: ' + $coord

if ($coord -and $coord -ne 'no input') {
    $p = $coord | ConvertFrom-Json
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $p.x; y = $p.y; button = "none" }
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $p.x; y = $p.y; button = "left"; buttons = 1; clickCount = 1 }
    $null = Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $p.x; y = $p.y; button = "left"; buttons = 0; clickCount = 1 }
    Start-Sleep -Milliseconds 500
    $focusExpr = @'
(() => {
  const ed = document.querySelector('[contenteditable="true"]');
  if (ed && document.activeElement !== ed) ed.focus();
  return document.activeElement === ed ? 'focused-ed' : 'not-focused';
})()
'@
    $null = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
    Start-Sleep -Milliseconds 400
    $null = Invoke-Cdp $ws 6 "Input.insertText" @{ text = $msg }
    $log += 'inserted: ' + $msg
    Start-Sleep -Seconds 2

    # 4. 找按钮并点击
    $btnExpr = @'
(() => {
  const send = document.querySelector('svg[aria-label="Send"], [aria-label="Send"]');
  if (!send) return 'no btn';
  const r = send.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
})()
'@
    $rb = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $btnExpr; returnByValue = $true }
    $btnPos = $rb.result.result.value
    $log += 'btn: ' + $btnPos
    if ($btnPos -and $btnPos -ne 'no btn') {
        $bp = $btnPos | ConvertFrom-Json
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $bp.x; y = $bp.y; button = "none" }
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $bp.x; y = $bp.y; button = "left"; buttons = 1; clickCount = 1 }
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $bp.x; y = $bp.y; button = "left"; buttons = 0; clickCount = 1 }
        $log += 'clicked'
    }
    Start-Sleep -Seconds 10

    # 5. 读全部证据
    $readExpr = @'
(() => {
  const out = {
    http: (window.__uiws && window.__uiws.http) || [],
    wsOut: (window.__uiws && window.__uiws.wsOut) || [],
    wsIn: (window.__uiws && window.__uiws.wsIn) || [],
    chats: [], inputAfter: ''
  };
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
    @{ log = $log; http = $out.http; ws_out = $out.wsOut; ws_in = $out.wsIn; chat_tail = $out.chats; input_after = $out.inputAfter; msg = $msg } | ConvertTo-Json -Depth 10 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile"
} else {
    $ws.Dispose()
    @{ log = $log; err = 'no input' } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile (no input)"
}
