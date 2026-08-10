# rs_observe4.ps1 — js-reverse Observe: 检查 messages 页 DOM 结构 (找会话列表选择器)
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
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
  // 找含 e2e 属性的元素
  const els = document.querySelectorAll('[data-e2e]');
  const e2e = {};
  els.forEach(el => {
    const k = el.getAttribute('data-e2e');
    if (!e2e[k]) e2e[k] = 0;
    e2e[k]++;
  });
  // 找会话列表容器
  const containers = [];
  document.querySelectorAll('div[role="list"], div[role="tablist"], nav, aside').forEach(el => {
    const r = el.getBoundingClientRect();
    if (r.width > 200) containers.push(el.tagName + '.' + (el.className && el.className.toString ? el.className.toString().slice(0, 60) : ''));
  });
  return JSON.stringify({ e2e: Object.keys(e2e).slice(0, 60), containers: containers.slice(0, 10) });
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== DOM 结构 ==="
if ($resp.result.result.value) { Write-Host $resp.result.result.value } else { Write-Host ($resp | ConvertTo-Json -Compress -Depth 6) }
$ws.Dispose()
