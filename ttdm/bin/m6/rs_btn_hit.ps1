# rs_btn_hit.ps1 — 诊断: elementFromPoint 确认点击命中元素 + 发送按钮 disabled 状态
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_btnhit.json"
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

# 1. 输入框有内容(之前累积), 直接检查发送按钮状态 + 命中测试
$expr = @'
(() => {
  const out = {};
  const send = document.querySelector('svg[aria-label="Send"]');
  out.sendExists = !!send;
  if (send) {
    const r = send.getBoundingClientRect();
    out.sendRect = { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
    out.sendCenter = { x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2) };
    // 命中测试: 中心 + 各偏移点
    const pts = {
      center: [Math.round(r.x + r.width/2), Math.round(r.y + r.height/2)],
      topRight: [Math.round(r.x + r.width - 4), Math.round(r.y + 4)],
      bottomRight: [Math.round(r.x + r.width - 4), Math.round(r.y + r.height - 4)],
      right: [Math.round(r.x + r.width - 2), Math.round(r.y + r.height/2)],
    };
    out.hits = {};
    for (const [k, [hx, hy]] of Object.entries(pts)) {
      const el = document.elementFromPoint(hx, hy);
      out.hits[k] = el ? {
        tag: el.tagName,
        aria: el.getAttribute('aria-label') || '',
        e2e: el.getAttribute('data-e2e') || '',
        cls: (el.className || '').toString().slice(0, 50),
        closestBtn: el.closest('[aria-label], [data-e2e], button') ? (el.closest('[aria-label], [data-e2e], button').getAttribute('aria-label') || el.closest('[aria-label], [data-e2e], button').getAttribute('data-e2e') || el.closest('[aria-label], [data-e2e], button').tagName) : ''
      } : null;
    }
    // disabled 状态
    const parent = send.closest('button, [role="button"], [data-e2e]');
    out.sendParent = parent ? {
      tag: parent.tagName,
      disabled: parent.disabled || parent.getAttribute('aria-disabled') || parent.getAttribute('disabled'),
      cls: (parent.className || '').toString().slice(0, 60)
    } : null;
  }
  // 输入框当前内容
  const input = document.querySelector('div[data-e2e="dm-new-input-editor"]');
  out.inputText = input ? (input.textContent || '').slice(0, 50) : '';
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
$log += 'hit: ' + $r1.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 10 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
