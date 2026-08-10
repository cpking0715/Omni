# rs_enum_convs.ps1 — 枚举会话列表: 昵称 + 打开后读聊天区最近消息 (找可发送会话)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_convs.json"
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

# 1) 枚举会话项 (昵称)
$expr1 = @'
(() => {
  const out = [];
  document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]').forEach((el, i) => {
    const nick = el.querySelector('[data-e2e="dm-new-conversation-nickname"]');
    const t = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    out.push({ i, nick: nick ? nick.textContent.trim() : '', text: t });
  });
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$convItems = @()
if ($r1.result.result.value) { $convItems = $r1.result.result.value | ConvertFrom-Json }
Write-Host ("会话数: " + $convItems.Count)

# 2) 逐个点击 + 读聊天区
$details = @()
foreach ($item in $convItems) {
    $expr2 = @"
(async () => {
  const els = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  const el = els[$($item.i)];
  if (!el) return 'no el';
  el.click();
  await new Promise(r => setTimeout(r, 2500));
  const chats = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  const msgs = [];
  for (const c of Array.from(chats).slice(-4)) {
    const t = (c.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    if (t) msgs.push(t);
  }
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  return JSON.stringify({ nick: nick ? nick.textContent.trim() : '', msgs, input: !!input, msgs_count: chats.length });
})()
"@
    $r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true; awaitPromise = $true }
    if ($r2.result.result.value) {
        $d = $r2.result.result.value | ConvertFrom-Json
        $details += @{ i = $item.i; nick = $item.nick; text = $item.text; detail = $d }
        Write-Host ("会话 $($item.i) [$($item.nick)]: msgs=$($d.msgs_count) input=$($d.input) last=$($d.msgs[-1])")
    }
    Start-Sleep -Seconds 1
}
$ws.Dispose()
@{ conversations = $details } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
