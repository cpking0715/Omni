# 一次性脚本:从已登录 AdsPower 浏览器提取 @tiktok 官方账号的 uid
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"

# 1. 启动/附加浏览器,拿 debug port
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
if ($start.code -ne 0) { Write-Host "start failed: $($start.msg)"; exit 1 }
$port = $start.data.debug_port
Write-Host "debug port: $port"

# 2. 找 tiktok 页面 target
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
if (-not $wsUrl) { $wsUrl = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1 -ExpandProperty webSocketDebuggerUrl }
if (-not $wsUrl) { Write-Host "no page target"; exit 1 }
Write-Host "page ws: $wsUrl"

# 3. WebSocket 会话
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$uri = [System.Uri]::new($wsUrl)
$ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$id = 0
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    # 读响应直到 id 匹配
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

# 4. 导航到 @tiktok 主页
$null = Invoke-Cdp $ws 1 "Page.navigate" @{ url = "https://www.tiktok.com/@tiktok" }
Start-Sleep -Seconds 8

# 5. 提取 uid: 从 __UNIVERSAL_DATA_FOR_REHYDRATION__ 或 link canonical 等
$expr = @'
(() => {
  try {
    const el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
    if (el) {
      const d = JSON.parse(el.textContent);
      const u = d.__DEFAULT_SCOPE__?.['webapp.user-detail']?.userInfo?.user;
      if (u) return JSON.stringify({uid: u.id, uniqueId: u.uniqueId, nickname: u.nickname});
    }
  } catch(e) {}
  // fallback: 从页面任意含 uid 的链接/属性找 9-20 位数字
  const m = document.documentElement.outerHTML.match(/"id"\s*:\s*"?(\d{9,20})/);
  if (m) return JSON.stringify({uid: m[1], via: 'regex'});
  return 'NO_UID';
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$val = $resp.result.result.value
Write-Host "RESULT: $val"
$ws.Dispose()
