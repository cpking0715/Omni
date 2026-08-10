# 抓取 94659.e7bddb5d.js 中消息 API 端点的完整上下文 (base URL + 参数)
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
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 60000) {
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
$s = "https://lf16-tiktok-web.tiktokcdn-us.com/obj/tiktok-web-tx/tiktok/webapp/main/react-v18/webapp-desktop/static/js/async/94659.e7bddb5d.js"
# 抓取 bundle, 提取端点附近 300 字符上下文 + 搜索 base URL (https:// 或 /api/ 前缀)
$fetchExpr = @'
(async () => {
  const t = await (await fetch('https://lf16-tiktok-web.tiktokcdn-us.com/obj/tiktok-web-tx/tiktok/webapp/main/react-v18/webapp-desktop/static/js/async/94659.e7bddb5d.js')).text();
  const keys = ['get_by_conversation_with_range', 'conversation/get_list', 'conversation/create', 'get_by_conversation_search'];
  const out = {};
  for (const k of keys) {
    const i = t.indexOf(k);
    if (i >= 0) {
      out[k] = t.slice(Math.max(0, i - 300), i + 200);
    }
  }
  // 搜索 im-api base URL
  const bases = [];
  let idx = 0;
  while ((idx = t.indexOf('im-api', idx)) >= 0 && bases.length < 5) {
    bases.push(t.slice(Math.max(0, idx - 100), idx + 100));
    idx += 10;
  }
  out.bases = bases;
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $fetchExpr; returnByValue = $true; awaitPromise = $true }
$result = $resp.result.result.value
[IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\api_context.txt", $result, [System.Text.Encoding]::UTF8)
Write-Host $result
$ws.Dispose()
