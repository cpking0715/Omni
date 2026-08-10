# rs_capture6.ps1 — js-reverse Capture: 浏览器真实 message/send 请求采样 (UI 发送 + resource timing)
# 目标: 确认 send 请求 URL 是否带 X-Dynosaur/msToken/X-Gnarly 签名
$ErrorActionPreference = 'Stop'
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_capture6.json"

function New-Cdp($wsUrl) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $null = $ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $ws
}
function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
function Read-UntilId($ws, [int]$targetId) {
    $buf = New-Object byte[] 524288
    while ($true) {
        $ms = [System.IO.MemoryStream]::new()
        do {
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $msg = $text | ConvertFrom-Json
        if ($msg.id -eq $targetId) { return $msg }
    }
}

$log = @()

# 1) 输入测试消息并点击发送
try {
    $ws1 = New-Cdp $wsUrl
    $sendExpr = @'
(async () => {
  const out = { steps: [] };
  const input = document.querySelector('[data-e2e="dm-new-input-editor"]');
  if (!input) { out.steps.push('no input editor'); return JSON.stringify(out); }
  input.focus();
  input.textContent = 'rs-test-ping';
  input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'rs-test-ping' }));
  out.steps.push('input set');
  await new Promise(r => setTimeout(r, 800));
  const btns = document.querySelectorAll('[data-e2e="dm-new-send-btn"]');
  out.steps.push('send btns: ' + btns.length);
  let clicked = false;
  for (const b of btns) {
    if (b.offsetParent !== null) { b.click(); clicked = true; out.steps.push('clicked visible send btn'); break; }
  }
  if (!clicked) { out.steps.push('no visible send btn; try last'); if (btns.length) btns[btns.length - 1].click(); }
  await new Promise(r => setTimeout(r, 3000));
  return JSON.stringify(out);
})()
'@
    Invoke-Cdp $ws1 1 "Runtime.evaluate" @{ expression = $sendExpr; returnByValue = $true; awaitPromise = $true }
    $r1 = Read-UntilId $ws1 1
    $log += 'send: ' + $r1.result.result.value
    $ws1.Dispose()
} catch { $log += 'step1 failed: ' + $_.Exception.Message }
Start-Sleep -Seconds 6

# 2) 读 resource timing 中的 message/send 与 im-api 请求
$timings = @()
try {
    $ws2 = New-Cdp $wsUrl
    $readExpr = @'
(() => {
  const out = [];
  const entries = performance.getEntriesByType('resource');
  for (const e of entries) {
    if (e.name.indexOf('im-api') >= 0 || e.name.indexOf('message/send') >= 0) {
      out.push({ url: e.name, dur: Math.round(e.duration), size: e.transferSize });
    }
  }
  return JSON.stringify(out.slice(-10));
})()
'@
    Invoke-Cdp $ws2 1 "Runtime.evaluate" @{ expression = $readExpr; returnByValue = $true }
    $r2 = Read-UntilId $ws2 1
    if ($r2.result.result.value) { $timings = $r2.result.result.value | ConvertFrom-Json }
    $ws2.Dispose()
} catch { $log += 'step2 failed: ' + $_.Exception.Message }

$result = @{
    log = $log
    im_api_timings = $timings
}
$result | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
