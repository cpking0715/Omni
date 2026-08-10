# rs_capture.ps1 — js-reverse Capture 阶段: 运行时采样 frontierSign 签名输出 (2026-08 reverse-skill 会话)
# 调用页面官方签名入口 frontierSign(url), 与 sign_snapshot.json 对比验证动态生成
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

# 采样1: 对真实发送端点 URL 签名 (与浏览器发消息时一致)
$expr1 = @'
(async () => {
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const out = { url };
  try {
    const r = await window.byted_acrawler.frontierSign(url);
    out.result = r;
    out.type = typeof r;
  } catch (e) { out.err = String(e).slice(0, 500); }
  return JSON.stringify(out);
})()
'@

$resp1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true; awaitPromise = $true }
Write-Host "=== Capture 采样1: frontierSign(message/send URL) ==="
$v1 = $resp1.result.result.value
if ($v1) { $v1 | Out-File -FilePath "d:\MyProjects\OmniMarket\ttdm\bin\m6\rs_capture1.json" -Encoding utf8; Write-Host $v1.Substring(0, [Math]::Min(600, $v1.Length)) } else { Write-Host ($resp1 | ConvertTo-Json -Compress -Depth 6) }

# 采样2: 无参数调用 (观察默认行为)
$expr2 = @'
(async () => {
  const out = {};
  try {
    const r = await window.byted_acrawler.frontierSign('');
    out.emptyResult = r;
  } catch (e) { out.emptyErr = String(e).slice(0, 300); }
  return JSON.stringify(out);
})()
'@
$resp2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true; awaitPromise = $true }
Write-Host "=== Capture 采样2: frontierSign('') ==="
if ($resp2.result.result.value) { Write-Host $resp2.result.result.value.Substring(0, [Math]::Min(400, $resp2.result.result.value.Length)) } else { Write-Host ($resp2 | ConvertTo-Json -Compress -Depth 6) }

$ws.Dispose()
