# rs_search_api.ps1 — 页面上下文直接调 TikTok 搜索 API, 拿未联系用户 uid
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_searchapi.json"
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
# 用之前抓到的真实搜索 URL 模板 (从 out_search.json 的 net log), 替换 keyword 为 tiktok
$expr = @'
(async () => {
  const out = {};
  const base = 'https://www.tiktok.com/api/search/general/preview/?WebIdLastTime=1785656072&aid=1988&app_language=en&app_name=tiktok_web&browser_language=en-US&browser_name=Mozilla&browser_online=true&browser_platform=Win32&browser_version=5.0%20%28Windows%20NT%2010.0%3B%20Win64%3B%20x64%29%20AppleWebKit%2F537.36%20%28KHTML%2C%20like%20Gecko%29%20Chrome%2F149.0.0.0%20Safari%2F537.36&channel=tiktok_web&cookie_enabled=true&data_collection_enabled=true&device_id=7669334412366218765&device_platform=web_pc&focus_state=true&from_page=user&history_len=14&is_fullscreen=false&is_page_visible=true&keyword=tiktok&language=en&os=windows&priority_region=US&region=US&root_referer=https%3A%2F%2Fwww.tiktok.com%2Fmessages&screen_height=1067&screen_width=1707&tz_name=America%2FLos_Angeles&user_is_login=true&webcast_language=en&browser_language=en-US&app_language=en&webcast_language=en&device_id=7669334412366218765&verifyFp=verify_msd57ogu_DzQuW7jI_Qyks_4bnD_9A6r_qpHE8ymsH3St&os=windows&priority_region=US&region=US&type=1';
  try {
    const r = await fetch(base, { credentials: 'include', headers: { 'accept': 'application/json' } });
    const t = await r.text();
    out.status = r.status;
    out.len = t.length;
    out.head = t.slice(0, 1500);
  } catch (e) { out.err = String(e).slice(0, 300); }
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
$log += 'search-api: ' + $r1.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
