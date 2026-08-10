# rs_check_chat.ps1 — 读取当前聊天区全部消息 + 页面元素状态
$ErrorActionPreference = 'Stop'
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
$expr = @'
(() => {
  const out = {};
  // 聊天区所有消息
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  out.msgs = [];
  for (const c of Array.from(chats)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim();
    if (t) out.msgs.push(t.slice(0, 120));
  }
  // 输入框/发送按钮状态
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.input = input ? input.textContent : 'NO_INPUT';
  const sendBtn = document.querySelector('[data-e2e="dm-new-send-btn"]');
  out.sendBtn = sendBtn ? (sendBtn.offsetParent !== null ? 'visible' : 'hidden') : 'NO_BTN';
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  out.nick = nick ? nick.textContent.trim() : 'NO_NICK';
  // 会话列表
  const convs = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  out.convCount = convs.length;
  out.convNicks = Array.from(convs).slice(0, 4).map(c => (c.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 30));
  // 是否有弹窗/overlay
  out.overlays = document.querySelectorAll('[role="dialog"], [class*="modal"], [class*="popup"]').length;
  return JSON.stringify(out);
})()
'@
$r = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
if ($r.result.result.value) { Write-Host $r.result.result.value } else { Write-Host ($r | ConvertTo-Json -Compress -Depth 5) }
$ws.Dispose()
