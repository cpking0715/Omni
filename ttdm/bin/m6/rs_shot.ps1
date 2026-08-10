# rs_shot.ps1 — 截图当前页面
$ErrorActionPreference = 'Stop'
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$req = @{ id = 1; method = "Page.captureScreenshot"; params = @{ format = "png" } }
$json = $req | ConvertTo-Json -Compress -Depth 8
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$seg = [ArraySegment[byte]]::new($bytes)
$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
$buf = New-Object byte[] 2097152
while ($true) {
    $ms = [System.IO.MemoryStream]::new()
    do {
        $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $ms.Write($buf, 0, $result.Count)
    } while (-not $result.EndOfMessage)
    $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $msg = $t2 | ConvertFrom-Json
    if ($msg.id -eq 1) {
        $b64 = $msg.result.data
        [IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\rs_state.png", [Convert]::FromBase64String($b64))
        Write-Host "saved: rs_state.png"
        break
    }
}
$ws.Dispose()
