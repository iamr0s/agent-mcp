param(
    [switch]$NoReload,
    [string]$Mode = "silent",
    [switch]$ShowWindow
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
$modeVal = if (($ShowWindow.IsPresent) -or ($Mode -eq "show")) { "show" } else { "silent" }
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = Join-Path $root ".sdk\flutter\bin\flutter.bat"
$dart = Join-Path $root ".sdk\flutter\bin\dart.bat"
if (-not (Test-Path $flutter)) {
    $flutter = "flutter"
    $dart = "dart"
}

Write-Host "[1/4] Building Flutter Web (/dashboard/ bundle)..." -ForegroundColor Cyan
Push-Location (Join-Path $root "apps\agent_mcp_app")
& $flutter build web --release --base-href /dashboard/ --no-pub
if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }

Write-Host "[2/4] Building Native Windows Desktop App (agent_mcp_app.exe)..." -ForegroundColor Cyan
& $flutter build windows --release --no-pub
if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
Pop-Location

Write-Host "[3/4] Compiling Standalone CLI / stdio Binary (agent-mcp.exe)..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path (Join-Path $root "bin") | Out-Null
& $dart compile exe (Join-Path $root "packages\agent_mcp_core\bin\agent_mcp.dart") -o (Join-Path $root "bin\agent-mcp.exe")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dist = Join-Path $root "dist\windows"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$runningApp = Get-Process -Name "agent_mcp_app" -ErrorAction SilentlyContinue
if ($runningApp) {
    Write-Host "[4/4] Live agent_mcp_app detected (PID=$($runningApp.Id -join ','))..." -ForegroundColor Cyan
    $dstWeb = Join-Path $dist "web_dashboard"
    if (Test-Path $dstWeb) { Remove-Item -Recurse -Force $dstWeb }
    Copy-Item -Recurse -Force (Join-Path $root "apps\agent_mcp_app\build\web") $dstWeb
    if ($NoReload) {
        Write-Host "[OK] Build staged cleanly (-NoReload set; call scripts\trigger_async_reload.ps1 when ready)." -ForegroundColor Green
    } else {
        & (Join-Path $PSScriptRoot "trigger_async_reload.ps1") -DelayMs 2500 -Mode $modeVal
    }
} else {
    Write-Host "[4/4] Assembling Portable Release Folder ($dist)..." -ForegroundColor Cyan
    foreach ($stale in @("web_dashboard", "data\flutter_assets")) {
        $sp = Join-Path $dist $stale
        if (Test-Path $sp) { Remove-Item -Recurse -Force $sp }
    }
    Copy-Item -Recurse -Force (Join-Path $root "apps\agent_mcp_app\build\windows\x64\runner\Release\*") $dist
    Copy-Item -Force (Join-Path $root "bin\agent-mcp.exe") (Join-Path $dist "agent-mcp.exe")
    Copy-Item -Force (Join-Path $root "apps\agent_mcp_app\assets\app_icon.ico") (Join-Path $dist "app_icon.ico")
    Copy-Item -Recurse -Force (Join-Path $root "apps\agent_mcp_app\build\web") (Join-Path $dist "web_dashboard")
    Write-Host "[OK] Portable Release Ready at: $dist" -ForegroundColor Green
}
