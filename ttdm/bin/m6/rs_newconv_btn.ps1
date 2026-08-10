# rs_newconv_btn.ps1 — 导航到全新会话 (royyen_3) 检查发送按钮是否存在
# 对比: 旧会话(7193限制)无发送按钮 vs 新会话(未联系)是否渲染
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_newconvbtn.json"
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

# 1. 导航到新会话 (royyen_3 = 7479823623491208199, 未联系过)
$navExpr = @'
(async () => {
  const url = 'https://www.tiktok.com/messages?lang=en&u=7479823623491208199';
  window.location.href = url;
  return 'navigating';
})()
'@
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $navExpr; returnByValue = $true }
$log += 'nav: sent'
Start-Sleep -Seconds 10

# 2. 检查页面状态: 输入区 + 发送按钮 + 会话信息
$expr = @'
(() => {
  const out = {};
  out.url = location.href.slice(0, 120);
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputExists = !!input;
  // 所有 aria-label 含 Send / data-e2e 含 send 的元素
  const sendEls = [];
  document.querySelectorAll('[aria-label], [data-e2e]').forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const e2e = el.getAttribute('data-e2e') || '';
    if (/send/i.test(aria + ' ' + e2e) && el.offsetParent !== null) {
      const r = el.getBoundingClientRect();
      sendEls.push({ tag: el.tagName, aria: aria.slice(0, 40), e2e: e2e.slice(0, 40),
        x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
    }
  });
  out.sendEls = sendEls.slice(0, 10);
  // 聊天区会话昵称
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"], p[data-e2e="chat-uniqueid"]');
  out.nick = nick ? nick.textContent.trim().slice(0, 40) : '';
  // 页面是否有错误提示
  out.hasErr = /Something went wrong|not available/i.test(document.body.innerText);
  // 输入区 HTML 片段
  const inputArea = document.querySelector('[data-e2e="message-input-area"]');
  out.inputAreaHTML = inputArea ? inputArea.outerHTML.slice(0, 500) : '';
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$log += 'newconv: ' + $r1.result.result.value

# 3. 聚焦输入框 + 真实键入 + 检查按钮出现
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

$msg = "rs-newconv-" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
foreach ($ch in $msg.ToCharArray()) {
    $key = if ($ch -eq '-') { "Minus" } else { $ch.ToString() }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyDown"; text = $ch.ToString(); key = $key }
    $null = Invoke-Cdp $ws 4 "Input.dispatchKeyEvent" @{ type = "keyUp"; key = $key }
}
$log += 'typed: ' + $msg
Start-Sleep -Seconds 3

$expr2 = @'
(() => {
  const out = {};
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
  out.sendEls = sendEls.slice(0, 10);
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputText = input ? (input.textContent || '').slice(0, 40) : '';
  const ph = document.querySelector('.public-DraftEditorPlaceholder-inner');
  out.placeholderVisible = !!ph && ph.offsetParent !== null;
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
$log += 'after-input: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
