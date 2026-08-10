# rs_nosign_first3.ps1 — 最终验证 v3: 短文本 Hello + 空 meta vs 有 meta, 排除内容审核/快照过期干扰
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_nosign_first3.json"
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

$bWithMeta = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" -to 6769042968499995650 -text "Hello"
$bEmpty = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" -empty -to 6769042968499995650 -text "Hello"
$log += 'bodies: meta=' + $bWithMeta.Trim().Length + ' empty=' + $bEmpty.Trim().Length

$expr = @"
(async () => {
  const out = {};
  const cases = [
    { name: 'G_hello_meta', b64: '$($bWithMeta.Trim())' },
    { name: 'H_hello_emptymeta', b64: '$($bEmpty.Trim())' },
  ];
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  for (const c of cases) {
    try {
      const bin = atob(c.b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const r = await fetch(url, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/x-protobuf' }, body: bytes });
      const ab = await r.arrayBuffer();
      const s = new TextDecoder().decode(ab);
      const m = s.match(/\"status_code\":(\d+)/);
      const tips = s.match(/\"tips\":\"([^\"]{0,120})/);
      out[c.name] = { http: r.status, biz: m ? m[1] : '', tips: tips ? tips[1] : '' };
    } catch (e) { out[c.name] = { err: String(e).slice(0, 200) }; }
    await new Promise(r2 => setTimeout(r2, 2000));
  }
  return JSON.stringify(out);
})()
"@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true; timeout = 45000 }
$log += 'result: ' + $r1.result.result.value
$ws.Dispose()

@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
