# rs_perm_check.ps1 — 最快验证: 页面内点击会话抓 conv_id → chat/notice 权限检查 → 找有额度会话
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_permcheck.json"
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

# 1. hook XHR 记录 im-api 请求 URL (拿 conv_id)
$hookExpr = @'
(() => {
  if (window.__convUrls) return 'already';
  window.__convUrls = [];
  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    if (String(u).includes('im-api') || String(u).includes('conv')) {
      window.__convUrls.push(String(u).slice(0, 500));
      if (window.__convUrls.length > 50) window.__convUrls.shift();
    }
    return origOpen.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 2. 依次点击 4 个会话, 每次等 2.5s 让页面发请求
$expr = @'
(async () => {
  const items = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]');
  const nicks = [];
  for (let i = 0; i < items.length && i < 4; i++) {
    const nick = items[i].querySelector('[data-e2e="dm-new-conversation-nickname"]');
    nicks.push(nick ? nick.textContent.trim() : ('conv' + i));
    items[i].click();
    await new Promise(r => setTimeout(r, 2500));
  }
  return JSON.stringify(nicks);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'nicks: ' + $r1.result.result.value

# 3. 读取捕获的 conv urls
$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__convUrls || [])'; returnByValue = $true }
$log += 'conv-urls: ' + $r2.result.result.value

# 4. 页面内对每个会话跑 chat/notice (ttdm CheckImPermission 的 Web 直连版)
$noticeExpr = @'
(async () => {
  const out = [];
  const convs = (window.__convUrls || []).filter(u => u.includes('conv_id=') || u.includes('conversation'));
  const seen = new Set();
  for (const u of convs) {
    let m = u.match(/conv_id=([^&]+)/);
    if (!m) m = u.match(/conversation[\/=]([^&]+)/);
    if (!m) continue;
    let conv = decodeURIComponent(m[1]);
    if (seen.has(conv)) continue;
    seen.add(conv);
    const parts = conv.split(':');
    const toUID = parts.length >= 3 ? parts[2] : '?';
    // chat/notice 接口 (与 ttdm tiktokapi.CheckImPermission 同构)
    try {
      const url = 'https://api16-normal-useast5.tiktokv.us/tiktok/v1/im/chat/notice/?to_user_id=' + toUID + '&conversation_id=' + encodeURIComponent(conv) + '&source_type=dm_chat&aid=1233&app_name=musical_ly&version_code=250203';
      const r = await fetch(url, { credentials: 'include', headers: { 'sdk-version': '2', 'accept': 'application/json' } });
      const t = await r.text();
      let notice = '';
      const nm = t.match(/"notice_code"\s*:\s*("[^"]*"|\[[^\]]*\])/);
      if (nm) notice = nm[1];
      out.push({ conv: conv.slice(0, 60), toUID, status: r.status, notice, head: t.slice(0, 200) });
    } catch (e) { out.push({ conv: conv.slice(0, 60), toUID, err: String(e).slice(0, 150) }); }
  }
  return JSON.stringify(out);
})()
'@
$r3 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $noticeExpr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'notice: ' + $r3.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
