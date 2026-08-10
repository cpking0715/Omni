# 检查当前页面: 输入框/错误提示/限制横幅/会话预览
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok\.com") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 65536
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
  const ed = document.querySelector('[data-e2e="message-input-area"] [contenteditable="true"]') || document.querySelector('div.DraftEditor-root [contenteditable="true"]');
  out.editorText = ed ? (ed.textContent||ed.innerText||'') : 'no-editor';
  // 所有提示/警告/横幅
  const tips = [];
  document.querySelectorAll('[data-e2e*="tip"], [data-e2e*="warning"], [data-e2e*="fail"], [role="alert"], [data-e2e*="notice"]').forEach(el => {
    const t = (el.textContent||'').trim().replace(/\s+/g,' ').slice(0,120);
    if (t) tips.push(t);
  });
  out.tips = tips;
  // 页面文本中含 "send" 的提示
  const all = document.body.innerText || '';
  const idx = all.indexOf('can only send');
  out.limitMsg = idx >= 0 ? all.slice(idx, idx+130).replace(/\n+/g,' | ') : 'none';
  // 会话预览
  const convs = document.querySelectorAll('[data-e2e="dm-new-conversation-item"]');
  out.firstConv = convs.length ? convs[0].textContent.trim().replace(/\s+/g,' ').slice(0,80) : '';
  return JSON.stringify(out);
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== 页面状态 ==="
Write-Host $resp.result.result.value
$shot = Invoke-Cdp $ws 2 "Page.captureScreenshot" @{ format = "png" }
[IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\state_check.png", [Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
