# 决定性实验: hook 页面 WebSocket 推送 + Go 发送 probe8, 验证 204 是否真入队
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 30000) {
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
# 1. hook WebSocket onmessage + send
$hook = @'
(() => {
  if (window.__wsHooked) return 'already';
  window.__wsHooked = true;
  window.__wsLog = [];
  const log = (dir, data) => {
    try {
      const s = typeof data === 'string' ? data : (data && data.data && typeof data.data === 'string' ? data.data : '');
      if (s && s.length < 20000) window.__wsLog.push({dir, t: s.slice(0, 4000)});
    } catch(e) {}
  };
  const origAdd = EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener = function(type, fn, opts) {
    if (this instanceof WebSocket) {
      const wrap = (ev) => { log('IN', ev); return fn.call(this, ev); };
      return origAdd.call(this, type, wrap, opts);
    }
    return origAdd.call(this, type, fn, opts);
  };
  const origSend = WebSocket.prototype.send;
  WebSocket.prototype.send = function(data) {
    log('OUT', data);
    return origSend.call(this, data);
  };
  return 'ok';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hook; returnByValue = $true }
Write-Host "ws hook: $($resp.result.result.value)"
Start-Sleep -Seconds 2
# 2. 清理已有日志 (只保留发送后的)
Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = 'window.__wsLog = []' } | Out-Null
# 3. Go 发送 probe8
Write-Host "=== 发送 probe8 ==="
$sendOut = & "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command 'cd "d:\MyProjects\OmniMarket\ttdm"; & "$env:LOCALAPPDATA\Programs\Go\go\bin\go.exe" run ".\cmd\websend" "d:\MyProjects\OmniMarket\ttdm\bin\m6\sign_snapshot.json" "d:\MyProjects\OmniMarket\ttdm\bin\m6\account.json" "probe8 - ws verification"' 2>&1
Write-Host $sendOut
Start-Sleep -Seconds 8
# 4. 读取 WS 日志
$resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify({count: (window.__wsLog||[]).length, logs: (window.__wsLog||[]).slice(-20)})'; returnByValue = $true }
$wsLog = $resp.result.result.value
[IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\ws_log.txt", $wsLog, [System.Text.Encoding]::UTF8)
Write-Host "=== WS 日志 (发送后) ==="
Write-Host $wsLog
$ws.Dispose()
