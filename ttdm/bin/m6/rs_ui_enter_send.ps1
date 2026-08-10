# rs_ui_enter_send.ps1 — UI 发送 v3: 真实键入 + Enter 键发送 (Draft.js 快捷键路径)
# 同时 hook message/send 响应, 拿 UI 真实发送的业务码
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uisend3.json"
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
$msg = "rs-enter-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1. hook message/send (fetch + XHR)
$hookExpr = @'
(() => {
  window.__rsSendResp3 = [];
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        const m = s.match(/"status_code":(\d+)/);
        window.__rsSendResp3.push({ kind: 'fetch', status: r.status, code: m ? m[1] : '', body: s.slice(0, 200) });
      } catch (e) {}
    }
    return r;
  };
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__rsU3 = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    this.addEventListener('load', () => {
      if ((this.__rsU3 || '').indexOf('message/send') >= 0) {
        try {
          const s = this.responseText || '';
          const m = s.match(/"status_code":(\d+)/);
          window.__rsSendResp3.push({ kind: 'xhr', status: this.status, code: m ? m[1] : '', body: s.slice(0, 200) });
        } catch (e) {}
      }
    });
    return os.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: hooked'

# 2. 打开第一个会话 (royyen)
$openExpr = @'
(() => {
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (items.length === 0) return 'no convs';
  items[0].click();
  return 'clicked conv 0';
})()
'@
$null = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $openExpr; returnByValue = $true }
Start-Sleep -Seconds 5

# 3. 聚焦输入框 + 真实键入
$focusExpr = @'
(() => {
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  if (!input) return 'no input';
  input.focus();
  input.click();
  return 'focused';
})()
'@
$null = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
Start-Sleep -Milliseconds 600
foreach ($ch in $msg.ToCharArray()) {
    $key = if ($ch -eq '-') { "Minus" } else { $ch.ToString() }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyDown"; text = $ch.ToString(); key = $key }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = $key }
    Start-Sleep -Milliseconds 30
}
$log += 'typed: ' + $msg
Start-Sleep -Seconds 1

# 4. 检查输入框有内容
$checkExpr = @'
(() => {
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  const t = input ? (input.textContent || '') : '';
  const ph = document.querySelector('.public-DraftEditorPlaceholder-inner');
  return JSON.stringify({ len: t.length, head: t.slice(0, 30), phVisible: !!ph && ph.offsetParent !== null });
})()
'@
$r1 = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
$log += 'check: ' + $r1.result.result.value

# 5. 按 Enter 发送
$null = Invoke-Cdp $ws 6 "Input.dispatchKeyEvent" @{ type = "rawKeyDown"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
$null = Invoke-Cdp $ws 6 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
$log += 'enter: sent'
Start-Sleep -Seconds 8

# 6. 读响应 + 聊天区 + 输入框清空情况
$readExpr = @'
(() => {
  const out = { sendResp: window.__rsSendResp3 || [], chats: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputAfter = input ? (input.textContent || '').slice(0, 30) : '';
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
$out = @{}
if ($r2.result.result.value) { $out = $r2.result.result.value | ConvertFrom-Json }
$ws.Dispose()

@{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; input_after = $out.inputAfter; msg = $msg } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
