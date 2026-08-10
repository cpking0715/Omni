# 在页面中搜索 access_key 值的来源: HTML / 全局变量 / localStorage / sessionStorage
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=$userId" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
$wsUrl = $null
foreach ($t in $targets) {
    if ($t.type -eq "page" -and $t.url -match "tiktok") { $wsUrl = $t.webSocketDebuggerUrl; break }
}
if (-not $wsUrl) { $wsUrl = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1 -ExpandProperty webSocketDebuggerUrl }
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
  const needles = ['08ac725d2a9a3fac7cc3a25bb7a44aec', 'c23b210eec9aeb43c4ea9b36eeaf7a19'];
  const out = [];
  // 1. HTML 源码
  const html = document.documentElement.outerHTML;
  for (const n of needles) {
    const idx = html.indexOf(n);
    if (idx >= 0) out.push('HTML: ' + n + ' @' + idx + ' ctx=' + html.slice(Math.max(0,idx-80), idx+80));
  }
  // 2. script 标签文本 (内联 JS)
  document.querySelectorAll('script:not([src])').forEach(s => {
    const t = s.textContent || '';
    for (const n of needles) {
      const idx = t.indexOf(n);
      if (idx >= 0) out.push('inline-script: ' + n + ' ctx=' + t.slice(Math.max(0,idx-100), idx+100).replace(/\s+/g,' '));
    }
  });
  // 3. localStorage / sessionStorage
  for (const [sname, st] of [['localStorage', localStorage], ['sessionStorage', sessionStorage]]) {
    for (let i = 0; i < st.length; i++) {
      const k = st.key(i);
      const v = st.getItem(k) || '';
      for (const n of needles) {
        if (v.indexOf(n) >= 0) out.push(sname + '[' + k + ']: contains ' + n);
      }
      if (k.indexOf('access') >= 0) out.push(sname + '[key=' + k + ']: ' + v.slice(0, 120));
    }
  }
  // 4. 全局对象键名含 access 的
  const g = Object.keys(window).filter(k => k.toLowerCase().indexOf('access') >= 0 || k.toLowerCase().indexOf('sdk') >= 0);
  out.push('global keys: ' + g.join(', '));
  return out.join('\n---\n') || 'NOT FOUND ANYWHERE';
})()
'@
$resp = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
Write-Host "RESULT:"
Write-Host $resp.result.result.value
$ws.Dispose()
