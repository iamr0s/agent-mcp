param(
    [switch]$SkipBuild,
    [string]$Version = "3.5.1"
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $SkipBuild) {
    Write-Host "[0/4] Running clean release build (-NoReload)..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "build_release.ps1") -NoReload
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$winReleaseDir = Join-Path $root "apps\agent_mcp_app\build\windows\x64\runner\Release"
$webBuildDir   = Join-Path $root "apps\agent_mcp_app\build\web"
$cliBinPath    = Join-Path $root "bin\agent-mcp.exe"
$iconPath      = Join-Path $root "apps\agent_mcp_app\assets\app_icon.ico"

foreach ($reqPath in @($winReleaseDir, $webBuildDir, $cliBinPath, $iconPath)) {
    if (-not (Test-Path $reqPath)) {
        throw "Missing required build artifact: $reqPath (run without -SkipBuild first)"
    }
}

$outRoot    = Join-Path $root "release"
$stageRoot  = Join-Path $outRoot "_clean_stage"
$zipOutPath = Join-Path $outRoot "AgentMCP-v$Version-windows-x64-portable.zip"
$sfxOutPath = Join-Path $outRoot "AgentMCP-v$Version-windows-x64-sfx.exe"

Write-Host "[1/4] Assembling zero-config clean staging directory..." -ForegroundColor Cyan
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

Copy-Item -Recurse -Force (Join-Path $winReleaseDir "*") $stageRoot
Copy-Item -Force $cliBinPath (Join-Path $stageRoot "agent-mcp.exe")
Copy-Item -Force $iconPath (Join-Path $stageRoot "app_icon.ico")
Copy-Item -Recurse -Force $webBuildDir (Join-Path $stageRoot "web_dashboard")

$forbiddenRelPaths = @(
    "config",
    "logs",
    "bin",
    "data\cache",
    "data\oauth_state.json",
    "data\sub_mcp_tokens.json",
    "data\exposures_state.json",
    "data\window_state.json",
    "data\tunnel_state.json",
    "data\update_prefs.json",
    "data\remote_nodes.json"
)
foreach ($rel in $forbiddenRelPaths) {
    $p = Join-Path $stageRoot $rel
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}

$leaked = Get-ChildItem -Path $stageRoot -Recurse -Include @(
    "mcp_config.json",
    "mcp_sub_servers.json",
    "oauth_state.json",
    "sub_mcp_tokens.json",
    "exposures_state.json",
    "window_state.json",
    "tunnel_state.json",
    "update_prefs.json",
    "remote_nodes.json",
    "*.log"
) -ErrorAction SilentlyContinue
if ($leaked) {
    throw "Sanitization check failed! Found personal state files: $($leaked.FullName -join ', ')"
}

Write-Host "[2/4] Compressing clean portable archive ($zipOutPath)..." -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $zipOutPath) { Remove-Item -Force $zipOutPath }
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageRoot,
    $zipOutPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

Write-Host "[3/4] Compiling Zero-UI Bootstrapper + Native Flutter --installer SFX ($sfxOutPath)..." -ForegroundColor Cyan
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    throw "Could not locate .NET Framework v4.0 csc.exe on this machine."
}

$csFile = Join-Path $outRoot "_sfx_stub.cs"
$csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("Agent MCP Prism Setup")]
[assembly: AssemblyProduct("Agent MCP Console")]
[assembly: AssemblyVersion("3.5.1.0")]

namespace AgentMcpSfx {
    internal sealed class InstallOptions {
        public bool Silent;
        public bool Cli;
        public bool AutoConfirmClose;
        public bool CreateShortcut = true;
        public bool ShortcutExplicit;
        public bool ShowHelp;
        public string ExplicitDir;
        public string After = "gui";
        public int DelayMs;
    }

    internal static class Program {
        internal const string AppVersion = "__APP_VERSION__";
        private const string RegSubKey = @"Software\AgentMCP";

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [STAThread]
        private static int Main(string[] args) {
            InstallOptions opts = ParseArgs(args);

            if (opts.ShowHelp) {
                EnsureConsole();
                PrintUsage();
                return 0;
            }

            if (opts.Silent) {
                return RunSilentInstall(opts);
            }

            if (opts.Cli) {
                EnsureConsole();
                return RunCliInstall(opts);
            }

            return LaunchFlutterInstallerWizard(opts);
        }

        private static int LaunchFlutterInstallerWizard(InstallOptions opts) {
            string tempDir = Path.Combine(
                Path.GetTempPath(),
                "AgentMCP-Setup-" + Guid.NewGuid().ToString("N").Substring(0, 10)
            );
            try {
                ExtractPayload(tempDir, null);
                string guiExe = Path.Combine(tempDir, "agent_mcp_app.exe");
                if (!File.Exists(guiExe)) {
                    EnsureConsole();
                    return RunCliInstall(opts);
                }

                var argBuilder = new StringBuilder();
                argBuilder.Append("--installer");
                argBuilder.Append(" --payload-dir \"").Append(tempDir.TrimEnd('\\')).Append("\"");
                if (!string.IsNullOrEmpty(opts.ExplicitDir)) {
                    argBuilder.Append(" --dir \"").Append(opts.ExplicitDir.TrimEnd('\\')).Append("\"");
                }
                if (!string.IsNullOrEmpty(opts.After)) {
                    argBuilder.Append(" --after ").Append(opts.After);
                }
                if (opts.ShortcutExplicit && !opts.CreateShortcut) {
                    argBuilder.Append(" --no-shortcut");
                }
                if (opts.AutoConfirmClose) {
                    argBuilder.Append(" --auto-close");
                }

                Process.Start(new ProcessStartInfo {
                    FileName = guiExe,
                    Arguments = argBuilder.ToString(),
                    WorkingDirectory = tempDir,
                    UseShellExecute = false
                });
                return 0;
            } catch {
                try { Directory.Delete(tempDir, true); } catch { }
                EnsureConsole();
                return RunCliInstall(opts);
            }
        }

        private static void EnsureConsole() {
            try {
                if (!AttachConsole(-1)) {
                    AllocConsole();
                }
            } catch { }
        }

        private static void PrintUsage() {
            Console.WriteLine("Agent MCP v" + AppVersion + " Prism Smart Installer (Zero-UAC, Native Flutter GUI)");
            Console.WriteLine("Usage:");
            Console.WriteLine("  installer.exe                                 Launch Native Dart/Flutter Prism Setup Wizard");
            Console.WriteLine("  installer.exe --silent [--after gui|tray|cli|none] [--dir <path>] [--delay-ms <N>]");
            Console.WriteLine("  installer.exe --cli [--yes] [--after gui|tray|cli|none] [--dir <path>]");
            Console.WriteLine("  installer.exe --extract-to <path>             Silent extract to target directory (no launch)");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --silent, -S, /S       Unattended zero-prompt install (auto-closes running instance)");
            Console.WriteLine("  --cli                  Console/CLI install mode with stdout progress");
            Console.WriteLine("  --dir, -o <path>       Override target installation directory");
            Console.WriteLine("  --after <mode>         Post-install action: gui (default) | tray | cli | none");
            Console.WriteLine("  --yes, -y              Auto-confirm closing running Agent MCP instances in CLI mode");
            Console.WriteLine("  --no-shortcut          Skip creating Desktop shortcut");
            Console.WriteLine("  --delay-ms <N>         Optional delay before stopping running instances");
        }

        internal static InstallOptions ParseArgs(string[] args) {
            var o = new InstallOptions();
            if (args == null) return o;
            for (int i = 0; i < args.Length; i++) {
                string a = (args[i] ?? "").Trim();
                string al = a.ToLowerInvariant();
                if (al == "--help" || al == "-h" || al == "/?") {
                    o.ShowHelp = true;
                } else if (al == "--silent" || al == "-s" || al == "/s" || al == "/silent") {
                    o.Silent = true;
                    o.AutoConfirmClose = true;
                } else if (al == "--cli" || al == "--console") {
                    o.Cli = true;
                } else if (al == "--yes" || al == "-y" || al == "--auto-close") {
                    o.AutoConfirmClose = true;
                } else if (al == "--no-shortcut") {
                    o.CreateShortcut = false;
                    o.ShortcutExplicit = true;
                } else if (al == "--shortcut") {
                    o.CreateShortcut = true;
                    o.ShortcutExplicit = true;
                } else if ((al == "--dir" || al == "-o" || al == "--target") && i + 1 < args.Length) {
                    o.ExplicitDir = Path.GetFullPath(args[++i]);
                } else if (al == "--extract-to" && i + 1 < args.Length) {
                    o.ExplicitDir = Path.GetFullPath(args[++i]);
                    o.Silent = true;
                    o.AutoConfirmClose = true;
                    o.After = "none";
                    o.CreateShortcut = false;
                    o.ShortcutExplicit = true;
                } else if (al == "--after" && i + 1 < args.Length) {
                    o.After = NormalizeAfter(args[++i]);
                } else if (al.StartsWith("--after=")) {
                    o.After = NormalizeAfter(a.Substring(8));
                } else if (al == "--delay-ms" && i + 1 < args.Length) {
                    int ms;
                    if (int.TryParse(args[++i], out ms) && ms > 0) o.DelayMs = Math.Min(ms, 30000);
                }
            }
            return o;
        }

        private static string NormalizeAfter(string raw) {
            string s = (raw ?? "gui").Trim().ToLowerInvariant();
            if (s == "tray" || s == "silent" || s == "background") return "tray";
            if (s == "cli" || s == "console") return "cli";
            if (s == "none" || s == "no" || s == "exit") return "none";
            return "gui";
        }

        internal static string GetProcessImagePath(Process proc) {
            try {
                IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, proc.Id);
                if (h != IntPtr.Zero) {
                    try {
                        var sb = new StringBuilder(1024);
                        int size = sb.Capacity;
                        if (QueryFullProcessImageName(h, 0, sb, ref size)) {
                            return sb.ToString();
                        }
                    } finally {
                        CloseHandle(h);
                    }
                }
            } catch { }
            try {
                return proc.MainModule != null ? proc.MainModule.FileName : null;
            } catch {
                return null;
            }
        }

        internal static List<Process> FindRunningInstances(string targetDirOrNull) {
            var list = new List<Process>();
            int selfPid = Process.GetCurrentProcess().Id;
            string normTarget = string.IsNullOrEmpty(targetDirOrNull)
                ? null
                : Path.GetFullPath(targetDirOrNull).TrimEnd(Path.DirectorySeparatorChar);

            foreach (string procName in new[] { "agent_mcp_app", "agent-mcp" }) {
                try {
                    foreach (Process p in Process.GetProcessesByName(procName)) {
                        if (p.Id == selfPid) continue;
                        if (normTarget != null && procName == "agent-mcp") {
                            string img = GetProcessImagePath(p);
                            if (string.IsNullOrEmpty(img) ||
                                !img.StartsWith(normTarget, StringComparison.OrdinalIgnoreCase)) {
                                continue;
                            }
                        }
                        list.Add(p);
                    }
                } catch { }
            }
            return list;
        }

        internal static string DetectExistingInstallDir(string explicitDir, out bool isUpgrade) {
            isUpgrade = false;
            if (!string.IsNullOrEmpty(explicitDir)) {
                isUpgrade = File.Exists(Path.Combine(explicitDir, "agent_mcp_app.exe"));
                return explicitDir;
            }

            try {
                foreach (Process p in Process.GetProcessesByName("agent_mcp_app")) {
                    string img = GetProcessImagePath(p);
                    if (!string.IsNullOrEmpty(img) && File.Exists(img)) {
                        string dir = Path.GetDirectoryName(img);
                        if (!string.IsNullOrEmpty(dir)) {
                            isUpgrade = true;
                            return dir;
                        }
                    }
                }
            } catch { }

            try {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RegSubKey)) {
                    if (key != null) {
                        object val = key.GetValue("InstallDir");
                        string regDir = val != null ? val.ToString().Trim() : "";
                        if (!string.IsNullOrEmpty(regDir) && Directory.Exists(regDir)) {
                            isUpgrade = File.Exists(Path.Combine(regDir, "agent_mcp_app.exe"));
                            return regDir;
                        }
                    }
                }
            } catch { }

            string defaultDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                "AgentMCP"
            );
            isUpgrade = File.Exists(Path.Combine(defaultDir, "agent_mcp_app.exe"));
            return defaultDir;
        }

        internal static void SaveInstallRegistry(string targetDir) {
            try {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegSubKey)) {
                    if (key != null) {
                        key.SetValue("InstallDir", Path.GetFullPath(targetDir));
                        key.SetValue("Version", AppVersion);
                        key.SetValue("UpdatedAt", DateTime.UtcNow.ToString("o"));
                    }
                }
            } catch { }
            try {
                string targetExe = Path.Combine(Path.GetFullPath(targetDir), "agent_mcp_app.exe");
                using (RegistryKey notifyRoot = Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings", true)) {
                    if (notifyRoot != null) {
                        foreach (string sub in notifyRoot.GetSubKeyNames()) {
                            using (RegistryKey item = notifyRoot.OpenSubKey(sub, true)) {
                                if (item == null) continue;
                                string ep = (item.GetValue("ExecutablePath") ?? "").ToString();
                                if (ep.EndsWith(targetExe, StringComparison.OrdinalIgnoreCase) ||
                                    ep.EndsWith(@"\agent_mcp_app.exe", StringComparison.OrdinalIgnoreCase)) {
                                    item.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                                }
                            }
                        }
                    }
                }
            } catch { }
        }

        internal static void StopRunningInstances(List<Process> procs) {
            if (procs == null || procs.Count == 0) return;
            foreach (Process p in procs) {
                try {
                    if (!p.HasExited) p.CloseMainWindow();
                } catch { }
            }
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(1800);
            while (DateTime.UtcNow < deadline) {
                bool anyAlive = false;
                foreach (Process p in procs) {
                    try {
                        if (!p.HasExited) { anyAlive = true; break; }
                    } catch { }
                }
                if (!anyAlive) break;
                Thread.Sleep(120);
            }
            foreach (Process p in procs) {
                try {
                    if (!p.HasExited) {
                        p.Kill();
                        p.WaitForExit(3000);
                    }
                } catch { }
            }
            Thread.Sleep(350);
        }

        internal static void ExtractPayload(string targetDir, Action<int, int, string> onProgress) {
            Directory.CreateDirectory(targetDir);
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream raw = asm.GetManifestResourceStream("AgentMCP.payload.zip")) {
                if (raw == null) throw new InvalidOperationException("Embedded payload missing.");
                using (ZipArchive archive = new ZipArchive(raw, ZipArchiveMode.Read)) {
                    int total = archive.Entries.Count;
                    int idx = 0;
                    string fullRoot = Path.GetFullPath(targetDir);
                    if (!fullRoot.EndsWith(Path.DirectorySeparatorChar.ToString())) {
                        fullRoot += Path.DirectorySeparatorChar;
                    }
                    foreach (ZipArchiveEntry entry in archive.Entries) {
                        idx++;
                        string rel = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                        string dst = Path.GetFullPath(Path.Combine(targetDir, rel));
                        if (!dst.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) {
                            continue;
                        }
                        if (string.IsNullOrEmpty(entry.Name)) {
                            Directory.CreateDirectory(dst);
                            continue;
                        }
                        string parent = Path.GetDirectoryName(dst);
                        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

                        Exception lastErr = null;
                        for (int attempt = 0; attempt < 6; attempt++) {
                            try {
                                entry.ExtractToFile(dst, true);
                                lastErr = null;
                                break;
                            } catch (IOException ex) {
                                lastErr = ex;
                                Thread.Sleep(250);
                            } catch (UnauthorizedAccessException ex) {
                                lastErr = ex;
                                Thread.Sleep(250);
                            }
                        }
                        if (lastErr != null) throw lastErr;
                        if (onProgress != null) onProgress(idx, total, entry.Name);
                    }
                }
            }
        }

        internal static void LaunchAfterInstall(string targetDir, string afterMode) {
            string mode = NormalizeAfter(afterMode);
            if (mode == "none") return;

            string guiExe = Path.Combine(targetDir, "agent_mcp_app.exe");
            string cliExe = Path.Combine(targetDir, "agent-mcp.exe");

            if (mode == "gui" && File.Exists(guiExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = guiExe,
                    Arguments = "--show",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            } else if (mode == "tray" && File.Exists(guiExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = guiExe,
                    Arguments = "--silent",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            } else if (mode == "cli" && File.Exists(cliExe)) {
                Process.Start(new ProcessStartInfo {
                    FileName = "cmd.exe",
                    Arguments = "/k \"\"" + cliExe + "\" --version\"",
                    WorkingDirectory = targetDir,
                    UseShellExecute = true
                });
            }
        }

        internal static void CreateDesktopShortcut(string targetExe, string iconPath) {
            try {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string lnkPath = Path.Combine(desktop, "Agent MCP Console.lnk");
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null) return;
                object shell = Activator.CreateInstance(shellType);
                object shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                Type scType = shortcut.GetType();
                scType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { targetExe });
                scType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(targetExe) });
                scType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "Agent MCP Console" });
                if (File.Exists(iconPath)) {
                    scType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { iconPath });
                }
                scType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            } catch { }
        }

        private static int RunSilentInstall(InstallOptions opts) {
            try {
                if (opts.DelayMs > 0) Thread.Sleep(opts.DelayMs);
                bool isUpgrade;
                string targetDir = DetectExistingInstallDir(opts.ExplicitDir, out isUpgrade);
                var running = FindRunningInstances(targetDir);
                if (running.Count > 0) {
                    StopRunningInstances(running);
                }
                ExtractPayload(targetDir, null);
                SaveInstallRegistry(targetDir);
                if (opts.CreateShortcut && (!isUpgrade || opts.ShortcutExplicit)) {
                    string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                    string icoPath = Path.Combine(targetDir, "app_icon.ico");
                    if (File.Exists(exePath)) CreateDesktopShortcut(exePath, icoPath);
                }
                LaunchAfterInstall(targetDir, opts.After);
                return 0;
            } catch {
                return 1;
            }
        }

        private static int RunCliInstall(InstallOptions opts) {
            try {
                Console.WriteLine("=== Agent MCP v" + AppVersion + " CLI Installer ===");
                bool isUpgrade;
                string targetDir = DetectExistingInstallDir(opts.ExplicitDir, out isUpgrade);
                Console.WriteLine("[1/4] Target directory: " + targetDir + (isUpgrade ? " (upgrade - preserving config/data/logs)" : " (fresh install)"));

                var running = FindRunningInstances(targetDir);
                if (running.Count > 0) {
                    Console.WriteLine("[2/4] Detected " + running.Count + " running Agent MCP instance(s).");
                    if (!opts.AutoConfirmClose) {
                        Console.Write("Close running instance(s) and continue? [Y/n]: ");
                        string ans = (Console.ReadLine() ?? "").Trim().ToLowerInvariant();
                        if (ans == "n" || ans == "no") {
                            Console.WriteLine("Aborted by user.");
                            return 2;
                        }
                    }
                    StopRunningInstances(running);
                    Console.WriteLine("      Stopped running instance(s).");
                } else {
                    Console.WriteLine("[2/4] No running instance detected.");
                }

                Console.WriteLine("[3/4] Extracting files...");
                ExtractPayload(targetDir, (cur, total, name) => {
                    if (cur == total || cur % 25 == 0) {
                        Console.WriteLine(string.Format("      ({0}/{1}) {2}", cur, total, name));
                    }
                });
                SaveInstallRegistry(targetDir);
                if (opts.CreateShortcut && (!isUpgrade || opts.ShortcutExplicit)) {
                    string exePath = Path.Combine(targetDir, "agent_mcp_app.exe");
                    string icoPath = Path.Combine(targetDir, "app_icon.ico");
                    if (File.Exists(exePath)) CreateDesktopShortcut(exePath, icoPath);
                }

                Console.WriteLine("[4/4] Install complete! Post-action: " + opts.After);
                if (opts.After == "cli") {
                    string cliExe = Path.Combine(targetDir, "agent-mcp.exe");
                    Console.WriteLine("CLI binary ready: " + cliExe);
                } else {
                    LaunchAfterInstall(targetDir, opts.After);
                }
                return 0;
            } catch (Exception ex) {
                Console.Error.WriteLine("[ERROR] " + ex.Message);
                return 1;
            }
        }
    }
}
'@

$asmVer = if ($Version -match '^\d+\.\d+\.\d+$') { "$Version.0" } else { "3.5.1.0" }
$renderedCs = $csSource.Replace('AssemblyVersion("3.5.1.0")', "AssemblyVersion(`"$asmVer`")").Replace('__APP_VERSION__', $Version)
[System.IO.File]::WriteAllText($csFile, $renderedCs, (New-Object System.Text.UTF8Encoding($true)))
if (Test-Path $sfxOutPath) { Remove-Item -Force $sfxOutPath }

& $csc /nologo /target:winexe /optimize+ `
    "/out:$sfxOutPath" `
    "/win32icon:$iconPath" `
    "/resource:$zipOutPath,AgentMCP.payload.zip" `
    /r:System.dll `
    /r:System.IO.Compression.dll `
    /r:System.IO.Compression.FileSystem.dll `
    $csFile

if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE"
}

Write-Host "[4/4] Cleaning temporary staging files..." -ForegroundColor Cyan
Remove-Item -Force $csFile -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $stageRoot -ErrorAction SilentlyContinue

$zipMb = [math]::Round((Get-Item $zipOutPath).Length / 1MB, 2)
$sfxMb = [math]::Round((Get-Item $sfxOutPath).Length / 1MB, 2)
Write-Host "[OK] Clean Portable ZIP : $zipOutPath ($zipMb MB)" -ForegroundColor Green
Write-Host "[OK] Smart Installer EXE: $sfxOutPath ($sfxMb MB)" -ForegroundColor Green
