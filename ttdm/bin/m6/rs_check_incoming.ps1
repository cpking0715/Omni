# rs_check_incoming.ps1 — 检查是否有"对方发来消息"的会话 (已接受请求 → 无签名第2条对照)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_incoming.json"
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
# 遍历 4 个会话, 打开后检查聊天区消息气泡方向 (incoming 表示对方发来)
$expr = @'
(async () => {
  const out = [];
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  for (let i = 0; i < items.length && i < 4; i++) {
    const el = items[i];
    const nick = el.querySelector('[data-e2e="dm-new-conversation-nickname"]');
    const n = nick ? nick.textContent.trim() : ('conv' + i);
    el.click();
    await new Promise(r => setTimeout(r, 2500));
    const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
    let hasIncoming = false, incomingCount = 0;
    for (const c of chats) {
      const cls = (c.className || '').toString();
      // 常见方向标记: 左对齐/右侧或 class 含 incoming/self
      if (/left|incoming|receiver/i.test(cls)) { hasIncoming = true; incomingCount++; }
    }
    const input = !!document.querySelector('[data-e2e="dm-new-input-editor"]');
    out.push({ i, nick: n, chats: chats.length, incoming: incomingCount, hasIncoming, input });
  }
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'convs: ' + $r1.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
