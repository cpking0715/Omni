# 截图当前页面状态 + 检查聊天面板 DOM 结构
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
# 页面 URL + 聊天面板 DOM 概览
$expr = @'
(() => {
  const u = document.querySelector('p[data-e2e="chat-uniqueid"]');
  const input = document.querySelector('[data-e2e="chat-input"], [data-e2e="dm-input"], div[contenteditable="true"]');
  const sendBtn = document.querySelector('svg[aria-label="Send"]');
  const msgEls = document.querySelectorAll('[data-e2e="message-item"], [data-e2e="chat-message"]');
  const convItems = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  const scrollers = [];
  document.querySelectorAll('div').forEach(d => {
    if (d.scrollHeight > d.clientHeight + 50 && d.clientHeight > 100) scrollers.push({h: d.clientHeight, sh: d.scrollHeight});
  });
  return JSON.stringify({
    url: location.href.slice(0, 120),
    uniqueid: u ? u.textContent : null,
    hasInput: !!input,
    hasSendBtn: !!sendBtn,
    msgElCount: msgEls.length,
    convCount: convItems.length,
    scrollers: scrollers.slice(0, 5),
    bodySnippet: document.body.innerText.slice(0, 300)
  });
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "=== DOM 状态 ==="
Write-Host $resp.result.result.value
# 截图
$shot = Invoke-Cdp $ws 2 "Page.captureScreenshot" @{ format = "png" }
[System.IO.File]::WriteAllBytes("d:\MyProjects\OmniMarket\ttdm\bin\m6\state_probe7.png", [System.Convert]::FromBase64String($shot.result.data))
Write-Host "screenshot saved"
$ws.Dispose()
