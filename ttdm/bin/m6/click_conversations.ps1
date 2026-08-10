# 逐个点击会话列表项, 从 URL/页面读取会话 uid
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
# 找会话列表容器
$listExpr = @'
(() => {
  const items = [];
  // 常见容器
  const containers = ['[data-e2e="chat-list"]', '[data-e2e="dm-list"]', '[data-e2e="chat-conversation-list"]'];
  let box = null;
  for (const s of containers) { box = document.querySelector(s); if (box) break; }
  if (!box) {
    // 兜底: 找包含 4 个会话文本的最近公共祖先太复杂, 直接列所有含 aria-label 或 role=button 的列表项
    document.querySelectorAll('[role="listitem"], [data-e2e]').forEach(el => {
      const e2e = el.getAttribute('data-e2e') || '';
      if (e2e.indexOf('chat') >= 0) items.push('e2e=' + e2e + ' :: ' + (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,40));
    });
    return JSON.stringify({box: 'none', items: items.slice(0,15)});
  }
  const children = box.querySelectorAll(':scope > div');
  children.forEach(c => {
    items.push((c.textContent||'').trim().replace(/\s+/g,' ').slice(0,40));
  });
  return JSON.stringify({box: box.tagName + '.' + String(box.className).slice(0,50), count: children.length, items: items.slice(0,10)});
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $listExpr; returnByValue = $true }
Write-Host "LIST: $($resp.result.result.value)"

# 点击每个会话项, 读 URL
$clickExpr = @'
(i) => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  if (i >= items.length) return 'OUT_OF_RANGE';
  const c = items[i];
  const name = (c.textContent||'').trim().replace(/\s+/g,' ').slice(0,30);
  const r = c.getBoundingClientRect();
  return JSON.stringify({name: name, x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
}
'@
$results = @()
for ($i = 0; $i -lt 6; $i++) {
    $resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "($clickExpr)($i)"; returnByValue = $true }
    $clickInfo = $resp.result.result.value
    if ($clickInfo -eq 'OUT_OF_RANGE') { break }
    $ci = $clickInfo | ConvertFrom-Json
    if (-not $ci.x) { Write-Host "item $i : $clickInfo"; continue }
    # 坐标点击
    Invoke-Cdp $ws 2 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = $ci.x; y = $ci.y; button = "left"; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $ci.x; y = $ci.y; button = "left"; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 2
    $resp = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = 'JSON.stringify({u: location.href, uniqueid: (document.querySelector("[data-e2e=\"chat-uniqueid\"]")||{}).textContent || ""})'; returnByValue = $true }
    $parsed = $resp.result.result.value | ConvertFrom-Json
    $href = $parsed.u
    $uid = $null
    if ($href -match "messages\?u=(\d+)") { $uid = $Matches[1] }
    if (-not $uid) { $uid = $parsed.uniqueid }
    $results += "$($ci.name) | uid=$uid | $href"
    # 返回列表页
    Invoke-Cdp $ws 5 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
    Start-Sleep -Seconds 2
}
Write-Host "=== 会话 uid ==="
$results | ForEach-Object { Write-Host $_ }
$ws.Dispose()
