# rs_compare_send.ps1 — js-reverse Patch: 无签名 vs 快照签名 vs 新X-Bogus 对照发送实验
# 判定: im-api message/send 是否真的需要 URL 签名参数; 新 X-Bogus 是否可替代快照
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_compare_send.json"
$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$userId = "k1fan6kh"
$text = "rs-sign-compare"

$results = @()

# 1. 浏览器 cookie
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
        $text2 = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text2 | ConvertFrom-Json
        if ($msg.id -eq $i) { return $msg }
    }
}
$resp = Invoke-Cdp $ws 1 "Network.getAllCookies" $null
$cookies = @()
foreach ($c in $resp.result.cookies) {
    if ($c.domain -match "tiktok\.(com|us|v)$|tiktokw\.us|tiktokv\.us") { $cookies += "$($c.name)=$($c.value)" }
}
$cookieStr = $cookies -join "; "
$ws.Dispose()
Write-Host "cookie count: $($cookies.Count)"

# 2. 新 body (新 UUID + 随机序号)
$b64 = & "d:\MyProjects\OmniMarket\ttdm\bin\m6\mkbody.exe" $text
$body = [Convert]::FromBase64String($b64.Trim())
Write-Host "body len: $($body.Length)"

# 3. 快照签名
$snap = Get-Content "d:\MyProjects\OmniMarket\ttdm\bin\m6\sign_snapshot.json" -Raw | ConvertFrom-Json

# 4. 新 X-Bogus (Node 沙箱生成)
$newBogus = ""
$bogusOut = "d:\MyProjects\OmniMarket\ttdm\bin\m6\jsrebuild\out_bogus.txt"
$bogusExpr = @"
(async () => {
  const r = await window.byted_acrawler.frontierSign('https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc');
  return JSON.stringify(r);
})()
"@
# 复用 loader4 逻辑: 写临时 js 调用沙箱
$loader = @'
'use strict';
const fs = require('fs');
const vm = require('vm');
const sandbox = {};
sandbox.window = sandbox; sandbox.self = sandbox; sandbox.top = sandbox; sandbox.parent = sandbox; sandbox.globalThis = sandbox;
sandbox.navigator = { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36', platform: 'Win32', language: 'en-US', languages: ['en-US'], maxTouchPoints: 0, webdriver: false };
sandbox.location = { href: 'https://www.tiktok.com/messages?lang=en', protocol: 'https:', host: 'www.tiktok.com', hostname: 'www.tiktok.com', pathname: '/messages', search: '?lang=en', origin: 'https://www.tiktok.com' };
sandbox.document = { cookie: '', referrer: '', title: 'TikTok', readyState: 'complete', createElement: () => ({ style: {}, setAttribute() {}, getContext: () => null }), getElementById: () => null, querySelector: () => null, addEventListener() {}, removeEventListener() {}, dispatchEvent: () => true, documentElement: { style: {} }, body: { style: {} }, hidden: false, visibilityState: 'visible' };
sandbox.screen = { width: 1707, height: 1067, colorDepth: 24, pixelDepth: 24 };
sandbox.history = { length: 14 };
for (const k of ['Uint8Array','Uint16Array','Uint32Array','Int8Array','Int16Array','Int32Array','Float32Array','Float64Array','ArrayBuffer','SharedArrayBuffer','DataView','TextEncoder','TextDecoder','crypto','setTimeout','clearTimeout','setInterval','clearInterval','queueMicrotask','console','fetch','Headers','Request','Response','URL','URLSearchParams','Event','Error','TypeError','RangeError','SyntaxError','Date','Math','JSON','Object','Array','String','Number','Boolean','RegExp','Promise','Symbol','Map','Set','WeakMap','WeakSet','Proxy','Reflect','atob','btoa','isNaN','parseInt','parseFloat','Infinity','NaN','BigInt','AbortController','AbortSignal','MessageChannel','MessagePort']) { if (typeof globalThis[k] !== 'undefined') sandbox[k] = globalThis[k]; }
sandbox.Buffer = Buffer;
sandbox.performance = globalThis.performance;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync('./webmssdk.js', 'utf8'), sandbox, { filename: 'webmssdk.js' });
const r = vm.runInContext(`(async () => {
  const u = 'https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc';
  const r = await window.byted_acrawler.frontierSign(u);
  return JSON.stringify(r);
})()`, sandbox);
Promise.resolve(r).then(v => { fs.writeFileSync('out_bogus.txt', v); console.log('bogus:', v); });
'@
$loader | Out-File -FilePath "d:\MyProjects\OmniMarket\ttdm\bin\m6\jsrebuild\gen_bogus.js" -Encoding utf8
Push-Location "d:\MyProjects\OmniMarket\ttdm\bin\m6\jsrebuild"
node gen_bogus.js
Pop-Location
Start-Sleep -Milliseconds 800
if (Test-Path $bogusOut) {
    $bogusJson = Get-Content $bogusOut -Raw | ConvertFrom-Json
    $newBogus = $bogusJson.'X-Bogus'
}
Write-Host "new X-Bogus: $newBogus"

# 5. 三变体发送
$base = "https://im-api.tiktok.com/v1/message/send?aid=1988&version_code=1.0.0&app_name=tiktok_web&device_platform=web_pc"
$variantA = $base  # 无签名
$variantB = "$base&X-Dynosaur=$($snap.sign.x_dynosaur)&msToken=$($snap.sign.ms_token)&X-Bogus=1&X-Gnarly=$($snap.sign.x_gnarly)"  # 快照签名
$variantC = "$base&X-Dynosaur=$($snap.sign.x_dynosaur)&msToken=$($snap.sign.ms_token)&X-Bogus=$newBogus&X-Gnarly=$($snap.sign.x_gnarly)"  # 新X-Bogus + 快照其余

$headers = @{
    "Content-Type" = "application/x-protobuf"
    "Cookie" = $cookieStr
    "Origin" = "https://www.tiktok.com"
    "Referer" = "https://www.tiktok.com/messages"
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
}

$variants = @(
    @{ name = "A_nosign"; url = $variantA },
    @{ name = "B_snapshot"; url = $variantB },
    @{ name = "C_newbogus"; url = $variantC }
)
foreach ($v in $variants) {
    $entry = @{ name = $v.name; url = $v.url.Substring(0, [Math]::Min(160, $v.url.Length)) }
    try {
        $r = Invoke-WebRequest -Method POST -Uri $v.url -Body $body -Headers $headers -UseBasicParsing -TimeoutSec 30
        $entry.status = $r.StatusCode
        $content = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        $entry.body = $content.Substring(0, [Math]::Min(300, $content.Length))
    } catch {
        $ex = $_.Exception
        if ($ex.Response) {
            $entry.status = [int]$ex.Response.StatusCode
            try {
                $sr = [IO.StreamReader]::new($ex.Response.GetResponseStream())
                $entry.body = $sr.ReadToEnd().Substring(0, 300)
            } catch { $entry.body = "" }
        } else {
            $entry.status = -1
            $entry.body = $ex.Message
        }
    }
    $results += $entry
    Write-Host ("{0}: HTTP {1}" -f $entry.name, $entry.status)
    Start-Sleep -Seconds 2
}

$result = @{ variants = $results; new_x_bogus = $newBogus }
$result | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
