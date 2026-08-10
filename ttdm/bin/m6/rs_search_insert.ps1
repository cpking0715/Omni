# rs_search_insert.ps1 — 用 insertText 真实输入搜索框 (React 受控组件) 打开新会话
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_searchinsert.json"
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

# 1. 找到搜索框坐标 (侧边栏顶部)
$coordExpr = @'
(() => {
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) return 'no search input';
  const r = input.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: Math.round(r.width), h: Math.round(r.height) });
})()
'@
$rc = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $coordExpr; returnByValue = $true }
$coord = $rc.result.result.value
$log += 'coord: ' + $coord

if ($coord -and $coord -ne 'no search input') {
    $p = $coord | ConvertFrom-Json
    # 2. 真实点击搜索框
    $null = Invoke-Cdp $ws 2 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $p.x; y = $p.y; button = "none" }
    $null = Invoke-Cdp $ws 2 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $p.x; y = $p.y; button = "left"; buttons = 1; clickCount = 1 }
    $null = Invoke-Cdp $ws 2 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $p.x; y = $p.y; button = "left"; buttons = 0; clickCount = 1 }
    Start-Sleep -Milliseconds 600
    # 3. insertText 输入 royyen_3
    $null = Invoke-Cdp $ws 3 "Input.insertText" @{ text = "royyen_3" }
    $log += 'typed: royyen_3'
    Start-Sleep -Seconds 5
    # 4. 读取搜索结果建议
    $expr = @'
(() => {
  const out = { sugg: [], inputVal: '' };
  const input = document.querySelector('[data-e2e="search-user-input"]');
  out.inputVal = input ? input.value : '';
  // 搜索结果: 建议列表项 (含头像)
  const cands = [];
  document.querySelectorAll('li, [role="option"], [data-e2e*="sug"], [data-e2e*="search-result"], [data-e2e*="user-item"]').forEach(el => {
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    const hasAvatar = !!el.querySelector('img');
    const r = el.getBoundingClientRect();
    const vis = el.offsetParent !== null;
    if (txt && vis && (hasAvatar || /royyen/.test(txt)) && txt.length < 80) {
      cands.push({ e2e: (el.getAttribute('data-e2e') || '').slice(0, 50), txt, avatar: hasAvatar,
        x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) });
    }
  });
  out.sugg = cands.slice(0, 12);
  return JSON.stringify(out);
})()
'@
    $r1 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
    $log += 'sugg: ' + $r1.result.result.value
    $ws.Dispose()
    @{ log = $log } | ConvertTo-Json -Depth 10 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile"
} else {
    $ws.Dispose()
    @{ log = $log; err = 'no search input' } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
    Write-Host "written: $outFile (no input)"
}
