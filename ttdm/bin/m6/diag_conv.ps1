# 诊断: 页面是否 reload + 手动注入 hook + 点击会话触发消息历史加载
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\inbox_hook2.txt"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$script:netReqs = @()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 25000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { break }
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
        if ($msg.method -eq "Network.requestWillBeSent") {
            $script:netReqs += @{ requestId = $msg.params.requestId; url = $msg.params.request.url; method = $msg.params.request.method }
        }
    }
    return $null
}
# 1. 诊断当前页面
$diag = @'
JSON.stringify({
  url: location.href,
  navType: performance.getEntriesByType('navigation')[0] ? performance.getEntriesByType('navigation')[0].type : '?',
  hooked: !!window.__allHooked,
  allLog: (window.__allLog||[]).length,
  urlLog: (window.__urlLog||[]).length
})
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $diag; returnByValue = $true }
Write-Host "=== 诊断 ==="
Write-Host $resp.result.result.value
# 2. 启用 Network 域 (捕获所有请求)
Invoke-Cdp $ws 2 "Network.enable" -timeoutMs 5000 | Out-Null
$script:netReqs = @()
# 3. 手动注入 hook (捕获 im 相关响应)
$hook = @'
(() => {
  if (window.__allHooked) return 'already';
  window.__allHooked = true;
  window.__allLog = [];
  const key = (u) => u.includes('im-api') || u.includes('/im/') || u.includes('message') || u.includes('conversation') || u.includes('tray');
  const log = (url, body, isReq) => {
    const u = String(url).slice(0, 400);
    if (!key(u)) return;
    window.__allLog.push({isReq, url: u, len: body ? body.length : 0, hasProbe: body ? body.includes('probe') : false, head: body ? body.slice(0, 800) : ''});
  };
  const OX = XMLHttpRequest.prototype.open;
  const OS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__u = String(u); return OX.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    const u = this.__u || '';
    if (key(u)) log(u, b, true);
    this.addEventListener('load', () => { try { if (key(this.__u || '')) log(this.__u, this.responseText || '', false); } catch(e) {} });
    return OS.apply(this, arguments);
  };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (key(u)) log(u, args[1] && typeof args[1].body === 'string' ? args[1].body : '', true);
    return of.apply(this, args).then(r => { if (key(u)) r.clone().text().then(t => log(u, t, false)).catch(() => {}); return r; });
  };
  return 'ok';
})()
'@
$resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $hook; returnByValue = $true }
Write-Host "hook: $($resp.result.result.value)"
# 4. 检查会话列表 + 点击目标会话
$clickExpr = @'
(() => {
  const u = document.querySelector('p[data-e2e="chat-uniqueid"]');
  if (u) return 'already-open:' + u.textContent;
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  if (!items.length) return 'no-items';
  for (const el of items) {
    if ((el.textContent||'').includes('17824815072124')) {
      const r = el.getBoundingClientRect();
      return 'click:' + Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
    }
  }
  return 'not-found';
})()
'@
$resp = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$state = $resp.result.result.value
Write-Host "state: $state"
if ($state -like 'click:*') {
    $p = $state.Substring(6).Split('|')
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 6 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 7 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Write-Host "clicked"
}
Start-Sleep -Seconds 6
# 5. 读取页面 hook 捕获
$resp = Invoke-Cdp $ws 8 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__allLog || [])'; returnByValue = $true }
$log = $resp.result.result.value
[IO.File]::WriteAllText($outFile, $log, [System.Text.Encoding]::UTF8)
$items = @()
try { $items = $log | ConvertFrom-Json } catch { }
Write-Host "=== 页面 hook 捕获: $($items.Count) ==="
foreach ($it in $items) {
    $mark = if ($it.hasProbe) { " <<< PROBE" } else { "" }
    Write-Host "$($it.url)$mark len=$($it.len)"
}
# 6. CDP Network 捕获汇总 (im 相关)
Write-Host "=== CDP 请求: $($script:netReqs.Count) ==="
foreach ($nr in $script:netReqs) {
    if ($nr.url -match "im-api|/im/|message|conversation|tray") {
        Write-Host "$($nr.method) $($nr.url.Substring(0, [Math]::Min(160, $nr.url.Length)))"
    }
}
$ws.Dispose()
