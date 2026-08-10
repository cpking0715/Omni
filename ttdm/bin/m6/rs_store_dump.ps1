# rs_store_dump.ps1 — 从页面内存 store 直接读会话数据 (conv id / uid)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_storedump.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 30000) {
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

# 1. __bytedImCallTrace 是什么
$expr1 = @'
(() => {
  const out = {};
  const t = window.__bytedImCallTrace;
  out.type = typeof t;
  if (t) {
    out.keys = Object.keys(t).slice(0, 20);
    try { out.json = JSON.stringify(t).slice(0, 500); } catch (e) { out.json = String(t).slice(0, 300); }
  }
  // 找 DOM 里所有含 '0:1:' 或 19位数字 的文本/属性
  const found = [];
  document.querySelectorAll('[class*="conv"], [class*="chat"], [class*="dm"]').forEach(el => {
    const s = (el.getAttribute('class') || '') + ' ' + (el.textContent || '').slice(0, 50);
    if (/0:1:\d+:\d+/.test(s)) found.push(s.slice(0, 80));
  });
  out.convTexts = found.slice(0, 10);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$log += 'trace: ' + $r1.result.result.value

# 2. 搜索 React fiber / store: 从任意元素找内部属性
$expr2 = @'
(() => {
  const out = [];
  const el = document.querySelector('[data-e2e="dm-new-conversation-item"]');
  if (el) {
    const keys = Object.keys(el);
    for (const k of keys) {
      if (k.startsWith('__react')) {
        try {
          let f = el[k];
          let depth = 0;
          while (f && depth < 3) {
            const memo = f.memoizedProps || {};
            const s = JSON.stringify(memo).slice(0, 400);
            if (/0:1:|\d{15,}/.test(s)) out.push({ key: k, depth, sample: s });
            f = f.return;
            depth++;
          }
        } catch (e) {}
      }
    }
  }
  return JSON.stringify(out.slice(0, 6));
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
$log += 'fiber: ' + $r2.result.result.value

# 3. 检查 WS 连接帧 (im-ws 推送的会话数据) — 通过 hook WebSocket 抓已收数据
$expr3 = @'
(() => {
  const out = {};
  out.wsCount = 0;
  try {
    // 检查现有 WebSocket 实例 (通过 performance 拿 ws url)
    const ents = performance.getEntriesByType('resource').filter(e => String(e.name).includes('ws'));
    out.wsUrls = ents.map(e => String(e.name).slice(0, 200)).slice(0, 5);
  } catch (e) { out.err = String(e).slice(0, 100); }
  return JSON.stringify(out);
})()
'@
$r3 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr3; returnByValue = $true }
$log += 'ws: ' + $r3.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
