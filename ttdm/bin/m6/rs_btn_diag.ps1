# rs_btn_diag.ps1 — 诊断: 聊天区真实发送按钮 DOM 结构 + 输入后按钮状态
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_btndiag.json"
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

# 1. 当前页面状态 + 聊天区所有 button 元素
$expr1 = @'
(() => {
  const out = {};
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  out.inputExists = !!input;
  if (input) {
    out.inputHTML = input.outerHTML.slice(0, 300);
    out.inputText = (input.textContent || '').slice(0, 50);
  }
  // 聊天区/底部所有 button
  const btns = [];
  document.querySelectorAll('button').forEach((b, i) => {
    const e2e = b.getAttribute('data-e2e') || '';
    const aria = b.getAttribute('aria-label') || '';
    const cls = (b.className || '').toString().slice(0, 80);
    const vis = b.offsetParent !== null;
    const rect = b.getBoundingClientRect();
    btns.push({ i, e2e: e2e.slice(0, 60), aria: aria.slice(0, 60), cls, vis,
      x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) });
  });
  out.buttons = btns.slice(0, 30);
  // 是否有 send 相关字样
  out.sendLike = btns.filter(b => /send|发送/i.test(b.e2e + ' ' + b.aria));
  // 底部输入区结构 (可能不是 button 而是 div role=button)
  out.inputAreaHTML = (input ? input.parentElement.parentElement.outerHTML.slice(0, 600) : 'no-input');
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$log += 'dom: ' + $r1.result.result.value

# 2. 输入文本(真实键入)后按钮状态
$expr2 = @'
(async () => {
  const out = {};
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  if (!input) { out.err = 'no input'; return JSON.stringify(out); }
  input.focus();
  await new Promise(r => setTimeout(r, 300));
  // 用 execCommand 或直接设置 textContent + input 事件 (contenteditable)
  input.textContent = 'rs-btn-diag-' + Date.now();
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(r => setTimeout(r, 1500));
  out.inputNow = (input.textContent || '').slice(0, 40);
  const btns = [];
  document.querySelectorAll('button').forEach((b, i) => {
    const e2e = b.getAttribute('data-e2e') || '';
    const aria = b.getAttribute('aria-label') || '';
    const vis = b.offsetParent !== null;
    const rect = b.getBoundingClientRect();
    if (/send|发送/i.test(e2e + ' ' + aria) || (vis && rect.y > 400)) {
      btns.push({ i, e2e: e2e.slice(0, 60), aria: aria.slice(0, 60), vis,
        x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height),
        disabled: b.disabled || b.getAttribute('aria-disabled') });
    }
  });
  out.buttonsAfterInput = btns.slice(0, 15);
  return JSON.stringify(out);
})()
'@
$r2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; awaitPromise = $true; returnByValue = $true; timeout = 30000 }
$log += 'after-input: ' + $r2.result.result.value

$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
