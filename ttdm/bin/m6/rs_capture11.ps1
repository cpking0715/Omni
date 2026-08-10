# rs_capture11.ps1 — UI 真实发送对照 (聊天区已恢复): 浏览器自身 message/send 的业务码
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture11.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
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
$msg = "rs-e2e-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1) hook message/send 响应 (fetch + XHR)
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
        const m = s.match(/"status_code":(\d+)/);
        window.__rsSendResp.push({ kind: 'fetch', status: r.status, code: m ? m[1] : '', body: s.slice(0, 200) });
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

# 2) 聚焦 + 键入
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
$null = Invoke-Cdp $ws 3 "Input.insertText" @{ text = $msg }
$log += 'inserted: ' + $msg
Start-Sleep -Seconds 1

# 3) 找发送按钮点击
$btnExpr = @'
(() => {
  const btns = document.querySelectorAll('[data-e2e="dm-new-send-btn"]');
  for (const b of btns) {
    if (b.offsetParent !== null) {
      const r = b.getBoundingClientRect();
      return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
    }
  }
  return 'NO_VISIBLE_BTN';
})()
'@
$r4 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $btnExpr; returnByValue = $true }
$pos = $r4.result.result.value
$log += 'btn: ' + $pos
if ($pos -and $pos -ne 'NO_VISIBLE_BTN') {
    $p = $pos | ConvertFrom-Json
    $null = Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $p.x; y = $p.y; button = "left"; clickCount = 1 }
    $null = Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $p.x; y = $p.y; button = "left"; clickCount = 1 }
    $log += 'clicked at ' + $pos
}
Start-Sleep -Seconds 7

# 4) 读响应 + 聊天区
$readExpr = @'
(() => {
  const out = { sendResp: window.__rsSendResp || [], chats: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  return JSON.stringify(out);
})()
'@
$r5 = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
$out = @{}
if ($r5.result.result.value) { $out = $r5.result.result.value | ConvertFrom-Json }
$ws.Dispose()

@{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; msg = $msg } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
