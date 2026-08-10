# rs_probe_newconv.ps1 — 查找新建会话入口与搜索框 (为 pat1b 新接收方实验准备)
$ErrorActionPreference = 'Stop'
$outFile = "d:\MyProjects\OmniMarket\ttdm\bin\m6\out_newconv.json"
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
$expr1 = @'
(() => {
  const out = {};
  const cands = [...document.querySelectorAll('button, [role="button"], [data-e2e]')]
    .filter(b => /new message|new chat|start new|compose/i.test((b.getAttribute('data-e2e')||'') + ' ' + (b.textContent||'').slice(0,60)));
  out.buttons = cands.slice(0,10).map(b => ({
    e2e: b.getAttribute('data-e2e') || '',
    cls: (b.className||'').toString().slice(0,60),
    txt: (b.textContent||'').replace(/\s+/g,' ').trim().slice(0,50)
  }));
  out.inputs = [...document.querySelectorAll('input')].map(i => ({
    ph: i.placeholder||'', e2e: i.getAttribute('data-e2e')||''
  })).slice(0,8);
  out.convCount = document.querySelectorAll('div[data-e2e="dm-new-conversation-item"]').length;
  return JSON.stringify(out);
})()
'@
$r1 = Invoke-Cdp $ws 1 "Runtime.evaluate" @{ expression = $expr1; returnByValue = $true }
$log += 'ui: ' + $r1.result.result.value
$ws.Dispose()
@{ log = $log } | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8
Write-Host "written: $outFile"
