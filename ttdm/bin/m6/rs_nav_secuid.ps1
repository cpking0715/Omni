# rs_nav_secuid.ps1 — 用 secUid 导航新会话 + 轮询等待输入区 + 检查发送按钮
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_navsecuid.json"
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

# 1. 导航: 用 royyen_3 的 secUid (从 user/full 搜索得到)
$secUid = "MS4wLjABAAAA5dZUDBRIjeMQefidPx"
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "window.location.href = 'https://www.tiktok.com/messages?lang=en&u=$secUid'; 'nav'" ; returnByValue = $true }
$log += 'nav-secuid: sent'
Start-Sleep -Seconds 12

# 2. 轮询检查输入区 (最多 25s)
$pollExpr = @'
(async () => {
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
    if (input) {
      const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"], p[data-e2e="chat-uniqueid"]');
      return JSON.stringify({ ready: true, url: location.href.slice(0, 130),
        nick: nick ? nick.textContent.trim().slice(0, 40) : '',
        chatCount: document.querySelectorAll('[data-e2e="dm-new-chat-item"]').length });
    }
    await new Promise(r => setTimeout(r, 1500));
  }
  return JSON.stringify({ ready: false, url: location.href.slice(0, 130),
    bodyHead: document.body.innerText.slice(0, 200) });
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $pollExpr; awaitPromise = $true; returnByValue = $true; timeout = 40000 }
$log += 'poll: ' + $r1.result.result.value

# 3. 若就绪: 键入文本 + 查发送按钮
$expr = @'
(async () => {
  const out = {};
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  input.click();
  await new Promise(r => setTimeout(r, 500));
  // 查发送按钮 (输入前)
  const before = [];
  document.querySelectorAll('[aria-label], [data-e2e], svg').forEach(el => {
    const aria = el.getAttribute('aria-label') || '';
    const e2e = el.getAttribute('data-e2e') || '';
    const r = el.getBoundingClientRect();
    if (/send/i.test(aria + ' ' + e2e) && el.offsetParent !== null && r.width > 10) {
      before.push({ tag: el.tagName, aria: aria.slice(0, 40), e2e: e2e.slice(0, 40) });
    }
  });
  out.sendBefore = before.slice(0, 5);
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'precheck: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
