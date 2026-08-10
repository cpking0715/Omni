# rs_combo_call.ps1 — 直接调用 im-api get_by_user_combo 创建/获取新用户会话
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_combocall.json"
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
# 尝试 GET/POST get_by_user_combo: 参数用 sec_uid 或 user_id
$expr = @'
(async () => {
  const out = {};
  const q = 'aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const tries = [
    'https://im-api.tiktok.com/v1/message/get_by_user_combo?' + q + '&user_id=7479823623491208199',
    'https://im-api.tiktok.com/v1/message/get_by_user_combo?' + q + '&sec_uid=MS4wLjABAAAA5dZUDBRIjeMQefidPx',
    'https://im-api.tiktok.com/v1/message/get_by_user_combo?' + q + '&unique_id=royyen_3'
  ];
  for (let i = 0; i < tries.length; i++) {
    try {
      const r = await fetch(tries[i], { credentials: 'include', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: '' });
      const t = await r.text();
      out['t' + i] = { status: r.status, len: t.length, head: t.slice(0, 500) };
    } catch (e) { out['t' + i + 'err'] = String(e).slice(0, 200); }
  }
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
$log += 'combo-call: ' + $r1.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
