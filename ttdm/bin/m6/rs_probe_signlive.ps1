# rs_probe_signlive.ps1 — Patch: 页面内实时采样 frontierSign 返回结构 + 真实 message/send 请求头
# 目的: 拿到页面权威签名(URL X-Bogus / header X-Gnarly X-Dynosaur), 作为三变体对照的真值
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_signlive.json"
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

# 1. 页面对象面: byted_acrawler / webmssdk 是否存在
$expr1 = @'
(() => {
  const out = {};
  out.hasAcrawler = typeof window.byted_acrawler !== 'undefined';
  out.hasWebmssdk = typeof window.webmssdk !== 'undefined';
  if (window.byted_acrawler) {
    out.acrawlerKeys = Object.keys(window.byted_acrawler).slice(0, 20);
    out.signImpl = typeof window.byted_acrawler.sign;
  }
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$log += 'obj: ' + $r1.result.result.value

# 2. frontierSign 实时调用: url 模式 + body 模式, 记录完整返回
$expr2 = @'
(async () => {
  const out = {};
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  try {
    const r = await window.byted_acrawler.frontierSign(url);
    out.urlMode = (typeof r === 'string') ? r.slice(0, 2000) : JSON.stringify(r).slice(0, 2000);
  } catch (e) { out.urlModeErr = String(e).slice(0, 300); }
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; awaitPromise = $true; returnByValue = $true }
$log += 'frontierSign: ' + $r2.result.result.value

# 3. 若返回含 X-Bogus, 提取真实值备用
$expr3 = @'
(async () => {
  const url = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  try {
    const r = await window.byted_acrawler.frontierSign(url);
    const s = (typeof r === 'string') ? r : JSON.stringify(r);
    const m = s.match(/X-Bogus[:=]"?([A-Za-z0-9_\-]{20,})/);
    return m ? m[1] : 'no-match';
  } catch (e) { return 'err:' + String(e).slice(0, 200); }
})()
'@
$r3 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr3; awaitPromise = $true; returnByValue = $true }
$log += 'x-bogus: ' + $r3.result.result.value

# 4. 采样真实 message/send 请求头(若页面近期发过): 从 performance entries
$expr4 = @'
(() => {
  const out = [];
  try {
    const entries = performance.getEntriesByType('resource');
    for (const e of entries) {
      if (String(e.name).includes('im-api') && String(e.name).includes('message/send')) {
        out.push({ url: e.name.slice(0, 400), dur: Math.round(e.duration) });
      }
    }
  } catch (e) { out.push({ err: String(e).slice(0, 200) }); }
  return JSON.stringify(out.slice(-5));
})()
'@
$r4 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr4; returnByValue = $true }
$log += 'perf-entries: ' + $r4.result.result.value

$ws.Dispose()

@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
