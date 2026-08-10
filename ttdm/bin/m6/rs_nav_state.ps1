# rs_nav_state.ps1 — 截图 + 读取页面状态 (诊断 u= 参数导航结果)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_navstate.json"
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
# 页面状态
$expr = @'
(() => {
  const out = {};
  out.url = location.href.slice(0, 150);
  out.title = document.title;
  out.bodyText = document.body.innerText.slice(0, 400);
  // 会话列表是否存在
  out.convList = !!document.querySelector('[data-e2e="dm-new-conversation-list"]');
  out.convCount = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]').length;
  // 是否有报错组件
  out.errorEl = document.querySelector('[data-e2e="dm-error"], [class*="Error"], [class*="error"]');
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$log += 'state: ' + $r1.result.result.value
# 截图
$r2 = Invoke-Cdp $ws 2 "Page.captureScreenshot" @{ format = "png" }
if ($r2.result -and $r2.result.data) {
    [IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\rs_navstate.png", [Convert]::FromBase64String($r2.result.data))
    $log += 'shot: saved'
}
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
