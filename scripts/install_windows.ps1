<#
.SYNOPSIS
    Install or uninstall Agent MCP on Windows (venv + editable package + Desktop & Start Menu shortcuts).

.DESCRIPTION
    - Creates/reuses a virtual environment (venv or .venv) and installs `agent-mcp` with desktop/tray extras.
    - Creates Desktop shortcut: %USERPROFILE%\Desktop\Agent MCP.lnk
    - Creates Start Menu shortcut:
        Default (Administrator / sudo): C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Agent MCP.lnk
        Fallback (non-admin / -UserOnly): %APPDATA%\Microsoft\Windows\Start Menu\Programs\Agent MCP.lnk
    - Optionally adds the venv Scripts directory to User PATH so `agent-mcp` and `agent-mcp-gui` work globally.

.EXAMPLE
    .\scripts\install_windows.ps1
    sudo pwsh -File .\scripts\install_windows.ps1
    .\scripts\install_windows.ps1 -CliOnly
    .\scripts\install_windows.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$CliOnly,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$UserOnly,
    [switch]$AddToPath = $true,
    [switch]$SkipInstall,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$IconPath = Join-Path $RootDir "agent_mcp\assets\app_icon.ico"
$LauncherPath = Join-Path $RootDir "launch_gui.pyw"

$DesktopDir = [Environment]::GetFolderPath("Desktop")
$DesktopLnk = Join-Path $DesktopDir "Agent MCP.lnk"
$AllUsersStartMenuDir = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
$AllUsersStartMenuLnk = Join-Path $AllUsersStartMenuDir "Agent MCP.lnk"
$UserStartMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$UserStartMenuLnk = Join-Path $UserStartMenuDir "Agent MCP.lnk"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$IconLocation,
        [string]$Description
    )
    $parent = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $TargetPath
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkingDirectory
    if ($IconLocation -and (Test-Path $IconLocation)) {
        $lnk.IconLocation = "$IconLocation,0"
    }
    $lnk.Description = $Description
    $lnk.Save()
}

if ($Uninstall) {
    Write-Host "[Agent MCP] Removing Windows shortcuts..." -ForegroundColor Cyan
    foreach ($p in @($DesktopLnk, $AllUsersStartMenuLnk, $UserStartMenuLnk)) {
        if (Test-Path $p) {
            try {
                Remove-Item -Path $p -Force
                Write-Host "  Removed: $p" -ForegroundColor Green
            } catch {
                Write-Warning "  Failed to remove $p (try running as Administrator / sudo): $_"
            }
        }
    }
    Write-Host "[Agent MCP] Uninstall finished. Project directory '$RootDir' was kept intact." -ForegroundColor Cyan
    exit 0
}

# 1. Detect or create virtual environment
$VenvDir = $null
foreach ($candidate in @("venv", ".venv")) {
    $full = Join-Path $RootDir $candidate
    if (Test-Path (Join-Path $full "Scripts\python.exe")) {
        $VenvDir = $full
        break
    }
}
if (-not $VenvDir) {
    $VenvDir = Join-Path $RootDir "venv"
    Write-Host "[Agent MCP] Creating virtual environment at $VenvDir ..." -ForegroundColor Cyan
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }
    if (-not $pyCmd) {
        throw "Python 3.10+ not found in PATH. Please install Python 3.10+ first."
    }
    & $pyCmd.Source -m venv $VenvDir
}

$VenvScripts = Join-Path $VenvDir "Scripts"
$VenvPython = Join-Path $VenvScripts "python.exe"
$VenvPythonw = Join-Path $VenvScripts "pythonw.exe"
if (-not (Test-Path $VenvPythonw)) {
    $VenvPythonw = $VenvPython
}

# 2. Install editable package
if (-not $SkipInstall) {
    $extra = if ($CliOnly) { "" } else { "[full]" }
    Write-Host "[Agent MCP] Installing agent-mcp$extra into $VenvDir ..." -ForegroundColor Cyan
    & $VenvPython -m pip install --upgrade pip
    & $VenvPython -m pip install -e "$RootDir$extra"
}

# 3. Optionally add venv Scripts to User PATH for global CLI usage
if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $segments = @()
    if ($userPath) { $segments = $userPath -split ";" | Where-Object { $_ -ne "" } }
    if ($segments -notcontains $VenvScripts) {
        $newPath = ($segments + $VenvScripts) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "[Agent MCP] Added '$VenvScripts' to User PATH (restart terminal to use 'agent-mcp' anywhere)." -ForegroundColor Green
    }
}

# 4. Create GUI shortcuts (unless -CliOnly)
if (-not $CliOnly) {
    $argsStr = "`"$LauncherPath`""
    if (-not $NoDesktop) {
        New-Shortcut -ShortcutPath $DesktopLnk `
                     -TargetPath $VenvPythonw `
                     -Arguments $argsStr `
                     -WorkingDirectory $RootDir `
                     -IconLocation $IconPath `
                     -Description "Agent MCP Desktop Console"
        Write-Host "[Agent MCP] Created Desktop shortcut: $DesktopLnk" -ForegroundColor Green
    }

    if (-not $NoStartMenu) {
        $useAllUsers = (-not $UserOnly) -and (Test-IsAdmin)
        if ($useAllUsers) {
            New-Shortcut -ShortcutPath $AllUsersStartMenuLnk `
                         -TargetPath $VenvPythonw `
                         -Arguments $argsStr `
                         -WorkingDirectory $RootDir `
                         -IconLocation $IconPath `
                         -Description "Agent MCP Desktop Console"
            Write-Host "[Agent MCP] Created Start Menu shortcut (All Users): $AllUsersStartMenuLnk" -ForegroundColor Green
        } else {
            New-Shortcut -ShortcutPath $UserStartMenuLnk `
                         -TargetPath $VenvPythonw `
                         -Arguments $argsStr `
                         -WorkingDirectory $RootDir `
                         -IconLocation $IconPath `
                         -Description "Agent MCP Desktop Console"
            Write-Host "[Agent MCP] Created Start Menu shortcut (Current User): $UserStartMenuLnk" -ForegroundColor Green
            if (-not $UserOnly) {
                Write-Host "  Tip: Run with Administrator / 'sudo' to install to '$AllUsersStartMenuDir'." -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n[Agent MCP] Installation complete!" -ForegroundColor Cyan
Write-Host "  GUI : Double-click 'Agent MCP' shortcut or run: agent-mcp gui"
Write-Host "  CLI : agent-mcp setup  |  agent-mcp run  |  agent-mcp config"
