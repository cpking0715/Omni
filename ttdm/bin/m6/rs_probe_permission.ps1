# rs_probe_permission.ps1 — 最快验证: 页面内取会话列表 uid + 逐个跑 chat/notice 权限检查
# 目标: 找到还有额度(chat_stranger_check=3条)的会话 → 无签名发第2条即可验证成功路径
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_permission.json"
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

# 1. 从页面内存/网络拿 4 个会话的 toUID: 先试 im-api conversation list 常见端点
$expr1 = @'
(async () => {
  const out = {};
  const tries = [
    'https://im-api.tiktok.com/v1/conversation/list?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc&cursor=0&count=20&media_type=0&scene=profile',
    'https://im-api.tiktok.com/v1/message/conversation/list?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc&count=20'
  ];
  for (let i = 0; i < tries.length; i++) {
    try {
      const r = await fetch(tries[i], { credentials: 'include', headers: { 'accept': 'application/json' } });
      const t = await r.text();
      out['try' + i] = { status: r.status, len: t.length, head: t.slice(0, 300) };
    } catch (e) { out['try' + i + 'err'] = String(e).slice(0, 200); }
  }
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; awaitPromise = $true; returnByValue = $true }
$log += 'convs: ' + $r1.result.result.value

# 2. 若上面失败, 尝试从页面点击会话后的 DOM/状态或 performance 拿 conversation id
$expr2 = @'
(() => {
  const out = [];
  try {
    const entries = performance.getEntriesByType('resource');
    for (const e of entries) {
      const n = String(e.name);
      if (n.includes('im-api')) out.push(n.slice(0, 300));
    }
  } catch (e) {}
  return JSON.stringify(out.slice(-10));
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true }
$log += 'im-api-entries: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
