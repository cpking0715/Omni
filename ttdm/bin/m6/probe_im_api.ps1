# 从 performance entries + 页面内 fetch 拉取会话列表 (同源无 CORS)
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
if (-not $wsUrl) { $wsUrl = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1 -ExpandProperty webSocketDebuggerUrl }
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 65536
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}
# 1. 列出含 im 的 API 请求
$expr1 = 'JSON.stringify(performance.getEntriesByType("resource").map(e=>e.name).filter(u=>/api|im|dm|message/i.test(u)).slice(0,40))'
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
Write-Host "=== API 请求 ==="
$resp.result.result.value | ConvertFrom-Json | ForEach-Object { Write-Host ($_.Substring(0, [Math]::Min(160, $_.Length))) }
# 2. 页面内 fetch 会话列表 API (尝试常见端点)
$fetchExpr = @'
(async () => {
  const endpoints = [
    'https://www.tiktok.com/api/im/fetch/conversations/?count=20',
    'https://www.tiktok.com/api/im/fetch/threads/?count=20',
    'https://www.tiktok.com/api/im/fetch/inbox/?count=20'
  ];
  const out = [];
  for (const ep of endpoints) {
    try {
      const r = await fetch(ep, {credentials: 'include'});
      const t = await r.text();
      out.push(ep + ' => HTTP ' + r.status + ' len=' + t.length + ' head=' + t.slice(0, 120));
    } catch(e) { out.push(ep + ' => ERR ' + e.message); }
  }
  return out.join('\n');
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $fetchExpr; awaitPromise = $true; returnByValue = $true }
Write-Host "=== fetch 探测 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
