# rs_ui_send_v2.ps1 — UI 真实发送 v2: 真实键盘键入 + 检测按钮出现 + 点击 + hook 响应
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uisend2.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 45000) {
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
$msg = "rs-e2e2-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1. hook message/send 响应
$hookExpr = @'
(() => {
  window.__rsSendResp2 = [];
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        const m = s.match(/"status_code":(\d+)/);
        window.__rsSendResp2.push({ status: r.status, code: m ? m[1] : '', body: s.slice(0, 250) });
      } catch (e) {}
    }
    return r;
  };
  return 'hooked';
})()
'@
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }

# 2. 聚焦输入框
$focusExpr = @'
(() => {
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  if (!input) return 'no input';
  input.focus();
  input.click();
  return 'focused';
})()
'@
$null = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
Start-Sleep -Milliseconds 500

# 3. 真实键盘键入 (逐字符)
foreach ($ch in $msg.ToCharArray()) {
    $key = if ($ch -eq '-') { "Minus" } else { $ch.ToString() }
    $null = Invoke-Cdp $ws 3 "Input.dispatchKeyEvent" @{ type = "keyDown"; text = $ch.ToString(); key = $key }
    $null = Invoke-Cdp $ws 3 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = $key }
}
$log += 'typed: ' + $msg
Start-Sleep -Seconds 2

# 4. 检查输入框状态 + 按钮
$checkExpr = @'
(() => {
  const out = {};
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.inputText = (input ? (input.textContent || '') : '').slice(0, 40);
  // placeholder 是否消失
  const ph = document.querySelector('.public-DraftEditorPlaceholder-inner');
  out.placeholderVisible = !!ph && ph.offsetParent !== null;
  // 底部区域所有可见元素 (输入区附近, y>400)
  const cands = [];
  document.querySelectorAll('button, [role="button"], [data-e2e]').forEach((b) => {
    const rect = b.getBoundingClientRect();
    if (rect.width > 10 && rect.height > 10 && rect.y > 450 && rect.x > 500) {
      cands.push({
        tag: b.tagName, e2e: (b.getAttribute('data-e2e') || '').slice(0, 50),
        aria: (b.getAttribute('aria-label') || '').slice(0, 50),
        cls: (b.className || '').toString().slice(0, 60),
        x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height)
      });
    }
  });
  out.bottomEls = cands.slice(0, 15);
  return JSON.stringify(out);
})()
'@
$r = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
$log += 'check: ' + $r.result.result.value

# 5. 若找到发送按钮 (含 svg 图标按钮: y>450 且右侧), 点击
$clickExpr = @'
(() => {
  const cands = [];
  document.querySelectorAll('button, [role="button"]').forEach((b) => {
    const rect = b.getBoundingClientRect();
    // 发送按钮特征: 在输入框同一行右侧 (x > 输入框x + 输入框宽 - 20), 可点击尺寸
    if (rect.width > 15 && rect.height > 15 && rect.y > 450) {
      cands.push({ e2e: (b.getAttribute('data-e2e') || ''), aria: (b.getAttribute('aria-label') || ''),
        cls: (b.className || '').toString().slice(0, 80),
        x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) });
    }
  });
  return JSON.stringify(cands.slice(0, 10));
})()
'@
$r2 = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$cands = @()
if ($r2.result.result.value) { $cands = $r2.result.result.value | ConvertFrom-Json }
$log += 'cands: ' + ($cands | ConvertTo-Json -Compress -Depth 5)
$clicked = $false
foreach ($c in $cands) {
    if (-not $clicked -and $c.x -gt 500) {
        $null = Invoke-Cdp $ws 6 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $c.x; y = $c.y; button = "left"; clickCount = 1 }
        $null = Invoke-Cdp $ws 6 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $c.x; y = $c.y; button = "left"; clickCount = 1 }
        $log += "clicked: $($c.e2e) aria=$($c.aria) at $($c.x),$($c.y)"
        $clicked = $true
    }
}
if (-not $clicked) { $log += 'clicked: none' }
Start-Sleep -Seconds 8

# 6. 读响应 + 聊天区
$readExpr = @'
(() => {
  const out = { sendResp: window.__rsSendResp2 || [], chats: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  return JSON.stringify(out);
})()
'@
$r3 = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
$out = @{}
if ($r3.result.result.value) { $out = $r3.result.result.value | ConvertFrom-Json }
$ws.Dispose()

@{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; msg = $msg } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
