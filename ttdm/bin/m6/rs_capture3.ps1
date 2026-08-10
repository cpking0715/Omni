# rs_capture3.ps1 — js-reverse Capture: 完整 fetch 包装源码 + 触发请求采样签名调用栈
$wsUrl = "ws://127.0.0.1:51261/devtools/page/F81E975B39BE5F6D57313EEE48678837"
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$ws.ConnectAsync([System.Uri]::new($wsUrl), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

function Invoke-Cdp($ws, [int]$i, [string]$method, $params) {
    $req = @{ id = $i; method = $method }
    if ($null -ne $params) { $req.params = $params }
    $json = $req | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buf = New-Object byte[] 524288
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

# 1) 完整 fetch 包装源码
$expr1 = @'
(() => {
  return window.fetch.toString();
})()
'@
$resp1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$v1 = $resp1.result.result.value
if ($v1) { $v1 | Out-File -FilePath "d:\MyProjects\OmniMarket\ttdm\bin\m6\jsrebuild\fetch_wrapper_src.txt" -Encoding utf8; Write-Host "fetch wrapper length: $($v1.Length)" } else { Write-Host ($resp1 | ConvertTo-Json -Compress -Depth 6) }

# 2) 触发页面请求: 点击第一个会话 (若有), 等待 3 秒
$expr2 = @'
(async () => {
  const click = async (sel) => {
    const el = document.querySelector(sel);
    if (!el) return 'no-el: ' + sel;
    el.click();
    return 'clicked: ' + sel;
  };
  const out = [];
  out.push(await click('div[data-e2e="conversation-item"]'));
  out.push(await click('div[data-e2e="chat-with-user-item"]'));
  out.push(await click('[data-e2e="chat-list-item"]'));
  return JSON.stringify(out);
})()
'@
$resp2 = Invoke-Cdp $ws 2 "Runtime.evaluate" @{ expression = $expr2; returnByValue = $true; awaitPromise = $true }
Write-Host "=== 触发点击 ==="
if ($resp2.result.result.value) { Write-Host $resp2.result.result.value } else { Write-Host ($resp2 | ConvertTo-Json -Compress -Depth 6) }
Start-Sleep -Seconds 4

# 3) 读取 hook 记录
$expr3 = @'
(() => {
  const arr = window.__rsHooked || [];
  const out = [];
  for (const h of arr.slice(-6)) {
    out.push({ url: h.url.slice(0, 400), xhr: h.xhr || false, stack: h.stack });
  }
  return JSON.stringify(out);
})()
'@
$resp3 = Invoke-Cdp $ws 3 "Runtime.evaluate" @{ expression = $expr3; returnByValue = $true }
Write-Host "=== 签名请求采样 (调用栈) ==="
if ($resp3.result.result.value) { Write-Host $resp3.result.result.value } else { Write-Host ($resp3 | ConvertTo-Json -Compress -Depth 6) }
$ws.Dispose()
