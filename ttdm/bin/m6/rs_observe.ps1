# rs_observe.ps1 — js-reverse Observe 阶段: 采样 byted_acrawler 签名入口 (2026-08 reverse-skill 会话)
# 用法: pwsh rs_observe.ps1
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
  try { out.frontierSignSrc = window.byted_acrawler.frontierSign.toString().slice(0, 3000); } catch (e) { out.frontierSignErr = String(e); }
  try { out.isWebmssdk = window.byted_acrawler.isWebmssdk(); } catch (e) { out.isWebmssdkErr = String(e); }
  try { out.getReferer = window.byted_acrawler.getReferer(); } catch (e) { out.getRefererErr = String(e); }
  return JSON.stringify(out);
})()
'@

$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== Observe: byted_acrawler 入口 ==="
if ($resp.result.result.value) { Write-Host $resp.result.result.value } else { Write-Host ($resp | ConvertTo-Json -Compress -Depth 6) }
$ws.Dispose()
