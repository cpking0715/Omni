# rs_ui_send_test.ps1 — 决定性对照: UI 真实发送给新接收方(royyen_3), 观察是否成功 + 抓请求
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_uisend.json"
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
function Invoke-Cdp($ws, [int]$i, [string]$method, $params, [int]$timeoutMs = 60000) {
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
# hook 网络: fetch+XHR 记录 message/send 与相关请求
$hookExpr = @'
(() => {
  if (window.__uiNet2) return 'already';
  window.__uiNet2 = [];
  const push = (k, u) => { if (window.__uiNet2.length > 60) window.__uiNet2.shift(); window.__uiNet2.push(k + '|' + String(u).slice(0, 800)); };
  const of = window.fetch;
  window.fetch = function(...args) {
    const u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
    if (String(u).includes('im-api') || String(u).includes('message/send') || String(u).includes('combo')) push('F', u);
    return of.apply(this, args);
  };
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u) {
    if (String(u).includes('im-api') || String(u).includes('message/send') || String(u).includes('combo')) push('X', u);
    return oo.apply(this, arguments);
  };
  return 'hooked';
})()
'@
$r0 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $hookExpr; returnByValue = $true }
$log += 'hook: ' + $r0.result.result.value

# 1. 搜索 royyen_3 (不在会话列表) → 等建议
$expr1 = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="search-user-input"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(input, 'royyen_3');
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 4000));
  const sugg = [];
  document.querySelectorAll('li, [role="option"], [data-e2e*="sug"], [data-e2e*="search"]').forEach(el => {
    const hasAvatar = !!el.querySelector('img');
    const txt = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    if ((hasAvatar || /royyen/.test(txt)) && txt && txt.length < 80) {
      sugg.push({ e2e: (el.getAttribute('data-e2e')||'').slice(0,50), txt });
    }
  });
  out.sugg = sugg.slice(0, 15);
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr1; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'sugg: ' + $r1.result.result.value

# 2. 点击第一个新用户建议 (含头像的建议项)
$expr2 = @'
(async () => {
  const out = {};
  const cands = [...document.querySelectorAll('li, [role="option"], [data-e2e*="sug"]')]
    .filter(el => el.querySelector('img') && !el.closest('[data-e2e="dm-new-conversation-item"]'));
  out.candCount = cands.length;
  if (cands.length > 0) {
    cands[0].click();
    out.clicked = (cands[0].textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    await new Promise(r => setTimeout(r, 4000));
  }
  // 检查聊天区: 输入框/昵称/发送按钮
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.input = !!input;
  const nick = document.querySelector('[data-e2e="dm-new-chat-nickname"]');
  out.nick = nick ? nick.textContent.trim() : '';
  const btns = [...document.querySelectorAll('button, [role="button"]')]
    .filter(b => /send/i.test((b.getAttribute('aria-label')||'') + ' ' + (b.getAttribute('data-e2e')||'') + ' ' + (b.textContent||'').slice(0,20)))
    .slice(0, 5)
    .map(b => ({ e2e: b.getAttribute('data-e2e')||'', aria: b.getAttribute('aria-label')||'', cls: (b.className||'').toString().slice(0,50), disabled: b.disabled || b.getAttribute('aria-disabled') }));
  out.sendBtns = btns;
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr2; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'open: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
