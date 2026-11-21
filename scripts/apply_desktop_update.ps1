param(
    [switch]$Async,
    [string]$Mode = "silent",
    [switch]$ShowWindow
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
$modeVal = if (($ShowWindow.IsPresent) -or ($Mode -eq "show")) { "show" } else { "silent" }

if ($Async) {
    & (Join-Path $PSScriptRoot "trigger_async_reload.ps1") -DelayMs 2500 -Mode $modeVal
} else {
    & (Join-Path $PSScriptRoot "async_hot_reload_mcp.ps1") -DelayMs 150 -Mode $modeVal
    Write-Host "[OK] Agent MCP Desktop updated and relaunched (mode=$modeVal)!" -ForegroundColor Green
}
