# rs_signed_newconv.ps1 — 对照: 快照签名三件套(X-Bogus=1+X-Gnarly+X-Dynosaur+msToken)发新接收方
# 若返回 7193/其他业务码而非 7195 → 签名影响风控路径; 若同 7195 → 内容审核与签名无关
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_signednew.json"
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

# 新接收方 body (royyen_3: 7479823623491208199)
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" -to 7479823623491208199 -text "Hello"
$log += 'body b64 len: ' + $b64.Trim().Length

# 快照签名三件套
$snap = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\sign_snapshot.json" -Raw | ConvertFrom-Json
$base = "https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc"
$signedUrl = "$base&X-Dynosaur=$($snap.sign.x_dynosaur)&msToken=$($snap.sign.ms_token)&X-Bogus=1&X-Gnarly=$($snap.sign.x_gnarly)"
$log += 'signed-url-len: ' + $signedUrl.Length

$expr = @"
(async () => {
  const out = {};
  const b64 = '$($b64.Trim())';
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const cases = [
    { name: 'I_signed_newconv', url: '$($signedUrl)' },
    { name: 'J_nosign_newconv', url: 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc' },
  ];
  for (const c of cases) {
    try {
      const r = await fetch(c.url, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/x-protobuf' }, body: bytes });
      const ab = await r.arrayBuffer();
      const s = new TextDecoder().decode(ab);
      const m = s.match(/\"status_code\":(\d+)/);
      const tips = s.match(/\"tips\":\"([^\"]{0,160})/);
      out[c.name] = { http: r.status, biz: m ? m[1] : '', tips: tips ? tips[1] : '' };
    } catch (e) { out[c.name] = { err: String(e).slice(0, 200) }; }
    await new Promise(r2 => setTimeout(r2, 2500));
  }
  return JSON.stringify(out);
})()
"@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true; awaitPromise = $true; timeout = 45000 }
$log += 'result: ' + $r1.result.result.value
$ws.Dispose()

@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
