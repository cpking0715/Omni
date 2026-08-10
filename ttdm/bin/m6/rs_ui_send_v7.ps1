# rs_ui_send_v7.ps1 — UI 发送 v7: 完整路径 + 点击后检查错误提示/输入框清空/聊天区
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uisend7.json"
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
$msg = "rs-v7-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# hook fetch + XHR message/send + 网络层
$hookExpr = @'
(() => {
  window.__rsSendResp7 = { fetch: [], xhr: [], net: [] };
  const of = window.fetch;
  window.fetch = async (...args) => {
    const r = await of.apply(this, args);
    const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (url.indexOf('message/send') >= 0) {
      try {
        const b = await r.clone().arrayBuffer();
        const s = new TextDecoder().decode(b);
        const m = s.match(/"status_code":(\d+)/);
        window.__rsSendResp7.fetch.push({ status: r.status, code: m ? m[1] : '', body: s.slice(0, 200) });
      } catch (e) {}
    }
    return r;
  };
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__rsU7 = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    this.addEventListener('load', () => {
      if ((this.__rsU7 || '').indexOf('message/send') >= 0) {
        try {
          const s = this.responseText || '';
          const m = s.match(/"status_code":(\d+)/);
          window.__rsSendResp7.xhr.push({ status: this.status, code: m ? m[1] : '', body: s.slice(0, 200) });
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

# 1. 确保 royyen 会话打开 (页面当前应该在 royyen)
$expr0 = @'
(async () => {
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  if (nick && nick.textContent.trim() !== '') return 'already: ' + nick.textContent.trim();
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (items.length === 0) return 'no convs';
  items[0].click();
  await new Promise(r => setTimeout(r, 4000));
  return 'opened';
})()
'@
$r0 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr0; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'open: ' + $r0.result.result.value

# 2. 输入框坐标 + 真实点击 + focus + insertText
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

    # 3. 找发送按钮坐标
    $btnExpr = @'
(() => {
  const send = document.querySelector('svg[aria-label="Send"], [aria-label="Send"]');
  if (!send) return 'no send btn';
  const r = send.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) });
})()
'@
    $rb = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $btnExpr; returnByValue = $true }
    $btnPos = $rb.result.result.value
    $log += 'btn: ' + $btnPos

    # 4. 点击发送按钮
    if ($btnPos -and $btnPos -ne 'no send btn') {
        $bp = $btnPos | ConvertFrom-Json
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $bp.x; y = $bp.y; button = "none" }
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $bp.x; y = $bp.y; button = "left"; buttons = 1; clickCount = 1 }
        $null = Invoke-Cdp $ws 8 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $bp.x; y = $bp.y; button = "left"; buttons = 0; clickCount = 1 }
        $log += 'clicked send btn'
    } else {
        # 兜底 Enter
        $null = Invoke-Cdp $ws 8 "Input.dispatchKeyEvent" @{ type = "rawKeyDown"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
        $null = Invoke-Cdp $ws 8 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = "Enter"; code = "Enter"; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }
        $log += 'enter-sent'
    }
    Start-Sleep -Seconds 8

    # 5. 全面检查: 响应/聊天区/输入框/错误提示/DOM 变化
    $readExpr = @'
(() => {
  const out = {
    sendResp: window.__rsSendResp7 || { fetch: [], xhr: [] },
    chats: [], inputAfter: '', errTexts: [], btnStill: false
  };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputAfter = input ? (input.textContent || '') : '';
  // 错误/警告提示 (常见选择器 + 全页面找 "message" 相关提示)
  document.querySelectorAll('[data-e2e*="warn"], [data-e2e*="error"], [data-e2e*="notification"], [data-e2e*="tip"], [role="alert"]').forEach(el => {
    if (el.offsetParent !== null) {
      const t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (t) out.errTexts.push(t.slice(0, 150));
    }
  });
  // toast 提示
  document.querySelectorAll('[class*="toast"], [class*="Toast"], [class*="banner"], [class*="Banner"]').forEach(el => {
    if (el.offsetParent !== null) {
      const t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (t && t.length < 200) out.errTexts.push(t.slice(0, 150));
    }
  });
  out.btnStill = !!document.querySelector('svg[aria-label="Send"]');
  return JSON.stringify(out);
})()
'@
    $r2 = Invoke-Cdp $ws 9 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
    $out = @{}
    if ($r2.result.result.value) { $out = $r2.result.result.value | ConvertFrom-Json }
    $ws.Dispose()
    @{ log = $log; send_responses = $out.sendResp; chat_tail = $out.chats; input_after = $out.inputAfter; err_texts = $out.errTexts; btn_still = $out.btnStill; msg = $msg } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile"
} else {
    $ws.Dispose()
    @{ log = $log; err = 'no input' } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile (no input)"
}
