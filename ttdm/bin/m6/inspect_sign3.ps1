# 探测 frontierSign 完整参数组合 (url+method+headers+body)
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
(async () => {
  const out = {};
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const body = new Uint8Array([0x08,0x64]).buffer; // 最小 protobuf body
  const cases = [
    ['full_obj', {url, method: 'POST', headers: {'content-type': 'application/x-protobuf'}, body}],
    ['url_str_2nd', [url, {method: 'POST', body, headers: {'content-type': 'application/x-protobuf'}}]],
    ['params_mode', {url, method: 'POST', params: {aid: '1988'}, body}],
  ];
  for (const [name, arg] of cases) {
    try {
      const r = await (Array.isArray(arg) ? window.byted_acrawler.frontierSign(...arg) : window.byted_acrawler.frontierSign(arg));
      out[name] = (typeof r === 'string' ? r : JSON.stringify(r)).slice(0, 800);
    } catch (e) { out[name + '_err'] = String(e).slice(0, 200); }
  }
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
Write-Host "=== frontierSign 完整参数 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
