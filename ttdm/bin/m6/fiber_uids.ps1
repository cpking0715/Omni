# 从 React fiber 提取会话项 uid (绕过 DOM 点击)
# 1. 导航到私信列表并等待加载
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
# 导航到私信列表并等待加载
Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = "location.href = 'https://www.tiktok.com/messages'" } | Out-Null
Start-Sleep -Seconds 6
$diag = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = 'JSON.stringify({href: location.href, items: document.querySelectorAll("[data-e2e=\"dm-new-conversation-item\"]").length, body: document.body ? document.body.innerText.slice(0,80) : "no-body"})'; returnByValue = $true }
Write-Host "DIAG: $($diag.result.result.value)"
# 2. 从 React fiber 提取会话项 uid
$expr = @'
(() => {
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  const out = [];
  for (const el of items) {
    const name = (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,30);
    // 挖 React fiber: 向上找 key/uid/memoizedProps
    let node = el;
    let found = {};
    const keys = Object.keys(el);
    const fiberKey = keys.find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
    if (fiberKey) {
      let fiber = el[fiberKey];
      for (let depth = 0; fiber && depth < 12; depth++, fiber = fiber.return) {
        const mp = fiber.memoizedProps;
        if (!mp) continue;
        const propsStr = JSON.stringify(mp);
        // 找含长数字串 (uid) 的字段
        const uidMatch = propsStr.match(/"uid"\s*:\s*"?(\d{10,})"?/) || propsStr.match(/"conversationId"\s*:\s*"?(\d{10,})"?/);
        const keyMatch = propsStr.match(/"(user|targetUser|chatUser|peer|profile|conversation)":\s*\{[^}]*?"id"\s*:\s*"?(\d{9,})"?/);
        if (uidMatch || keyMatch) {
          found = {uid: (uidMatch ? uidMatch[1] : keyMatch[2]), depth: depth};
          break;
        }
        // key 属性可能是 uid
        if (typeof fiber.key === 'string' && /^\d{10,}$/.test(fiber.key)) {
          found = {uid: fiber.key, depth: depth, fromKey: true};
          break;
        }
      }
    }
    out.push(name + ' => ' + (found.uid ? ('uid=' + found.uid + ' (depth ' + found.depth + (found.fromKey ? ' key' : '') + ')') : 'no-uid'));
  }
  return out.join('\n');
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 会话 uid (fiber) ==="
Write-Host $resp.result.result.value
$ws.Dispose()
