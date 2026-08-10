$key = "1b9852a697cd62264618eaf6ea150c13009671a2b9fc76dc"
$start = Invoke-RestMethod -Uri "http://127.0.0.1:50325/api/v1/browser/start?user_id=k1fan6kh" -Headers @{Authorization = "Bearer $key"}
$port = $start.data.debug_port
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
foreach ($t in $targets) {
    if ($t.type -eq "page") { Write-Host ($t.url + " | " + $t.webSocketDebuggerUrl) }
}
