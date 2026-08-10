# hook fetch/XHR + 滚动消息历史, 捕获消息列表 API 响应, 权威验证 probe7 是否在服务端
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
# 1. 注入 fetch/XHR 响应 hook
$hookExpr = @'
(() => {
  window.__respLog = [];
  const log = (url, len, body) => {
    if (window.__respLog.length > 200) return;
    window.__respLog.push({url: String(url).slice(0, 220), len, hasProbe: body.includes('probe'), head: body.slice(0, 1500)});
  };
  const origFetch = window.fetch;
  if (origFetch && !window.__respHooked) {
    window.fetch = function(...args) {
      const url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
      return origFetch.apply(this, args).then(r => {
        if (url.includes('im-api') || url.includes('message') || url.includes('conversation') || url.includes('/im/')) {
          r.clone().text().then(t => log(url, t.length, t)).catch(() => {});
        }
        return r;
      });
    };
    window.__respHooked = true;
  }
  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  if (!window.__xhrHooked) {
    XMLHttpRequest.prototype.open = function(m, u) { this.__url = u; return origOpen.apply(this, arguments); };
    XMLHttpRequest.prototype.send = function(...args) {
      this.addEventListener('load', () => {
        const u = this.__url || '';
        if (u.includes('im-api') || u.includes('message') || u.includes('conversation') || u.includes('/im/')) {
          try { log(u, (this.responseText||'').length, this.responseText || ''); } catch(e) {}
        }
      });
      return origSend.apply(this, arguments);
    };
    window.__xhrHooked = true;
  }
  return 'hooked';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
Write-Host "hook: $($resp.result.result.value)"
# 2. 确保会话已打开 (若未打开则点击)
$checkExpr = @'
(() => {
  const u = document.querySelector('p[data-e2e="chat-uniqueid"]');
  if (u) return 'open:' + u.textContent;
  const items = document.querySelectorAll('[data-e2e="dm-new-conversation-item"], [data-e2e="conversation-item"]');
  for (const el of items) {
    if ((el.textContent||'').includes('17824815072124')) {
      const r = el.getBoundingClientRect();
      return 'click:' + Math.round(r.x + r.width/2) + '|' + Math.round(r.y + r.height/2);
    }
  }
  return 'not-found';
})()
'@
$resp = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $checkExpr; returnByValue = $true }
$state = $resp.result.result.value
Write-Host "state: $state"
if ($state -like 'click:*') {
    $p = $state.Substring(6).Split('|')
    Invoke-Cdp $ws 3 "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = [int]$p[0]; y = [int]$p[1] } | Out-Null
    Invoke-Cdp $ws 4 "Input.dispatchMouseEvent" @{ type = "mousePressed"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-Cdp $ws 5 "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = [int]$p[0]; y = [int]$p[1]; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
    Start-Sleep -Seconds 5
}
# 3. 滚动消息历史触发加载 (多个可能容器 + 滚轮)
$scrollExpr = @'
(() => {
  const scrollers = [];
  document.querySelectorAll('div').forEach(d => {
    if (d.scrollHeight > d.clientHeight + 100 && d.clientHeight > 200) scrollers.push(d);
  });
  let scrolled = 0;
  for (const s of scrollers.slice(0, 4)) {
    s.scrollTop = 0; scrolled++;
    s.scrollTop = s.scrollHeight; scrolled++;
  }
  return 'scrolled containers: ' + scrolled;
})()
'@
$resp = Invoke-Cdp $ws 6 "Runtime.evaluate" @{ expression = $scrollExpr; returnByValue = $true }
Write-Host $resp.result.result.value
Start-Sleep -Seconds 3
$resp = Invoke-Cdp $ws 7 "Runtime.evaluate" @{ expression = $scrollExpr; returnByValue = $true }
Write-Host $resp.result.result.value
Start-Sleep -Seconds 4
# 4. 读取捕获的响应
$readExpr = @'
(() => {
  const items = window.__respLog || [];
  const probes = items.filter(i => i.hasProbe).map(i => ({url: i.url, len: i.len, head: i.head.slice(0, 400)}));
  const imApi = items.filter(i => !i.hasProbe).map(i => ({url: i.url, len: i.len}));
  return JSON.stringify({probes: probes.slice(0, 10), imApi: imApi.slice(0, 20)});
})()
'@
$resp = Invoke-Cdp $ws 8 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
Write-Host "=== 捕获的响应 ==="
Write-Host $resp.result.result.value
$ws.Dispose()
