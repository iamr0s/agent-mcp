param(
    [int]$DelayMs = 2500,
    [string]$Mode = "silent",
    [switch]$ShowWindow
)

$ErrorActionPreference = "Continue"
$wantShow = ($ShowWindow.IsPresent) -or ($Mode -eq "show")
$root = Split-Path -Parent $PSScriptRoot
$srcWin = Join-Path $root "apps\agent_mcp_app\build\windows\x64\runner\Release"
$srcWeb = Join-Path $root "apps\agent_mcp_app\build\web"
$srcCli = Join-Path $root "bin\agent-mcp.exe"
$srcIco = Join-Path $root "apps\agent_mcp_app\assets\app_icon.ico"
$dist = Join-Path $root "dist\windows"
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "hot_reload.log"

function Write-ReloadLog([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Write-ReloadLog "=== Async Hot-Reload Triggered (DelayMs=$DelayMs, Mode=$Mode, WantShow=$wantShow) ==="

if (-not (Test-Path (Join-Path $srcWin "agent_mcp_app.exe"))) {
    Write-ReloadLog "ERROR: Release binary missing at $srcWin\agent_mcp_app.exe. Aborting."
    exit 1
}

if ($DelayMs -gt 0) {
    Start-Sleep -Milliseconds $DelayMs
}

Write-ReloadLog "[1/4] Stopping running agent_mcp_app process..."
Get-Process -Name "agent_mcp_app" -ErrorAction SilentlyContinue | Stop-Process -Force

$targetExe = Join-Path $dist "agent_mcp_app.exe"
for ($i = 0; $i -lt 30; $i++) {
    $stillRunning = Get-Process -Name "agent_mcp_app" -ErrorAction SilentlyContinue
    if (-not $stillRunning) {
        if (-not (Test-Path $targetExe)) { break }
        try {
            $fs = [System.IO.File]::Open($targetExe, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            $dllPath = Join-Path $dist "flutter_windows.dll"
            if (Test-Path $dllPath) {
                $fsDll = [System.IO.File]::Open($dllPath, 'Open', 'ReadWrite', 'None')
                $fsDll.Close()
            }
            break
        } catch {
            # File handle still releasing
        }
    }
    Start-Sleep -Milliseconds 300
}

Write-ReloadLog "[2/4] Syncing native Windows desktop release and assets to $dist..."
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$staleFlutterAssets = Join-Path $dist "data\flutter_assets"
if (Test-Path $staleFlutterAssets) {
    Remove-Item -Recurse -Force $staleFlutterAssets -ErrorAction SilentlyContinue
}

Copy-Item -Recurse -Force "$srcWin\*" $dist

if (Test-Path $srcCli) {
    Copy-Item -Force $srcCli (Join-Path $dist "agent-mcp.exe")
}
if (Test-Path $srcIco) {
    Copy-Item -Force $srcIco (Join-Path $dist "app_icon.ico")
}

if (Test-Path (Join-Path $srcWeb "index.html")) {
    Write-ReloadLog "[3/4] Syncing compiled Flutter Web bundle to $dist\web_dashboard..."
    $dstWeb = Join-Path $dist "web_dashboard"
    if (Test-Path $dstWeb) {
        Remove-Item -Recurse -Force $dstWeb -ErrorAction SilentlyContinue
    }
    Copy-Item -Recurse -Force $srcWeb $dstWeb
}

$launchArg = if ($wantShow) { "--show" } else { "--silent" }
Write-ReloadLog "[4/4] Relaunching $targetExe $launchArg..."
$proc = Start-Process -FilePath $targetExe -ArgumentList $launchArg -WorkingDirectory $dist -PassThru
Write-ReloadLog "=== Hot-Reload Completed Successfully (new_pid=$($proc.Id)) ==="
