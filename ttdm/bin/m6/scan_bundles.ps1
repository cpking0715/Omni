# 扫描下载的 bundle, 寻找 access_key 生成逻辑
$dir = "d:\MyProjects\OmniMarket\ttdm\bin\m6\bundles"
$needles = @("access_key", "accessKey", "fws_1.0.0", "08ac725d2a9a3fac7cc3a25bb7a44aec", "c23b210eec9aeb43c4ea9b36eeaf7a19", "im-ws", "ws/v2", "xsack", "xaack", "fpid", "1459", "1988")
$md5Re = [regex]'(md5|MD5)'
foreach ($f in Get-ChildItem "$dir\*.js") {
    $c = Get-Content $f.FullName -Raw
    foreach ($n in $needles) {
        $idx = $c.IndexOf($n)
        if ($idx -ge 0) {
            $ctx = $c.Substring([Math]::Max(0, $idx - 250), [Math]::Min(600, $c.Length - [Math]::Max(0, $idx - 250)))
            Write-Host "=== $($f.Name) contains '$n' ==="
            Write-Host ($ctx -replace '\s+', ' ')
            Write-Host ""
        }
    }
    if ($md5Re.IsMatch($c)) {
        $m = $md5Re.Match($c)
        $ctx = $c.Substring([Math]::Max(0, $m.Index - 200), [Math]::Min(500, $c.Length - [Math]::Max(0, $m.Index - 200)))
        Write-Host "=== $($f.Name) has md5 ==="
        Write-Host ($ctx -replace '\s+', ' ')
        Write-Host ""
    }
}
Write-Host "scan done"
