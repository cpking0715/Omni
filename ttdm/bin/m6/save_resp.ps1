# POST 消息历史 API 并把原始响应体存为 base64 文件 (供 decodeframe 解码)
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
    'https://im-api.tiktok.com/v1/conversation/get_list?' + q + '&cursor=0&limit=50'
  ];
  const out = [];
  for (const url of urls) {
    const result = await new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', url, true);
      xhr.withCredentials = true;
      xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
      xhr.responseType = 'arraybuffer';
      xhr.onload = () => {
        const u8 = new Uint8Array(xhr.response);
        let bin = '';
        for (let i = 0; i < u8.length; i += 8192) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 8192));
        resolve({status: xhr.status, len: u8.length, b64: btoa(bin), type: xhr.getResponseHeader('Content-Type')});
      };
      xhr.onerror = () => resolve({status: 'XHR-ERR'});
      xhr.ontimeout = () => resolve({status: 'TIMEOUT'});
      xhr.timeout = 15000;
      xhr.send('');
    });
    out.push({url: url.slice(0, 170), ...result});
  }
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
$result = $resp.result.result.value | ConvertFrom-Json
$i = 0
foreach ($r in $result) {
    $i++
    Write-Host "=== [$i] $($r.url) status=$($r.status) len=$($r.len) type=$($r.type) ==="
    if ($r.b64) {
        $b64File = "d:\MyProjects\OmniMarket\ttdm\bin\m6\resp_$i.b64"
        [IO.File]::WriteAllText($b64File, $r.b64, [System.Text.Encoding]::ASCII)
        Write-Host "saved -> $b64File"
    }
}
$ws.Dispose()
