# 耐心轮询会话列表: 导航后每 2s 检查 dm-new-conversation-item, 最多 40s
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; Write-Host "page: $($t.url)"; break }
}
if (-not $wsUrl) { Write-Host "no tiktok page target!"; exit 1 }
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
# 若不在 messages 页则导航
$stateExpr = 'JSON.stringify({href: location.href, items: document.querySelectorAll("[data-e2e=\"dm-new-conversation-item\"]").length})'
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $stateExpr; returnByValue = $true }
$st = $resp.result.result.value | ConvertFrom-Json
if ($st.href -notmatch "messages") {
    Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
}
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $resp = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $stateExpr; returnByValue = $true }
    $st = $resp.result.result.value | ConvertFrom-Json
    Write-Host "t=$($i*2)s items=$($st.items) href=$($st.href)"
    if ($st.items -gt 0) { break }
}
# 提取 uid (fiber + 文本)
$expr = @'
(() => {
  const out = [];
  const safeStr = (v, depth) => {
    try {
      if (depth > 3) return JSON.stringify(v && typeof v === 'object' ? Object.keys(v) : v);
      return JSON.stringify(v);
    } catch (e) { return '[circular]'; }
  };
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  for (const el of items) {
    try {
      const name = (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,30);
      const keys = Object.keys(el);
      const fiberKey = keys.find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      let found = '';
      if (fiberKey) {
        let fiber = el[fiberKey];
        for (let depth = 0; fiber && depth < 15; depth++, fiber = fiber.return) {
          const mp = fiber.memoizedProps;
          if (!mp) continue;
          // 只挑可能含 uid 的字段检查, 避免循环引用
          const candidates = ['uid','userId','conversationId','targetUser','chatUser','user','peer','conversation','profile'];
          let m = null;
          for (const c of candidates) {
            const v = mp[c];
            if (typeof v === 'string' && /^\d{9,}$/.test(v)) { m = [c, v]; break; }
            if (v && typeof v === 'object') {
              const s = safeStr(v, 0);
              const mm = s.match(/\"?id\"?\s*:\s*\"?(\d{9,})/);
              if (mm) { m = [c, mm[1]]; break; }
            }
          }
          if (m) { found = m[0] + '=' + m[1] + ' @d' + depth; break; }
          if (typeof fiber.key === 'string' && /^\d{9,}$/.test(fiber.key)) { found = 'key=' + fiber.key + ' @d' + depth; break; }
        }
      }
      out.push(name + ' => ' + (found || 'no-uid'));
    } catch (e) { out.push('ERR ' + e.message); }
  }
  return out.join('\n') || 'no items';
})()
'@
$resp = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 会话 uid (fiber) ==="
Write-Host $resp.result.result.value
$ws.Dispose()
