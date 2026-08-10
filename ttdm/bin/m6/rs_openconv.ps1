# rs_openconv.ps1 — 点击会话 0 并检查聊天区; 若可用则继续 UI 发送对照
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture10.json"
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
$clickExpr = @'
(() => {
  const els = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  if (els.length === 0) return 'no convs';
  els[0].click();
  return 'clicked';
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $clickExpr; returnByValue = $true }
$log += 'click: ' + $r1.result.result.value
Start-Sleep -Seconds 4
$checkExpr = @'
(() => {
  const out = {};
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.input = !!input;
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  out.nick = nick ? nick.textContent.trim() : '';
  out.err = /Something went wrong/i.test(document.body.innerText);
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  out.msgCount = chats.length;
  const overlay = document.querySelectorAll('[role="dialog"]').length;
  out.overlays = overlay;
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
$log += 'check: ' + $r2.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
