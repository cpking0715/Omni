# ttdm 一键启动脚本: 构建 + 启动 Web 控制台 + 打开浏览器
# 用法:
#   .\start.ps1              # 构建并启动 (默认端口 8787)
#   .\start.ps1 -Port 9000   # 自定义端口
#   .\start.ps1 -NoBuild     # 跳过构建, 直接启动已有 ttdm.exe
param(
    [int]$Port = 8787,
    [switch]$NoBuild
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

if (-not $NoBuild) {
    Write-Host "==> 构建 ttdm ..."
    go build -o ttdm.exe ./cmd/ttdm
    if ($LASTEXITCODE -ne 0) { Write-Error "构建失败"; exit 1 }
    Write-Host "    构建完成"
}

# AdsPower 本地服务检测 (仅提示, 不阻塞)
$adsUp = $false
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:50325/status" -TimeoutSec 2 -UseBasicParsing
    $adsUp = $true
} catch { }
if (-not $adsUp) {
    Write-Warning "AdsPower 本地服务未启动 (127.0.0.1:50325)。"
    Write-Warning "使用指纹浏览器通道请先启动 AdsPower; 仅用本地浏览器/Web 通道可忽略。"
}

Write-Host "==> 启动 ttdm server: http://127.0.0.1:$Port"
$server = Start-Process -FilePath "$root\ttdm.exe" -ArgumentList @("server", "--addr", "127.0.0.1:$Port") -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
if ($server.HasExited) {
    Write-Error "ttdm server 启动失败 (退出码 $($server.ExitCode))，请检查端口占用或数据目录"
    exit 1
}
Start-Process "http://127.0.0.1:$Port"
Write-Host "Web 控制台已打开 (PID $($server.Id))。关闭本窗口或按 Ctrl+C 停止服务。"

try {
    Wait-Process -Id $server.Id
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Write-Host "ttdm server 已停止"
}
