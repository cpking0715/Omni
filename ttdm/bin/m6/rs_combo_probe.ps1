# rs_combo_probe.ps1 — hook get_by_user_combo 响应, 拿用户会话数据 (uid/conv_id)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_combo.json"
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
# hook XHR 响应: 记录 get_by_user_combo 的 URL + responseText (前 3000 字符)
$hookExpr = @'
(() => {
  if (window.__combo) return 'already';
  window.__combo = [];
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u) {
    this.__u = u;
    return oo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    this.addEventListener('load', () => {
      const u = String(this.__u || '');
      if (u.includes('get_by_user_combo') || u.includes('get_by_conversation')) {
        const t = this.responseText || '';
        window.__combo.push({ url: u.slice(0, 400), len: t.length, head: t.slice(0, 3000) });
        if (window.__combo.length > 10) window.__combo.shift();
      }
    });
    return os.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 在搜索框输入 royyen (已存在用户) 触发 get_by_user_combo, 读响应
$expr = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'royyen');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 4000));
  out.logCount = (window.__combo || []).length;
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'typed: ' + $r1.result.result.value

$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = 'JSON.stringify(window.__combo || [])'; returnByValue = $true }
$log += 'combo: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
