# rs_recover.ps1 — reload 恢复页面 + 等待 + 检查聊天区; 若恢复则 UI 发送并采样响应
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture9.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=k1fan6kh" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
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

# reload (连接会断, 无妨)
try {
    $ws0 = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws0.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $req = @{ id = 1; method = "Runtime.evaluate"; params = @{ expression = "location.reload(); 'ok'"; returnByValue = $true } }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($req | ConvertTo-Json -Compress -Depth 8))
    $ws0.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $ws0.Dispose()
    $log += 'reload sent'
} catch { $log += 'reload err: ' + $_.Exception.Message }
Start-Sleep -Seconds 14

# 检查聊天区
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$checkExpr = @'
(() => {
  const out = {};
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.input = !!input;
  const err = document.body.innerText.match(/Something went wrong/i);
  out.errPanel = !!err;
  const convs = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  out.convCount = convs.length;
  return JSON.stringify(out);
})()
'@
$r = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
$log += 'check: ' + $r.result.result.value
$ws.Dispose()

$result = @{ log = $log }
$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
