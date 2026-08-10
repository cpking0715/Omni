# rs_observe3.ps1 — js-reverse Observe: 检查 window.secsdk API 与签名生成入口
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
  const out = {};
  out.secsdkType = typeof window.secsdk;
  if (window.secsdk) {
    out.secsdkKeys = Object.keys(window.secsdk);
    const methods = {};
    for (const k of Object.keys(window.secsdk)) {
      const v = window.secsdk[k];
      if (typeof v === 'function') {
        methods[k] = v.toString().slice(0, 300);
      } else if (v && typeof v === 'object') {
        methods[k + ':{' + Object.keys(v).join(',') + '}'] = '';
      } else {
        methods[k] = String(v).slice(0, 100);
      }
    }
    out.secsdkDetail = methods;
  }
  // _FETCH_SDK_INIT_SECSDK 的值
  out.fetchSdkInit = String(window._FETCH_SDK_INIT_SECSDK).slice(0, 200);
  return JSON.stringify(out);
})()
'@

$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== Observe3: secsdk 结构 ==="
if ($resp.result.result.value) { Write-Host $resp.result.result.value } else { Write-Host ($resp | ConvertTo-Json -Compress -Depth 6) }
$ws.Dispose()
