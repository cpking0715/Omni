# rs_ui_newconv_flow.ps1 — 完整 UI 流程: 回到会话列表 → 搜索框真实键入 → 点击搜索结果 → 新会话按钮检查
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uinewflow.json"
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

# 0. 导航回消息列表首页 (清掉 u= 参数)
$navExpr = 'window.location.href = "https://www.tiktok.com/messages?lang=en"; "nav"'
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $navExpr; returnByValue = $true }
$log += 'nav-home: sent'
Start-Sleep -Seconds 8

# 1. 检查会话列表就绪
$expr0 = @'
(() => {
  const out = {};
  out.url = location.href.slice(0, 100);
  out.convList = !!document.querySelector('[data-e2e="dm-new-conversation-list"]');
  out.convCount = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]').length;
  out.input = !!document.querySelector('[data-e2e="search-user-input"]');
  return JSON.stringify(out);
})()
'@
$r0 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr0; returnByValue = $true }
$log += 'home: ' + $r0.result.result.value

# 2. 搜索框聚焦 + 真实键入 "royyen_3" (会触发搜索建议)
$focusExpr = @'
(() => {
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) return 'no search input';
  input.focus();
  input.click();
  return 'focused';
})()
'@
$null = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $focusExpr; returnByValue = $true }
Start-Sleep -Milliseconds 600
foreach ($ch in "royyen_3".ToCharArray()) {
    $key = if ($ch -eq '_') { "Shift" } elseif ($ch -eq '3') { "3" } else { $ch.ToString() }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyDown"; text = $ch.ToString(); key = $key }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = $key }
    Start-Sleep -Milliseconds 60
}
$log += 'typed: royyen_3'
Start-Sleep -Seconds 4

# 3. 读取搜索建议 DOM
$expr1 = @'
(() => {
  const out = { sugg: [] };
  document.querySelectorAll('li, [role="option"], [data-e2e*="sug"], [data-e2e*="search"], a').forEach(el => {
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    const e2e = (el.getAttribute('data-e2e') || '').slice(0, 50);
    const hasAvatar = !!el.querySelector('img');
    const href = (el.getAttribute('href') || '').slice(0, 80);
    if (txt && (hasAvatar || /royyen/.test(txt) || e2e.includes('search')) && txt.length < 80) {
      out.sugg.push({ e2e, txt, href, avatar: hasAvatar });
    }
  });
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$log += 'sugg: ' + $r1.result.result.value

# 4. 点击第一个含头像的搜索建议
$expr2 = @'
(() => {
  const cands = [...document.querySelectorAll('li, [role="option"], [data-e2e*="sug"], a')]
    .filter(el => el.querySelector('img') && (el.textContent || '').trim().length < 80);
  if (cands.length === 0) return 'no cand';
  cands[0].click();
  return 'clicked: ' + (cands[0].textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40);
})()
'@
$r2 = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
$log += 'click: ' + $r2.result.result.value
Start-Sleep -Seconds 6

# 5. 检查新会话: 输入区 + 发送按钮 + 昵称
$expr3 = @'
(() => {
  const out = {};
  out.url = location.href.slice(0, 130);
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputExists = !!input;
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"], p[data-e2e="chat-uniqueid"]');
  out.nick = nick ? nick.textContent.trim().slice(0, 40) : '';
  const sendEls = [];
  document.querySelectorAll('[aria-label], [data-e2e], svg, button').forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const e2e = el.getAttribute('data-e2e') || '';
    const r = el.getBoundingClientRect();
    const vis = el.offsetParent !== null && r.width > 10 && r.height > 10;
    if (/send/i.test(aria + ' ' + e2e) && vis) {
      sendEls.push({ tag: el.tagName, aria: aria.slice(0, 40), e2e: e2e.slice(0, 40),
        x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
    }
  });
  out.sendEls = sendEls.slice(0, 8);
  // 聊天区是否有消息
  out.chatCount = document.querySelectorAll('[data-e2e="dm-new-chat-item"]').length;
  return JSON.stringify(out);
})()
'@
$r3 = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $expr3; returnByValue = $true }
$log += 'newconv: ' + $r3.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
