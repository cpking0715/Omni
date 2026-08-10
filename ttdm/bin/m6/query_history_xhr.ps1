# XHR 方式调用消息历史 API (页面 hook 显示 send 用 XHR 成功, 看 XHR 是否绕过 CORS)
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
$expr = @'
(async () => {
  const conv = '0:1:7366359960223482885:7664958044560016398';
  const q = 'aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const urls = [
    'https://im-api.tiktok.com/v1/message/get_by_conversation?' + q + '&conv_id=' + encodeURIComponent(conv) + '&cursor=0&limit=50',
    'https://im-api.tiktok.com/v1/message/get_by_user?' + q + '&cursor=0&limit=50',
    'https://im-api.tiktok.com/v1/conversation/get_list?' + q + '&cursor=0&limit=50'
  ];
  const out = [];
  for (const url of urls) {
    const result = await new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', url, true);
      xhr.withCredentials = true;
      xhr.onload = () => resolve({status: xhr.status, len: (xhr.responseText||'').length, body: (xhr.responseText||'').slice(0, 1500), type: xhr.responseType});
      xhr.onerror = () => resolve({status: 'XHR-ERR', body: 'network error'});
      xhr.ontimeout = () => resolve({status: 'TIMEOUT'});
      xhr.timeout = 15000;
      xhr.send();
    });
    out.push({url: url.slice(0, 170), ...result});
  }
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
$result = $resp.result.result.value
[IO.File]::WriteAllText("d:\MyProjects\OmniMarket\ttdm\bin\m6\msg_history_xhr.txt", $result, [System.Text.Encoding]::UTF8)
Write-Host $result
$ws.Dispose()
