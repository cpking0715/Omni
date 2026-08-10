# rs_combo3.ps1 — 1) hook get_by_user_combo 响应 2) user/full 搜索端点拿真实用户 uid
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_combo3.json"
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
  if (window.__combo3) return 'already';
  window.__combo3 = [];
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) { this.__u3 = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(...args) {
    this.addEventListener('load', () => {
      const u = String(this.__u3 || '');
      if (u.includes('get_by_user_combo')) {
        window.__combo3.push({ url: u.slice(0, 2000), len: (this.responseText||'').length, head: (this.responseText||'').slice(0, 6000) });
        if (window.__combo3.length > 8) window.__combo3.shift();
      }
    });
    return os.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 1) 搜索已有用户 royyen (触发 combo), 拿完整响应结构
$expr1 = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  input.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'royyen');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 4000));
  out.comboCount = (window.__combo3 || []).length;
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr1; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'typed: ' + $r1.result.result.value
$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__combo3 || [])'; returnByValue = $true }
$log += 'combo: ' + $r2.result.result.value

# 2) user/full 搜索端点 (拿任意真实用户 uid)
$expr2 = @'
(async () => {
  const out = {};
  const url = 'https://www.tiktok.com/api/search/user/full/?aid=1988&app_language=en&app_name=tiktok_web&browser_language=en-US&channel=tiktok_web&device_id=7669334412366218765&device_platform=web_pc&keyword=royyen&os=windows&priority_region=US&region=US&user_is_login=true&verifyFp=verify_msd57ogu_DzQuW7jI_Qyks_4bnD_9A6r_qpHE8ymsH3St&count=5';
  try {
    const r = await fetch(url, { credentials: 'include', headers: { 'accept': 'application/json' } });
    const t = await r.text();
    out.status = r.status; out.len = t.length;
    // 提取用户字段
    const users = [];
    try {
      const j = JSON.parse(t);
      const arr = j.user_list || j.data || [];
      for (const u of (Array.isArray(arr) ? arr : [])) {
        const info = u.user_info || u;
        users.push({ uid: info.uid, unique: info.unique_id, nick: info.nickname, secUid: (info.sec_uid||'').slice(0,30) });
      }
    } catch (e) {}
    out.users = users.slice(0, 5);
    out.head = t.slice(0, 600);
  } catch (e) { out.err = String(e).slice(0, 200); }
  return JSON.stringify(out);
})()
'@
$r3 = Invoke-Cdp $ws 4 "Runtime.evaluate" @{ expression = $expr2; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'userfull: ' + $r3.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
