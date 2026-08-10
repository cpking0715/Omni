# 全量 hook fetch/XHR (不过滤 URL) + 刷新页面, 找到消息列表 API 并检查 probe7
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\inbox_hook.txt"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 20000) {
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
    }
    return $null
}
# 1. 注入全量 hook (addScriptToEvaluateOnNewDocument: 刷新后依然存活)
$hook = @'
(() => {
  if (window.__allHooked) return 'already';
  window.__allHooked = true;
  window.__allLog = [];
  const key = (u) => u.includes('im-api') || u.includes('/im/') || u.includes('message') || u.includes('conversation') || u.includes('tray') || u.includes('graphql') || u.includes('msg/');
  const log = (url, body, isReq) => {
    const u = String(url).slice(0, 400);
    if (!key(u)) return;
    window.__allLog.push({
      isReq, url: u,
      len: body ? body.length : 0,
      hasProbe: body ? body.includes('probe') : false,
      head: body ? body.slice(0, 600) : ''
    });
  };
  const logAll = (url, isReq) => {
    const u = String(url).slice(0, 300);
    window.__urlLog = window.__urlLog || [];
    if (window.__urlLog.length < 500) window.__urlLog.push((isReq ? 'REQ' : 'RES') + ' ' + u);
  };
  const OX = XMLHttpRequest.prototype.open;
  const OS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__u = String(u); logAll(u, true); return OX.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(b) {
    const u = this.__u || '';
    if (key(u)) log(u, b, true);
    this.addEventListener('load', () => {
      try {
        logAll(this.__u || '', false);
        if (key(this.__u || '')) log(this.__u, this.responseText || '', false);
      } catch(e) {}
    });
    return OS.apply(this, arguments);
  };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    logAll(u, true);
    const body = args[1] && args[1].body;
    if (key(u)) log(u, typeof body === 'string' ? body : '', true);
    return of.apply(this, args).then(r => {
      if (key(u)) r.clone().text().then(t => log(u, t, false)).catch(() => {});
      return r;
    });
  };
  return 'ok';
})()
'@
$resp = Invoke-Cdp $ws 1 "Page.addScriptToEvaluateOnNewDocument" @{ source = $hook }
Write-Host "scriptId: $($resp.result.identifier)"
# 2. 刷新页面
Invoke-Cdp $ws 2 "Page.reload" @{ ignoreCache = $true } -timeoutMs 5000 | Out-Null
Write-Host "reloading..."
Start-Sleep -Seconds 15
# 3. 读取日志
$resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify({all: window.__allLog || [], urls: window.__urlLog || [], hooked: !!window.__allHooked})'; returnByValue = $true }
$log = $resp.result.result.value
[IO.File]::WriteAllText($outFile, $log, [System.Text.Encoding]::UTF8)
Write-Host "saved -> $outFile ($($log.Length) chars)"
# 4. 汇总输出
$parsed = $log | ConvertFrom-Json
$items = $parsed.all
Write-Host "hooked=$($parsed.hooked) 匹配请求=$($items.Count) 全部请求=$($parsed.urls.Count)"
$i = 0
foreach ($it in $items) {
    $i++
    $mark = if ($it.hasProbe) { " <<< PROBE" } else { "" }
    $bodyInfo = if ($it.isReq) { "REQ" } else { "RES len=$($it.len)" }
    Write-Host "[$i] $bodyInfo hasProbe=$($it.hasProbe) $($it.url)$mark"
}
Write-Host "=== 全部请求 URL (前 40) ==="
$j = 0
foreach ($u in $parsed.urls) {
    $j++
    if ($j -gt 40) { break }
    Write-Host $u
}
$ws.Dispose()
