# 从私信列表页提取所有会话 uid + 名称 (DOM 扫描)
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
# 1. 导航到私信列表
Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
Start-Sleep -Seconds 4
# 2. 提取会话: 链接 href 含 messages?u= 的 a 标签 + 文本
$expr = @'
(() => {
  const out = [];
  const seen = new Set();
  document.querySelectorAll('a[href*="messages?u="], a[href*="/messages?user_id="]').forEach(a => {
    const href = a.href || '';
    const m = href.match(/messages\?u=(\d+)/);
    if (!m) return;
    const uid = m[1];
    if (seen.has(uid)) return;
    seen.add(uid);
    out.push(uid + ' | ' + (a.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 60));
  });
  if (out.length === 0) {
    // 兜底: 找 data-e2e 属性含 chat 的元素
    document.querySelectorAll('[data-e2e]').forEach(el => {
      const e2e = el.getAttribute('data-e2e') || '';
      if (e2e.indexOf('chat') >= 0 && e2e.indexOf('item') >= 0) {
        const t = (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 60);
        out.push('e2e=' + e2e + ' | ' + t);
      }
    });
  }
  return out.join('\n') || 'NO CONVERSATIONS FOUND';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 会话列表 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
