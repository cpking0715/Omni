# rs_capture7.ps1 — 浏览器 UI 真实发送 + 响应 hook: 对照 HTTP message/send 业务状态码
# 用 CDP Input 域真实键入 (React 响应), hook fetch/XHR 响应记录 message/send 业务码
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture7.json"
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
    $buf = New-Object byte[] 1048576
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}
$log = @()

# 1) 注入响应 hook
$hookExpr = @'
(() => {
  window.__rsSendResp = [];
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        let code = '';
        const m = s.match(/"status_code":(\d+)/);
        if (m) code = m[1];
        window.__rsSendResp.push({ kind: 'fetch', status: r.status, code, body: s.slice(0, 200) });
      } catch (e) {}
    }
    return r;
  };
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__rsU = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (b) {
    this.addEventListener('load', () => {
      if ((this.__rsU || '').indexOf('message/send') >= 0) {
        try {
          const s = this.responseText || '';
          const m = s.match(/"status_code":(\d+)/);
          window.__rsSendResp.push({ kind: 'xhr', status: this.status, code: m ? m[1] : '', body: s.slice(0, 200) });
        } catch (e) {}
      }
    });
    return os.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r1.result.result.value

# 2) 聚焦输入框 + CDP 真实键入
$msg = "rs-e2e-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$focusExpr = @'
(() => {
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  if (!input) return 'no input';
  input.focus();
  return 'focused';
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
$log += 'focus: ' + $r2.result.result.value
Start-Sleep -Milliseconds 400
Invoke-Cdp $ws 3 "Input.insertText" @{ text = $msg }
$r3 = Invoke-Cdp $ws 3 "Input.insertText" @{ text = $msg }
Start-Sleep -Milliseconds 600
$log += 'inserted: ' + $msg
# 回车发送
Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyDown"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
$r4 = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
Start-Sleep -Seconds 6

# 3) 读 hook 响应 + 聊天区确认
$readExpr = @'
(() => {
  const out = { sendResp: window.__rsSendResp || [], chats: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-5)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 100);
    if (t) out.chats.push(t);
  }
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.editorText = input ? input.textContent : 'NO_INPUT';
  return JSON.stringify(out);
})()
'@
$r5 = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
$out = @{}
if ($r5.result.result.value) { $out = $r5.result.result.value | ConvertFrom-Json }
$ws.Dispose()

@{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; editor_text = $out.editorText } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
