# 探测页面签名能力: byted_acrawler / webmssdk 全局 / 签名函数可调用性
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
  const out = {};
  out.byted_acrawler = typeof window.byted_acrawler;
  if (window.byted_acrawler) {
    out.acrawlerKeys = Object.keys(window.byted_acrawler).join(',');
    if (window.byted_acrawler.sign) {
      out.signExists = true;
    }
  }
  const globals = [];
  for (const k in window) {
    if (/byted|acrawler|gnarly|dynosaur|bogus|sign|webms/i.test(k)) globals.push(k);
  }
  out.globals = globals.join(',');
  // 尝试调用 byted_acrawler.sign (若无害) 生成 X-Bogus
  try {
    if (window.byted_acrawler && window.byted_acrawler.sign) {
      out.trySign = window.byted_acrawler.sign('https://im-api.tiktok.com/v1/message/send?aid=1988');
    }
  } catch (e) { out.trySignErr = String(e).slice(0, 200); }
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 签名能力探测 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
