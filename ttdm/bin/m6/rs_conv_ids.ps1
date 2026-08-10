# rs_conv_ids.ps1 — hook fetch+XHR 抓 conv_id; 点击会话; 读聊天区 data 属性
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_convids.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 45000) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 2097152
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $t2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $t2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
    return $null
}
$log = @()
$hookExpr = @'
(() => {
  if (window.__netLog) return 'already';
  window.__netLog = [];
  const push = (kind, u) => {
    if (window.__netLog.length > 100) window.__netLog.shift();
    window.__netLog.push(kind + '|' + String(u).slice(0, 400));
  };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (String(u).includes('im-api') || String(u).includes('conv') || String(u).includes('notice')) push('F', u);
    return of.apply(this, args);
  };
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    if (String(u).includes('im-api') || String(u).includes('conv') || String(u).includes('notice')) push('X', u);
    return oo.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

$expr = @'
(async () => {
  const out = {};
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  out.count = items.length;
  const nicks = [];
  for (let i = 0; i < items.length && i < 4; i++) {
    const nick = items[i].querySelector('[data-e2e="dm-new-conversation-nickname"]');
    nicks.push(nick ? nick.textContent.trim() : ('conv' + i));
    items[i].click();
    await new Promise(r => setTimeout(r, 2000));
  }
  out.nicks = nicks;
  // 聊天区 data 属性
  const chatItems = document.querySelectorAll('[data-e2e="dm-new-chat-item"]');
  out.chatAttrs = [];
  for (const c of chatItems) {
    const attrs = {};
    for (const a of c.attributes) attrs[a.name] = a.value.slice(0, 100);
    out.chatAttrs.push(attrs);
  }
  // 页面全局对象上的会话数据线索
  out.globals = Object.keys(window).filter(k => /conv|chat|im|dm/i.test(k)).slice(0, 30);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'dom: ' + $r1.result.result.value

$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__netLog || [])'; returnByValue = $true }
$log += 'net: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
