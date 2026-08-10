# rs_ui_map.ps1 — 截图 + 映射 messages 页面 UI 结构 (新建会话入口/搜索面板)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uimap.json"
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

# 1. 回到 messages 首页
$null = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = 'window.location.href = "https://www.tiktok.com/messages?lang=en"; "nav"' ; returnByValue = $true }
$log += 'nav-home'
Start-Sleep -Seconds 9

# 2. 读取主界面结构: 会话列表区域所有可点击元素 (带 data-e2e)
$expr = @'
(() => {
  const out = {};
  out.url = location.href.slice(0, 110);
  // 会话列表区容器
  const list = document.querySelector('[data-e2e="dm-new-conversation-list"]');
  out.listExists = !!list;
  // 列表区所有可见可点击元素
  const els = [];
  (list || document).querySelectorAll('[data-e2e], button, [role="button"]').forEach(el => {
    const r = el.getBoundingClientRect();
    if (el.offsetParent !== null && r.width > 5 && r.height > 5) {
      const e2e = (el.getAttribute('data-e2e') || '').slice(0, 50);
      const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40);
      els.push({ e2e, txt, x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
    }
  });
  out.elements = els.slice(0, 25);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$log += 'map: ' + $r1.result.result.value

# 3. 截图
$r2 = Invoke-Cdp $ws 3 "Page.captureScreenshot" @{ format = "png" }
if ($r2.result -and $r2.result.data) {
    [IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\rs_uimap.png", [Convert]::FromBase64String($r2.result.data))
    $log += 'shot: saved'
}

# 4. 点击搜索框(打开搜索面板) 再截图
$expr2 = @'
(() => {
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) return 'no input';
  input.click();
  return 'search-focused';
})()
'@
$r3 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
$log += 'search: ' + $r3.result.result.value
Start-Sleep -Seconds 3
$r4 = Invoke-Cdp $ws 5 "Page.captureScreenshot" @{ format = "png" }
if ($r4.result -and $r4.result.data) {
    [IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\rs_uimap_search.png", [Convert]::FromBase64String($r4.result.data))
    $log += 'shot2: saved'
}
# 搜索面板 DOM
$r5 = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = @'
(() => {
  const out = [];
  document.querySelectorAll('[role="dialog"], [class*="search"], [class*="Search"], [data-e2e*="search"]').forEach(el => {
    const r = el.getBoundingClientRect();
    if (el.offsetParent !== null) {
      out.push({ e2e: (el.getAttribute('data-e2e')||'').slice(0,40), cls: (el.className||'').toString().slice(0,50),
        txt: (el.textContent||'').replace(/\s+/g,' ').trim().slice(0,50),
        x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
    }
  });
  return JSON.stringify(out.slice(0, 12));
})()
'@; returnByValue = $true }
$log += 'search-panel: ' + $r5.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
