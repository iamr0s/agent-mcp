param(
    [int]$DelayMs = 2500,
    [string]$Mode = "silent",
    [switch]$ShowWindow
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
$modeVal = if (($ShowWindow.IsPresent) -or ($Mode -eq "show")) { "show" } else { "silent" }
$root = Split-Path -Parent $PSScriptRoot
$workerScript = Join-Path $PSScriptRoot "async_hot_reload_mcp.ps1"
if (-not (Test-Path $workerScript)) {
    Write-Error "Missing worker script: $workerScript"
    exit 1
}

$quotedWorker = if ($workerScript.Contains(' ')) { "`"$workerScript`"" } else { $workerScript }
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedWorker -DelayMs $DelayMs -Mode $modeVal"
$fullCmd = "`"$psExe`" $psArgs"

# 1. Primary (zero-elevation, works for standard users):
#    Win32 CreateProcessW with CREATE_BREAKAWAY_FROM_JOB (0x01000000) + CREATE_NO_WINDOW (0x08000000)
#    Cleanly escapes agent_mcp_app's Job Object (which sets JOB_OBJECT_LIMIT_BREAKAWAY_OK).
try {
    if (-not ("JobBreakawayLauncher" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JobBreakawayLauncher {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation
    );
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);

    public static int LaunchDetached(string cmdLine, string cwd) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = 1; // STARTF_USESHOWWINDOW
        si.wShowWindow = 0; // SW_HIDE
        PROCESS_INFORMATION pi;
        const uint flags = 0x01000000u | 0x08000000u; // CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW
        if (!CreateProcessW(null, cmdLine, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, cwd, ref si, out pi)) {
            return -Marshal.GetLastWin32Error();
        }
        int pid = pi.dwProcessId;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return pid;
    }
}
"@
    }
    $spawnPid = [JobBreakawayLauncher]::LaunchDetached($fullCmd, $root)
    if ($spawnPid -gt 0) {
        Write-Host "[ASYNC_HOT_RELOAD_SCHEDULED] via=breakaway pid=$spawnPid delay_ms=$DelayMs mode=$modeVal" -ForegroundColor Green
        exit 0
    }
} catch {
    # Fallback below
}

# 2. Fallback: Shell.Application COM (explorer.exe)
try {
    $shellApp = New-Object -ComObject Shell.Application
    $shellApp.ShellExecute($psExe, $psArgs, $root, "open", 0)
    Write-Host "[ASYNC_HOT_RELOAD_SCHEDULED] via=explorer.exe delay_ms=$DelayMs mode=$modeVal" -ForegroundColor Green
    exit 0
} catch {
    $p = Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList $psArgs -WorkingDirectory $root -PassThru
    Write-Host "[ASYNC_HOT_RELOAD_SCHEDULED_FALLBACK] updater_pid=$($p.Id) delay_ms=$DelayMs mode=$modeVal" -ForegroundColor Yellow
}
