# rs_capture12.ps1 — 页面上下文内 fetch 发送 message/send (无签名): 浏览器环境对照
# 在页面 JS 里 fetch (走 webmssdk 拦截层 + 页面 cookie), 记录响应业务码
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture12.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 1048576
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}
$log = @()

# 新 body (有 meta 版本, 与实验 A 相同构造)
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" "rs-pagefetch-test"
$log += 'body b64 len: ' + $b64.Trim().Length

$expr = @"
(async () => {
  const out = {};
  const b64 = '$($b64.Trim())';
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  try {
    const r = await fetch(url, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/x-protobuf' },
      body: bytes,
    });
    out.httpStatus = r.status;
    const ab = await r.arrayBuffer();
    const s = new TextDecoder().decode(ab);
    const m = s.match(/\"status_code\":(\d+)/);
    out.bizCode = m ? m[1] : '';
    out.bodyHead = s.slice(0, 120);
  } catch (e) {
    out.error = String(e).slice(0, 300);
  }
  return JSON.stringify(out);
})()
"@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
$log += 'page fetch result: ' + $r1.result.result.value
$ws.Dispose()

@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
