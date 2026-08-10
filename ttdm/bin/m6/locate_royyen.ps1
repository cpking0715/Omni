# 定位包含会话文本的元素及其祖先链, 找出可点击的会话项
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
$expr = @'
(() => {
  const out = [];
  // 找含 royyen 文本的元素
  const all = document.querySelectorAll('*');
  for (const el of all) {
    if (el.children.length === 0 && (el.textContent || '').trim() === 'royyen') {
      // 向上找有宽度/可点击的祖先
      let node = el;
      const chain = [];
      for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
        const r = node.getBoundingClientRect();
        chain.push({
          tag: node.tagName,
          cls: String(node.className || '').slice(0, 70),
          e2e: node.getAttribute && node.getAttribute('data-e2e'),
          role: node.getAttribute && node.getAttribute('role'),
          w: Math.round(r.width), h: Math.round(r.height),
          x: Math.round(r.x), y: Math.round(r.y)
        });
      }
      out.push(JSON.stringify(chain));
      break; // 只分析第一个
    }
  }
  return out.join('\n') || 'royyen text not found';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== royyen 元素祖先链 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
