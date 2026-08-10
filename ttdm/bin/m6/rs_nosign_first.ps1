# rs_nosign_first.ps1 — 最终验证: 新接收方无签名发第 1 条 (期望 status=0)
# body 用 mkbody.exe -to 6769042968499995650 生成 (未联系过的 royyen 主号)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_nosign_first.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 60000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 2097152
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
    return $null
}
$log = @()

# 新 body: 目标 royyen 主号 (未联系过)
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" -to 6769042968499995650 -text "rs-nosign-first"
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
    const tips = s.match(/\"tips\":\"([^\"]{0,200})/);
    out.tips = tips ? tips[1] : '';
    out.bodyHead = s.slice(0, 300);
  } catch (e) {
    out.error = String(e).slice(0, 300);
  }
  return JSON.stringify(out);
})()
"@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true; timeout = 45000 }
$log += 'nosign-first result: ' + $r1.result.result.value
$ws.Dispose()

@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
