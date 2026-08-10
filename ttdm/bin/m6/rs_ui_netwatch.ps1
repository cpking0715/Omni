# rs_ui_netwatch.ps1 — 最终: CDP Network 域监听全部请求 + UI 输入 + 点击发送
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uinets.json"
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
$msg = "rs-net-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$netEvents = [System.Collections.ArrayList]::new()

# 1. 开启 Network 域 + 监听 requestWillBeSent / responseReceived (事件推送)
$null = Invoke-Cdp $ws 1 "Network.enable" $null
$log += 'net-enabled'
# 事件监听循环: 并行接收, 收集网络事件
function Start-NetListener($ws, $events) {
    $buf = New-Object byte[] 2097152
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.method -eq "Network.requestWillBeSent") {
            $u = $msg.params.request.url
            if ($u -match "im-api|message/send|conversation") {
                $null = $events.Add("REQ: $($msg.params.type) $($u.Substring(0, [Math]::Min(200, $u.Length)))")
            }
        } elseif ($msg.method -eq "Network.responseReceived") {
            $u = $msg.params.response.url
            if ($u -match "im-api|message/send|conversation") {
                $null = $events.Add("RESP: $($msg.params.response.status) $($u.Substring(0, [Math]::Min(200, $u.Length)))")
            }
        }
    }
}
$listenerTask = [System.Threading.Tasks.Task]::Run([Action]{ Start-NetListener $ws $netEvents })
Start-Sleep -Milliseconds 500

# 2. 确保 royyen 打开
$expr0 = @'
(async () => {
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

# 3. 输入
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

    # 4. 点击发送按钮 (bottomRight 偏移, 避开 path 内部)
    $btnExpr = @'
(() => {
  const send = document.querySelector('svg[aria-label="Send"]');
  if (!send) return 'no btn';
  const r = send.getBoundingClientRect();
  // 用右下偏移点 (elementFromPoint 命中 svg 本体)
  return JSON.stringify({ x: Math.round(r.x + r.width - 6), y: Math.round(r.y + r.height - 6) });
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

    # 5. 读 DOM 状态 (不依赖 hook)
    $readExpr = @'
(() => {
  const out = { chats: [], inputAfter: '', btnStill: false, errTexts: [] };
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  for (const c of Array.from(chats).slice(-8)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.chats.push(t.slice(0, 120));
  }
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputAfter = input ? (input.textContent || '') : '';
  out.btnStill = !!document.querySelector('svg[aria-label="Send"]');
  document.querySelectorAll('[role="alert"], [class*="error"], [class*="warn"], [data-e2e*="tip"]').forEach(el => {
    if (el.offsetParent !== null) {
      const t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (t) out.errTexts.push(t.slice(0, 120));
    }
  });
  return JSON.stringify(out);
})()
'@
    $r2 = Invoke-Cdp $ws 9 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
    $out = @{}
    if ($r2.result.result.value) { $out = $r2.result.result.value | ConvertFrom-Json }
    Start-Sleep -Milliseconds 500
    $ws.Dispose()
    @{ log = $log; net_events = $netEvents; chat_tail = $out.chats; input_after = $out.inputAfter; btn_still = $out.btnStill; err_texts = $out.errTexts; msg = $msg } | ConvertTo-Json -Depth 10 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile"
} else {
    $ws.Dispose()
    @{ log = $log; err = 'no input' } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile (no input)"
}
